import { createServer } from 'node:http';
import { hostname } from 'node:os';

import { DesktopNotificationReader } from './desktop-notifications.js';
import { DirectCollector } from './direct.js';
import { bridgeStatus } from './events.js';
import { LogTail } from './log-tail.js';
import { PresenceTracker } from './presence.js';
import { PairingCodes } from './pairing.js';
import { gatherLogFile, lanAddresses, readGatherSpace } from './paths.js';
import { acceptWebSocket, isWebSocketUpgrade } from './ws.js';

export const DEFAULT_PORT = 7799;

/** How much history a reconnecting phone can catch up on. */
const HISTORY = 500;

/**
 * The daemon: Gather in, one WebSocket out.
 *
 * ```
 *   Gather's game server ────────────▶ DirectCollector ─────────────┐
 *                                                                   ├─▶ PresenceTracker ─▶ WS clients
 *   ~/Library/Logs/GatherV2/main.log ─▶ DesktopNotificationReader ──┘
 * ```
 *
 * `DirectCollector` is the whole presence story: it authenticates as the user and
 * reads the space from Gather itself. It replaced two scrapers — a CDP attachment
 * to the desktop client's renderer, and a broad tail of that client's log — both
 * of which were strictly worse (a debug port left open on a live session; regexes
 * over log lines Gather never promised to keep).
 *
 * The log tail survives in one narrow form, and only because there is no
 * alternative: Gather's *own* notifications — waves, meeting invites, event
 * reminders — are decisions its client makes and hands to the OS. They are in no
 * model and no REST route. They are also precisely the events worth waking a
 * phone for, so they are worth the one remaining dependency on the desktop app.
 *
 * Mic, camera and screenshare went with the old parser and are not coming back;
 * they exist nowhere but that client's IPC. `SpaceUser.speaking` — live voice
 * activity, and the most frequent delta on the wire — covers the useful half.
 */
export class BridgeServer {
  constructor({
    token,
    port = DEFAULT_PORT,
    spaceId = null,
    logSource = gatherLogFile,
    // Test seams, both passed straight through to the collector. Production uses
    // neither: it reads the adopted session and talks to Gather.
    socketUrl = undefined,
    getToken = undefined,
    log = () => {},
  }) {
    this.token = token;
    this.port = port;
    this.spaceId = spaceId;
    this.logSource = logSource;
    this.socketUrl = socketUrl;
    this.getToken = getToken;
    this.log = log;

    this.tracker = new PresenceTracker();
    this.notifications = new DesktopNotificationReader();
    this.pairing = new PairingCodes({ log });

    /** @type {Set<import('./ws.js').WsConnection>} */
    this._clients = new Set();
    /** Clients that asked for the unfiltered firehose via `?raw=1`. */
    this._rawClients = new Set();
    /** @type {Array<{ seq: number, event: object }>} */
    this._history = [];
    this._seq = 0;

    this._http = null;
    /** @type {DirectCollector|null} */
    this._collector = null;
    this._tail = null;
    this._startedAt = Date.now();

    const space = readGatherSpace();
    if (space.spaceId) this.tracker.apply({ type: 'space.changed', at: new Date().toISOString(), source: 'bridge', confidence: 'observed', spaceId: space.spaceId, spaceName: null });
  }

  async start() {
    await this._startHttp();
    this._startCollector();
    this._startNotificationTail();
  }

  async stop() {
    this._collector?.stop();
    this._tail?.stop();
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
        // Wire identity: `isOurs()` compares against it to tell "my daemon holds
        // this port" from "something else does". Renamed with the command while
        // nothing was installed anywhere — changing it once daemons exist in the
        // wild would make a new CLI declare an older running one foreign.
        name: 'gather-app-bridge',
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
          // First label only: hostnames arrive as "studio.local" on some networks and
          // "studio.fritz.box" on others, and neither domain belongs on a phone screen.
          name: hostname().split('.')[0],
        });
      }
      const detail = {
        'no-code': 'No pairing code is active. Run `npx gather-app-bridge pair` on the computer.',
        expired: 'That code has expired. Run `npx gather-app-bridge pair` again.',
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
        // the cost of getting it wrong is a one-second reconnect.
        const collector = this._collector;
        if (!collector) return json(503, { ok: false, detail: 'no collector running' });
        collector.resync().then((r) => json(r.ok ? 200 : 409, r)).catch((e) =>
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
          detail: this._collector?.detail ?? null,
          logFile: this.logSource,
          logTailHealthy: this._tail?.healthy ?? false,
          // Live protocol-reader stats. This is the thing to look at when the
          // collector is connected but the roster stays empty: unknown frame types
          // here mean the wire format moved.
          stats: this._collector?.stats() ?? null,
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

  _startCollector() {
    const collector = new DirectCollector({
      spaceId: this.spaceId,
      socketUrl: this.socketUrl,
      getToken: this.getToken,
      log: this.log,
    });
    this._collector = collector;
    this.log('connecting to Gather as an observer');

    collector.on('roster', (roster) => {
      const out = this.tracker.applyRoster(roster);
      this._publish(out.emit);
      if (out.stateChanged) this._publishSnapshot();
    });

    collector.on('status', ({ healthy, detail }) => {
      this._ingest([bridgeStatus({ at: new Date(), collector: 'gather', healthy, detail })]);
    });

    collector.start();
  }

  /**
   * Tails the desktop client's log for Gather's own notifications, and nothing
   * else.
   *
   * Unlike the collector this is optional: with the desktop app closed there are
   * no waves to hear about, so a missing log is reported and otherwise shrugged
   * at rather than treated as a fault.
   */
  _startNotificationTail() {
    const tail = new LogTail(this.logSource);
    this._tail = tail;

    tail.on('line', (line) => {
      let events;
      try {
        events = this.notifications.feed(line);
      } catch (err) {
        this.log(`notification reader error: ${err.message}`);
        return;
      }
      if (events.length) this._ingest(events);
    });

    tail.on('presence', (present) => {
      this.log(
        present
          ? 'watching the desktop client\'s log for Gather notifications'
          : 'gather log missing — no waves or meeting invites until the desktop app runs',
      );
      this._ingest([
        bridgeStatus({
          at: new Date(),
          collector: 'logTail',
          healthy: present,
          detail: present ? this.logSource : 'gather log not found (desktop app not running)',
        }),
      ]);
    });

    tail.on('error', (err) => this.log(`log tail error: ${err.message}`));
    tail.start();
  }
}
