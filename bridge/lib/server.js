import { createServer } from 'node:http';
import { hostname } from 'node:os';

import { DesktopNotificationReader } from './desktop-notifications.js';
import { DirectCollector } from './direct.js';
import { bridgeStatus } from './events.js';
import { FcmSender } from './fcm.js';
import { LogTail } from './log-tail.js';
import { PartyMode } from './party.js';
import { PresenceTracker } from './presence.js';
import { PairingCodes } from './pairing.js';
import { fcmKeyFile, gatherLogFile, lanAddresses, readGatherSpace } from './paths.js';
import { PushNotifier, PushRegistry } from './push.js';
import { acceptWebSocket, isWebSocketUpgrade } from './ws.js';

export const DEFAULT_PORT = 7799;

/** How much history a reconnecting phone can catch up on. */
const HISTORY = 500;

/**
 * Never send a phone two snapshots closer together than this.
 *
 * The snapshot is the whole roster — 79 players and ~23 KiB in the measured
 * space — and it is republished whenever anything in it changes. Measured against
 * a real space that came to 0.86 snapshots per second, ~1.1 MB per minute, for a
 * screen that shows the one person standing next to you. The phone spent that
 * budget decoding rosters and rebuilding its widget tree, which is what "the
 * connection is fragile" actually looked like from the outside.
 *
 * Coalescing rather than dropping: the flush reads live state, so several changes
 * inside one window collapse into a single publish that reflects all of them.
 */
const SNAPSHOT_MIN_INTERVAL_MS = 500;

/** How often to ask each phone to prove it is still on the other end. */
const PING_INTERVAL_MS = 15_000;

/**
 * Drop a client we have not heard a single byte from in this long.
 *
 * Comfortably more than two ping intervals, so one lost packet on a phone's Wi-Fi
 * is not a disconnection.
 */
const CLIENT_IDLE_TIMEOUT_MS = 45_000;

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
    /**
     * The push subsystem. Null builds the real one, which reads the service
     * account from disk and the device list from the user's config.
     *
     * **Tests must always pass one.** Left to build its own, a suite on a machine
     * where push is set up would load real credentials and fire real
     * notifications at the developer's phone.
     */
    push = null,
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
    this.push =
      push ?? new PushNotifier({ sender: loadPushSender(log), registry: new PushRegistry({ log }), log });

    // The collector is looked up lazily rather than passed: it does not exist
    // until `start()`, and it is replaced outright whenever the bridge
    // reconnects to Gather.
    this.party = new PartyMode({ collector: () => this._collector, log });
    // Switching on and off changes what the whole card says, so it goes out as a
    // snapshot. The hop counter ticking does not, and gets a frame of its own.
    this.party.on('change', () => this._publishSnapshot());
    this.party.on('progress', (state) => this._publishParty(state));

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

    /** Pending coalesced snapshot publish, and when the last one went out. */
    this._snapshotTimer = null;
    this._snapshotAt = 0;
    /** Pings the phones and drops the ones that stopped answering. */
    this._keepalive = null;

    const space = readGatherSpace();
    if (space.spaceId) this.tracker.apply({ type: 'space.changed', at: new Date().toISOString(), source: 'bridge', confidence: 'observed', spaceId: space.spaceId, spaceName: null });
  }

  async start() {
    await this._startHttp();
    this._startKeepalive();
    this._startCollector();
    this._startNotificationTail();
  }

  async stop() {
    this.party.stop('the bridge stopped');
    this._collector?.stop();
    this._tail?.stop();
    if (this._snapshotTimer) clearTimeout(this._snapshotTimer);
    this._snapshotTimer = null;
    if (this._keepalive) clearInterval(this._keepalive);
    this._keepalive = null;
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

  /**
   * Pings every client, and drops the ones that have gone quiet.
   *
   * A phone never says goodbye. iOS suspends the app, or Wi-Fi hands over to
   * cellular, and the socket simply stops being answered — no error, no close
   * frame, nothing for the daemon to notice. Without this the fan-out list only
   * ever grew: the log showed `client connected (2 total)` on a bridge with one
   * phone, and every publish after that wrote into a socket nobody was reading
   * until 8 MiB of backlog finally tripped `MAX_BACKLOG`.
   */
  _startKeepalive() {
    this._keepalive = setInterval(() => this._sweepClients(), PING_INTERVAL_MS);
    this._keepalive.unref?.();
  }

  /** One pass of the above. Separate so a test can run it without a clock. */
  _sweepClients(now = Date.now()) {
    for (const client of this._clients) {
      if (now - client.lastSeenAt > CLIENT_IDLE_TIMEOUT_MS) {
        // Deleting the current element of a Set mid-iteration is well defined, and
        // `close` fires the handler that does the removing.
        client.close(1001);
        this.log(`dropped a client that stopped answering (${this._clients.size} left)`);
        continue;
      }
      client.ping();
    }
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

    // The phone hands over its FCM token after pairing, and again whenever
    // Firebase rotates it. Idempotent by token, so re-registering is free.
    if (url.pathname === '/push/register') {
      readJsonBody(req)
        .then((body) => {
          const count = this.push.registry.register({
            token: body?.token,
            platform: body?.platform ?? 'ios',
          });
          json(200, { ok: true, devices: count, sending: this.push.enabled });
        })
        .catch((error) => json(400, { ok: false, detail: error.message }));
      return undefined;
    }

    // Party mode: the one thing the phone can switch on rather than only watch.
    // Reachable by GET as well as POST — it is a toggle, the state it produces is
    // published on the snapshot anyway, and `curl` is how you turn it off when
    // your phone is the thing that went flat.
    if (url.pathname === '/party') {
      const wanted = url.searchParams.get('on');
      if (wanted == null) return json(200, this.party.state());
      const on = wanted !== '0' && wanted !== 'false';
      const result = on ? this.party.start() : this.party.stop('switched off');
      // `ok:false` means it refused to start and said why, which is a 409 rather
      // than a failure of the request itself.
      return json(result.ok === false ? 409 : 200, result);
    }

    switch (url.pathname) {
      case '/state':
        return json(200, { seq: this._seq, ...this._snapshot() });
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
          push: {
            // Whether a service account is loaded, versus how many phones asked
            // for pushes: "configured but nobody registered" and "phones waiting
            // but no credentials" are different problems with different fixes.
            sending: this.push.enabled,
            devices: this.push.registry.list().length,
            kinds: this.push.registry.kinds(),
          },
          party: {
            ...this.party.state(),
            // How big the walkable-tile pool has grown. A small number here is
            // why party mode would be skipping hops.
            knownTiles: this.party.knownTiles,
          },
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
    client.on('message', (text) => this._onCommand(client, text));

    // First frame is always a full snapshot, so the app can paint without
    // replaying history. Through `_snapshot()` rather than the tracker directly,
    // so a phone connecting while party mode is already running sees that instead
    // of waiting for the next change to find out.
    client.send(JSON.stringify({ kind: 'snapshot', seq: this._seq, snapshot: this._snapshot() }));

    // A reconnecting phone asks for what it missed.
    const since = Number(url.searchParams.get('since') ?? 0);
    if (Number.isFinite(since) && since > 0) {
      for (const h of this._history) {
        if (h.seq > since) client.send(JSON.stringify({ kind: 'event', seq: h.seq, event: h.event }));
      }
    }

    this.log(`client connected${raw ? ' (raw)' : ''} (${this._clients.size} total)`);
  }

  /**
   * A command from a phone, over the socket it already has.
   *
   * Party mode used to be reachable only over HTTP, which meant the one thing the
   * app can *do* rode a brand new TCP connection every time — a second chance for
   * the same flaky Wi-Fi to fail, on a link whose WebSocket was demonstrably up.
   * On a phone that is not a theoretical difference: a connection that has been
   * open and passing traffic for a minute is far likelier to work than one being
   * opened from cold.
   *
   * `/party` stays, because `curl` is how you switch it off when your phone is the
   * thing that went flat.
   *
   * No token check: the socket proved the token at upgrade, and nothing can reach
   * this without one.
   */
  _onCommand(client, text) {
    let msg;
    try {
      msg = JSON.parse(text);
    } catch {
      return; // Not ours. Say nothing rather than teaching a scanner our shape.
    }
    if (!msg || typeof msg !== 'object') return;

    // Echoed back so the app can match an answer to the tap that caused it,
    // instead of assuming the next ack it sees is the one it is waiting for.
    const id = typeof msg.id === 'number' ? msg.id : null;
    const reply = (ok, detail = null) =>
      client.send(JSON.stringify({ kind: 'ack', id, ok, detail: ok ? null : detail }));

    switch (msg.cmd) {
      // Liveness the app can ask for directly. On resume it needs to know whether
      // the socket it is holding survived being suspended, and waiting ~20s for a
      // ping to time out means either stale data on screen or tearing down a
      // perfectly good connection to be sure.
      case 'ping':
        return reply(true);

      case 'party': {
        const result = msg.on === true ? this.party.start() : this.party.stop('switched off');
        return reply(result.ok !== false, result.detail);
      }

      default:
        return reply(false, `unknown command ${String(msg.cmd).slice(0, 40)}`);
    }
  }

  // ---- fan-out ---------------------------------------------------------------

  _publish(events) {
    if (events.length === 0) return;
    for (const event of events) {
      const seq = ++this._seq;
      this._history.push({ seq, event });
      const frame = JSON.stringify({ kind: 'event', seq, event });
      for (const client of this._clients) client.send(frame);
      // Fire-and-forget: a phone with a live socket already has this event, and
      // a slow round trip to Google must never hold up the ones that do.
      this.push.consider(event, (id) => this._nameFor(id)).catch(() => {});
    }
    if (this._history.length > HISTORY) {
      this._history.splice(0, this._history.length - HISTORY);
    }
  }

  /**
   * The snapshot, with party mode folded in at the last moment.
   *
   * Pulled rather than pushed. Party mode changes four times a second while it
   * runs, and mirroring each hop into the tracker would mean either a stale
   * counter or a snapshot per hop to every connected phone. Reading it here
   * costs nothing and means whatever snapshot goes out next — for any reason —
   * carries a current number.
   */
  _snapshot() {
    this.tracker.setParty(this.party.state());
    return this.tracker.snapshot();
  }

  /**
   * Publishes the snapshot, no more often than [SNAPSHOT_MIN_INTERVAL_MS].
   *
   * Coalescing, not sampling: a call inside the quiet window schedules one flush
   * and further calls join it, and the flush reads live state — so the phone gets
   * every change, just batched. Nothing is lost, only the redundant intermediate
   * rosters that nobody could have rendered in the meantime.
   */
  _publishSnapshot() {
    if (this._clients.size === 0) return;
    if (this._snapshotTimer) return; // A flush is already coming; it will see this.

    const wait = this._snapshotAt + SNAPSHOT_MIN_INTERVAL_MS - Date.now();
    if (wait <= 0) {
      this._flushSnapshot();
      return;
    }
    this._snapshotTimer = setTimeout(() => {
      this._snapshotTimer = null;
      this._flushSnapshot();
    }, wait);
    this._snapshotTimer.unref?.();
  }

  /**
   * Party mode's own state, and nothing else.
   *
   * The hop counter is on screen while somebody watches it, and a snapshot is the
   * wrong envelope for it: 22 KiB of roster to deliver a number that changed by
   * four. This is about 80 bytes, which is what makes a live counter affordable at
   * all — the alternatives were a frozen one or reintroducing the flood the rest of
   * this work removed.
   *
   * The tracker is updated too, so the next snapshot for any other reason agrees
   * with what the phone was just told.
   */
  _publishParty(state) {
    if (this._clients.size === 0) return;
    this.tracker.setParty(state);
    const frame = JSON.stringify({ kind: 'party', seq: this._seq, party: state });
    for (const client of this._clients) client.send(frame);
  }

  _flushSnapshot() {
    if (this._clients.size === 0) return;
    this._snapshotAt = Date.now();
    const frame = JSON.stringify({
      kind: 'snapshot',
      seq: this._seq,
      snapshot: this._snapshot(),
    });
    for (const client of this._clients) client.send(frame);
  }

  /** A display name for a push, falling back to something a person can read. */
  _nameFor(id) {
    const player = this.tracker.players.find((p) => p.id === id);
    return player?.name ?? 'Someone';
  }

  /** Route one collector event through the tracker and out to the clients. */
  _ingest(events) {
    // Raw subscribers see everything the collectors produced, before the tracker
    // decides what is worth telling a human. Most of what is dropped here is
    // genuine noise — roster churn, voice activity, transport chatter —
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
      // Before the tracker, so that a hop fired from this same roster is judged
      // against the freshest positions we hold rather than the previous ones.
      this.party.noteRoster(roster);
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
          detail: present ? this.logSource : 'Gather log not found (desktop app not running)',
        }),
      ]);
    });

    tail.on('error', (err) => this.log(`log tail error: ${err.message}`));
    tail.start();
  }
}

/**
 * Builds the FCM sender, or returns null when push is not set up.
 *
 * Absent credentials are a normal state, not a fault: everything else works and
 * the phone still gets its notifications whenever the app is running. So this
 * says so once and moves on, rather than throwing at start-up.
 */
function loadPushSender(log) {
  const sender = new FcmSender({ keyFile: fcmKeyFile, log });
  try {
    sender.account();
  } catch (error) {
    log(`push: disabled — ${error.message}`);
    return null;
  }
  log(`push: sending as ${sender.projectId}`);
  return sender;
}

/** Reads a JSON request body, with a cap so a bad client cannot exhaust memory. */
function readJsonBody(req, limit = 64 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(new Error('body too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}'));
      } catch {
        reject(new Error('body is not valid JSON'));
      }
    });
    req.on('error', () => reject(new Error('the request ended early')));
  });
}
