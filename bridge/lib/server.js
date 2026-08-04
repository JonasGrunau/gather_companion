import { createServer } from 'node:http';
import { hostname } from 'node:os';

import { CdpCollector, DEFAULT_CDP_PORT } from './cdp.js';
import { bridgeStatus } from './events.js';
import { GatherLogParser } from './log-parser.js';
import { LogTail } from './log-tail.js';
import { FollowDetector, PresenceTracker } from './presence.js';
import { PairingCodes } from './pairing.js';
import { gatherLogFile, lanAddresses, readGatherSpace } from './paths.js';
import { acceptWebSocket, isWebSocketUpgrade } from './ws.js';

export const DEFAULT_PORT = 7799;

/** How much history a reconnecting phone can catch up on. */
const HISTORY = 500;

/**
 * The daemon: two collectors in, one WebSocket out.
 *
 * ```
 *   ~/Library/Logs/GatherV2/main.log ──▶ LogTail ──▶ GatherLogParser ──┐
 *                                                                      ├─▶ PresenceTracker ──▶ WS clients
 *   Gather renderer (CDP, optional) ───▶ CdpCollector ─────────────────┘
 * ```
 *
 * The log collector always runs and needs no setup. The CDP collector attaches
 * when the desktop client was started with `--remote-debugging-port`, and
 * upgrades proximity and following from inferred to observed.
 */
export class BridgeServer {
  constructor({
    token,
    port = DEFAULT_PORT,
    cdpPort = DEFAULT_CDP_PORT,
    logSource = gatherLogFile,
    log = () => {},
  }) {
    this.token = token;
    this.port = port;
    this.cdpPort = cdpPort;
    this.logSource = logSource;
    this.log = log;

    this.tracker = new PresenceTracker({ followDetector: new FollowDetector() });
    this.parser = new GatherLogParser();
    this.pairing = new PairingCodes({ log });

    /** @type {Set<import('./ws.js').WsConnection>} */
    this._clients = new Set();
    /** Clients that asked for the unfiltered firehose via `?raw=1`. */
    this._rawClients = new Set();
    /** @type {Array<{ seq: number, event: object }>} */
    this._history = [];
    this._seq = 0;

    this._http = null;
    this._tail = null;
    this._cdp = null;
    this._startedAt = Date.now();

    const space = readGatherSpace();
    if (space.spaceId) this.tracker.apply({ type: 'space.changed', at: new Date().toISOString(), source: 'bridge', confidence: 'observed', spaceId: space.spaceId, spaceName: null });
  }

  async start() {
    await this._startHttp();
    this._startLogTail();
    this._startCdp();
  }

  async stop() {
    this._tail?.stop();
    this._cdp?.stop();
    for (const client of this._clients) client.close(1001);
    this._clients.clear();
    this._rawClients.clear();
    await new Promise((resolve) => {
      if (!this._http) return resolve();
      this._http.close(() => resolve());
    });
  }

  // ---- transport -------------------------------------------------------------

  _startHttp() {
    return new Promise((resolve, reject) => {
      const server = createServer((req, res) => this._onRequest(req, res));
      server.on('upgrade', (req, socket) => this._onUpgrade(req, socket));
      server.on('error', reject);
      server.listen(this.port, '0.0.0.0', () => {
        server.removeListener('error', reject);
        this._http = server;
        resolve();
      });
    });
  }

  _authorised(url) {
    return url.searchParams.get('token') === this.token;
  }

  _onRequest(req, res) {
    const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`);

    const json = (code, body) => {
      const text = JSON.stringify(body);
      res.writeHead(code, {
        'content-type': 'application/json; charset=utf-8',
        'content-length': Buffer.byteLength(text),
        'cache-control': 'no-store',
      });
      res.end(text);
    };

    // Unauthenticated liveness probe: enough for the CLI to tell "my daemon is
    // up" from "something else has the port", and nothing more.
    if (url.pathname === '/health') {
      return json(200, {
        ok: true,
        name: 'gather-v2-bridge',
        uptimeSeconds: Math.round((Date.now() - this._startedAt) / 1000),
      });
    }

    // Claiming a pairing code is the one thing that cannot require the token —
    // handing over the token is the whole point of it. It is safe because a code
    // only exists after someone ran `pair`, it is single-use, it expires, and a
    // few wrong guesses destroy it.
    if (url.pathname === '/pair/claim') {
      const outcome = this.pairing.claim(url.searchParams.get('code') ?? '');
      if (outcome === 'ok') {
        return json(200, {
          ok: true,
          token: this.token,
          port: this.port,
          // First label only: hostnames arrive as "Mac.local" on some networks and
          // "Mac.fritz.box" on others, and neither domain belongs on a phone screen.
          name: hostname().split('.')[0],
        });
      }
      const detail = {
        'no-code': 'No pairing code is active. Run `npx gather-v2-bridge pair` on the Mac.',
        expired: 'That code has expired. Run `npx gather-v2-bridge pair` again.',
        wrong: 'That code is not right.',
      }[outcome];
      return json(outcome === 'wrong' ? 403 : 409, { ok: false, reason: outcome, detail });
    }

    if (!this._authorised(url)) return json(401, { error: 'bad or missing token' });

    switch (url.pathname) {
      case '/state':
        return json(200, { seq: this._seq, ...this.tracker.snapshot() });
      case '/events': {
        const since = Number(url.searchParams.get('since') ?? 0);
        const events = this._history.filter((h) => h.seq > since);
        return json(200, { seq: this._seq, events });
      }
      case '/resync': {
        // Deliberately reachable by GET as well as POST: it is idempotent-ish and
        // the cost of getting it wrong is a two-second reconnect.
        const cdp = this._cdp;
        if (!cdp) return json(503, { ok: false, detail: 'cdp collector not running' });
        cdp.resync().then((r) => json(r.ok ? 200 : 409, r)).catch((e) =>
          json(500, { ok: false, detail: e.message }),
        );
        return undefined;
      }
      case '/pair/offer': {
        const { code, expiresAt } = this.pairing.mint();
        return json(200, {
          code,
          expiresAt,
          port: this.port,
          addresses: lanAddresses(),
          claims: this.pairing.claims,
        });
      }
      case '/pair/status':
        return json(200, {
          pending: this.pairing.pending,
          claims: this.pairing.claims,
        });
      case '/collectors':
        return json(200, {
          health: this.tracker.health,
          logFile: this.logSource,
          logTailHealthy: this._tail?.healthy ?? false,
          cdpPort: this.cdpPort,
          cdpDetail: this._cdp?.detail ?? null,
          // Live protocol-reader stats. This is the thing to look at when the CDP
          // collector is attached but the roster stays empty: unknown frame types
          // here mean the wire format moved.
          cdpStats: this._cdp?.stats() ?? null,
        });
      default:
        return json(404, { error: 'not found' });
    }
  }

  _onUpgrade(req, socket) {
    const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`);
    if (!isWebSocketUpgrade(req) || url.pathname !== '/ws' || !this._authorised(url)) {
      socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }

    const client = acceptWebSocket(req, socket);
    if (!client) return;
    this._clients.add(client);
    const raw = url.searchParams.get('raw') === '1';
    if (raw) this._rawClients.add(client);
    client.on('close', () => {
      this._clients.delete(client);
      this._rawClients.delete(client);
    });

    // First frame is always a full snapshot, so the app can paint without
    // replaying history.
    client.send(JSON.stringify({ kind: 'snapshot', seq: this._seq, snapshot: this.tracker.snapshot() }));

    // A reconnecting phone asks for what it missed.
    const since = Number(url.searchParams.get('since') ?? 0);
    if (Number.isFinite(since) && since > 0) {
      for (const h of this._history) {
        if (h.seq > since) client.send(JSON.stringify({ kind: 'event', seq: h.seq, event: h.event }));
      }
    }

    this.log(`client connected${raw ? ' (raw)' : ''} (${this._clients.size} total)`);
  }

  // ---- fan-out ---------------------------------------------------------------

  _publish(events) {
    if (events.length === 0) return;
    for (const event of events) {
      const seq = ++this._seq;
      this._history.push({ seq, event });
      const frame = JSON.stringify({ kind: 'event', seq, event });
      for (const client of this._clients) client.send(frame);
    }
    if (this._history.length > HISTORY) {
      this._history.splice(0, this._history.length - HISTORY);
    }
  }

  _publishSnapshot() {
    if (this._clients.size === 0) return;
    const frame = JSON.stringify({
      kind: 'snapshot',
      seq: this._seq,
      snapshot: this.tracker.snapshot(),
    });
    for (const client of this._clients) client.send(frame);
  }

  /** Route one collector event through the tracker and out to the clients. */
  _ingest(events) {
    // Raw subscribers see everything the collectors produced, before the tracker
    // decides what is worth telling a human. Most of what is dropped here is
    // genuine noise — repeated proximity reports, mic toggles, transport chatter —
    // but "what can this thing actually see" is a fair question to be able to
    // answer, so it is one query parameter away rather than unavailable.
    this._publishRaw(events);

    const emit = [];
    let stateChanged = false;
    for (const event of events) {
      const out = this.tracker.apply(event);
      emit.push(...out.emit);
      stateChanged = stateChanged || out.stateChanged;
    }
    this._publish(emit);
    if (stateChanged) this._publishSnapshot();
  }

  _publishRaw(events) {
    if (this._rawClients.size === 0 || events.length === 0) return;
    for (const event of events) {
      const frame = JSON.stringify({ kind: 'raw', event });
      for (const client of this._rawClients) client.send(frame);
    }
  }

  // ---- collectors ------------------------------------------------------------

  _startLogTail() {
    const tail = new LogTail(this.logSource);
    this._tail = tail;

    tail.on('line', (line) => {
      let events;
      try {
        events = this.parser.feed(line);
      } catch (err) {
        this.log(`parser error: ${err.message}`);
        return;
      }
      if (events.length) this._ingest(events);
    });

    tail.on('presence', (present) => {
      this.log(present ? 'gather log found; tailing' : 'gather log missing (client not running?)');
      this._ingest([
        bridgeStatus({
          at: new Date(),
          collector: 'logTail',
          healthy: present,
          detail: present ? this.logSource : 'gather log not found',
        }),
      ]);
    });

    tail.on('error', (err) => this.log(`log tail error: ${err.message}`));
    tail.start();
  }

  _startCdp() {
    const cdp = new CdpCollector({ port: this.cdpPort, log: this.log });
    this._cdp = cdp;

    cdp.on('roster', ({ selfId, rows }) => {
      const out = this.tracker.applyRoster({ selfId, rows });
      this._publish(out.emit);
      if (out.stateChanged) this._publishSnapshot();
    });

    cdp.on('status', ({ healthy, detail }) => {
      this._ingest([
        bridgeStatus({ at: new Date(), collector: 'cdp', healthy, detail }),
      ]);
    });

    cdp.start();
  }
}
