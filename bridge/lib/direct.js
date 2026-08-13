/**
 * Reads presence by connecting to Gather ourselves.
 *
 * The bridge's only collector. It replaced two scrapers — a CDP attachment to the
 * desktop client's renderer, and a tail of that client's log file — and removed
 * every constraint they carried:
 *
 *   - no `--remote-debugging-port`, so nothing leaves a debug port open on the
 *     user's authenticated session;
 *   - no dependency on the desktop client running at all;
 *   - no log regexes to break the next time Gather changes a console line;
 *   - **no `resync`**. The full state dump is sent once per *connection*, which
 *     is why attaching to a long-running client yielded heartbeats only and
 *     needed a renderer reload to shake state loose. When the connection is ours,
 *     every connect is a fresh dump. The whole problem disappears.
 *
 * ## Observer mode, and why this is safe
 *
 * `loadSpaceUser` materialises our SpaceUser and starts the state dump.
 * `enterSpace` is a *separate* action, and it is what actually puts an avatar in
 * the room. **We never send it.** The result is a connection with
 * `Connection.entered: false` that receives the complete roster while being
 * invisible to everyone in the space.
 *
 * This also settles the old fear that a second connection would evict the user's
 * own session (close 4031). Measured 2026-08-06: neither an observer connection
 * *nor* an entered one disturbed the desktop client's socket.
 * `Connection` is per-connection but `SpaceUser` is per-person-per-space, so two
 * connections drive the same avatar and there is nothing to collide with.
 *
 * So `enterSpace` is omitted because it is **unnecessary and not free**, not
 * because it is dangerous: entering increments the user's `numTimesEnteredSpace`
 * on every reconnect and marks them present for idle/availability purposes. A
 * collector that only reads should not touch either.
 *
 * ## Handshake
 *
 * Captured off the desktop client's own outbound frames via CDP
 * `Network.webSocketFrameSent`, so these shapes are observed, not guessed:
 *
 *   {type:'Authenticate',   credential:{type:'JWT', jwt:<idToken>}}
 *   {type:'ConnectToSpace', spaceId}
 *   {type:'Subscribe'}                              // takes no arguments
 *   {type:'Action', txnId, action:'loadSpaceUser',
 *                   args:['SpaceUser', null, {connectionTarget, clientPlatform}]}
 *
 * A wrong-shaped `Authenticate` is the trap: Gather does not reject it, it simply
 * never replies and keeps heartbeating, so the failure looks like a network
 * problem rather than an auth one. If this collector ever reports "connected but
 * holding no state" while frames flow, suspect the frame shape first.
 */

import { EventEmitter } from 'node:events';
import { randomUUID } from 'node:crypto';

import { GameProtocolReader } from './game-protocol.js';
import { decode, encode } from './msgpack.js';
import { getIdToken, gatherUid, recentSpaces, uidFromIdToken } from './gather-auth.js';
import { readGatherSpace } from './paths.js';

const GAME_SOCKET = 'wss://game-router.v2.gather.town/gather-game-v2';

/**
 * Rosters are coalesced over this window rather than published per patch. A busy
 * space moves several people a second, and the phone wants the result, not the
 * frames.
 */
const PUBLISH_INTERVAL_MS = 250;

/**
 * The desktop client heartbeats roughly once a second. We are far less chatty
 * because nothing depends on our liveness being noticed quickly; an unauthenticated
 * probe survived 25s sending none at all, so 10s is comfortably inside tolerance.
 */
const HEARTBEAT_INTERVAL_MS = 10_000;

/**
 * How long after the handshake we stay quiet about holding no state.
 *
 * A server heartbeat usually lands before the first `FullStateChunk`, so without
 * this the collector would announce failure on every connect and immediately
 * retract it. Long enough to cover a slow dump, short enough that a genuinely
 * rejected handshake is still reported promptly.
 */
const HANDSHAKE_GRACE_MS = 5000;

/**
 * How long a total silence has to last before we stop believing the socket.
 *
 * Nothing else notices a socket that has gone deaf. `close` is what drives every
 * reconnect here, and a half-open TCP connection never fires one: the peer sent no
 * FIN, so the send side keeps accepting heartbeats into a kernel buffer and the read
 * side simply never delivers anything again. That is the ordinary outcome of a
 * laptop suspending — measured 2026-08-13, 63% of this collector's drops landed
 * within two minutes of a macOS sleep or wake, against a 6% baseline — and when it
 * happens without a FIN the collector reports `98 space users (observer)` and full
 * health for as long as the daemon runs, while receiving nothing and pushing nothing.
 *
 * Gather's server heartbeats every 3–9s, so silence is unambiguous well before this.
 * Generous anyway: the cost of being wrong is a reconnect and a fresh state dump,
 * but reconnecting a *working* socket every 45s would be its own bug.
 */
const SILENCE_LIMIT_MS = 45_000;

/** What we tell Gather we are. Mirrors the desktop client — see docs/gather-api.md. */
const CONNECTION_TARGET = 'OfficeView';
const CLIENT_PLATFORM = 'Desktop';

export class DirectCollector extends EventEmitter {
  constructor({
    spaceId = null,
    socketUrl = GAME_SOCKET,
    // Injected so tests can run against a fake game server without touching
    // Gather or the developer's real session. Production always uses the default.
    getToken = getIdToken,
    log = () => {},
    // Injected for the same reason as `socketUrl`: the honest test of the deaf-socket
    // watchdog is to let a connection actually fall silent, and a suite that waited
    // [SILENCE_LIMIT_MS] to find out would add 45 seconds to every run.
    silenceLimitMs = SILENCE_LIMIT_MS,
  } = {}) {
    super();
    this.log = log;
    this.silenceLimitMs = silenceLimitMs;
    /** Overridable so tests can point at a fake game server instead of Gather. */
    this.socketUrl = socketUrl;
    this._getToken = getToken;
    /** Explicitly configured space, if any; otherwise resolved per connect. */
    this.configuredSpaceId = spaceId;
    this.spaceId = spaceId;
    this.reader = new GameProtocolReader({ log });

    this._ws = null;
    this._retryTimer = null;
    this._publishTimer = null;
    this._heartbeatTimer = null;
    this._backoffMs = 1000;
    this._stopped = false;
    this._healthy = false;
    this._lastDetail = null;
    this._dirty = false;
    this._frames = 0;
    this._connects = 0;
    this._lastClose = null;
    this._handshakeAt = 0;
    /** When a frame last arrived. The watchdog's whole state — see [SILENCE_LIMIT_MS]. */
    this._lastFrameAt = 0;
  }

  get healthy() {
    return this._healthy;
  }

  get detail() {
    return this._lastDetail;
  }

  /**
   * Whether we hold state, as opposed to merely being connected. The distinction
   * matters: an empty roster reported as healthy would let the app render a
   * confident "nobody is following you" out of nothing.
   */
  get hasState() {
    return this.reader.users.size > 0;
  }

  /** Our own `SpaceUser` id, once the dump has told us which row is us. */
  get selfId() {
    return this.reader.selfId;
  }

  /**
   * Moves our avatar to a tile. The one thing this collector writes.
   *
   * `SpaceUser` is per-person-per-space rather than per-connection, so this moves
   * the *same* avatar the desktop client is driving — there is no second body to
   * fight with. Verified 2026-08-07 that it works from an observer connection:
   * `teleport` returns `{type:'Success'}` without `enterSpace` having been sent,
   * which was previously an open question (docs/gather-api.md, Unverified #3).
   * That matters because entering is the one action with a permanent cost, so
   * being able to skip it keeps writes as free as reads.
   *
   * Fire-and-forget by design. Replies come back asynchronously in
   * `DeltaState.actionReturns[]` keyed by `txnId`, and the only failure a caller
   * could act on — not connected, or not knowing which avatar is ours — is
   * already answerable here. The authoritative confirmation is the position
   * patch that follows, which arrives through the normal roster path.
   *
   * The server does **not** validate walkability: every tile on the grid is
   * accepted, including walls and void. Picking somewhere sensible is the
   * caller's job — see `PartyMode`.
   */
  teleport({ x, y, direction = 'Down' }) {
    const ws = this._ws;
    if (!ws || ws.readyState !== 1) return { ok: false, detail: 'not connected to Gather' };
    const selfId = this.reader.selfId;
    if (!selfId) return { ok: false, detail: 'do not know which avatar is ours yet' };
    if (!Number.isFinite(x) || !Number.isFinite(y)) {
      return { ok: false, detail: 'teleport needs finite coordinates' };
    }

    try {
      ws.send(
        encode({
          type: 'Action',
          txnId: randomUUID(),
          action: 'teleport',
          // Flat x/y — `{position:{x,y}}` is rejected — and `direction` is
          // required even though teleporting does not pass through any tiles.
          args: ['SpaceUser', selfId, { x, y, direction }],
        }),
      );
      return { ok: true };
    } catch (error) {
      return { ok: false, detail: error.message };
    }
  }

  stats() {
    return {
      ...this.reader.stats(),
      frames: this._frames,
      connects: this._connects,
      spaceId: this.spaceId,
      authUserId: this.reader.authUserId,
      lastClose: this._lastClose,
      entered: false,
    };
  }

  start() {
    this._stopped = false;
    this._connect();
  }

  stop() {
    this._stopped = true;
    this._clearTimers();
    this._closeSocket();
  }

  /**
   * Reconnects, which is all a resync is here: the server replays the full state
   * dump on every new connection. Kept so the HTTP surface behaves the same
   * whichever collector is running.
   */
  async resync() {
    if (this._stopped) return { ok: false, detail: 'collector stopped' };
    this.log('direct: reconnecting to force a fresh state dump');
    this._clearTimers();
    this._closeSocket();
    this._backoffMs = 1000;
    this._connect();
    return { ok: true, detail: 'reconnecting; a full state dump follows immediately' };
  }

  _clearTimers() {
    if (this._retryTimer) clearTimeout(this._retryTimer);
    if (this._publishTimer) clearInterval(this._publishTimer);
    if (this._heartbeatTimer) clearInterval(this._heartbeatTimer);
    this._retryTimer = null;
    this._publishTimer = null;
    this._heartbeatTimer = null;
  }

  _closeSocket() {
    const ws = this._ws;
    this._ws = null;
    if (!ws) return;
    try {
      ws.close();
    } catch {
      /* already gone */
    }
  }

  _setHealth(healthy, detail) {
    const changed = healthy !== this._healthy || detail !== this._lastDetail;
    this._healthy = healthy;
    this._lastDetail = detail ?? null;
    if (changed) this.emit('status', { healthy, detail: this._lastDetail });
  }

  _scheduleRetry() {
    if (this._stopped || this._retryTimer) return;
    const wait = this._backoffMs;
    this._backoffMs = Math.min(this._backoffMs * 2, 30_000);
    this._retryTimer = setTimeout(() => {
      this._retryTimer = null;
      this._connect();
    }, wait);
    this._retryTimer.unref?.();
  }

  /**
   * Which space to watch.
   *
   * Prefers configuration, then the space the desktop client last opened — which
   * costs nothing and is almost always right — and only then asks the API.
   */
  async _resolveSpaceId() {
    if (this.configuredSpaceId) return this.configuredSpaceId;

    const local = readGatherSpace().spaceId;
    if (local) return local;

    const spaces = await recentSpaces({ log: this.log });
    if (spaces.length === 0) return null;
    // Most recently visited first; `lastVisited` is an ISO string.
    spaces.sort((a, b) => String(b.lastVisited ?? '').localeCompare(String(a.lastVisited ?? '')));
    return spaces[0].id;
  }

  async _connect() {
    if (this._stopped) return;
    this._clearTimers();
    this._closeSocket();

    let token;
    let spaceId;
    try {
      token = await this._getToken({ log: this.log });
      spaceId = await this._resolveSpaceId();
    } catch (error) {
      this._setHealth(false, `gather auth failed: ${error.message}`);
      this._scheduleRetry();
      return;
    }
    if (this._stopped) return;

    if (!spaceId) {
      this._setHealth(false, 'no space to watch — open a space in Gather once, or pass --space');
      this._scheduleRetry();
      return;
    }
    this.spaceId = spaceId;

    // The token is the identity; the stored uid is only a cache of it. Reading
    // the token first means a stale or mismatched config cannot silently point us
    // at the wrong account — which would leave `selfId` unresolved and make
    // "following me" unanswerable.
    const authUserId = uidFromIdToken(token) ?? gatherUid();

    // A fresh reader per connection: the dump we are about to receive is
    // complete, so carrying rows over from a previous connection would only keep
    // ghosts of people who have since left.
    this.reader = new GameProtocolReader({ log: this.log });
    this.reader.authUserId = authUserId;
    this._frames = 0;
    this._lastFrameAt = 0;

    const url =
      `${this.socketUrl}?spaceId=${encodeURIComponent(spaceId)}` +
      `&authUserId=${encodeURIComponent(authUserId ?? '')}`;
    this.reader.noteSocketUrl(url);

    let ws;
    try {
      ws = new WebSocket(url);
    } catch (error) {
      this._setHealth(false, `game socket connect failed: ${error.message}`);
      this._scheduleRetry();
      return;
    }
    ws.binaryType = 'arraybuffer';
    this._ws = ws;
    this._connects++;
    this._setHealth(false, 'connecting to the game server');

    ws.addEventListener('open', () => {
      if (this._ws !== ws) return;
      this._backoffMs = 1000;
      this.log(`direct: connected to space ${spaceId} as observer`);
      try {
        for (const frame of this._handshake(token, spaceId)) ws.send(encode(frame));
      } catch (error) {
        // encode() refuses rather than sending something Gather would ignore.
        this._setHealth(false, `handshake encode failed: ${error.message}`);
        this._closeSocket();
        this._scheduleRetry();
        return;
      }
      this._handshakeAt = Date.now();
      // The clock starts at the handshake, not at the first frame: a server that
      // accepts the socket and then says nothing at all is exactly the case worth
      // reconnecting out of, and leaving this at 0 until something arrived would
      // make that the one case the watchdog could not see.
      this._lastFrameAt = this._handshakeAt;
      this._setHealth(false, 'handshake sent; waiting for state');

      this._publishTimer = setInterval(() => this._flush(), PUBLISH_INTERVAL_MS);
      this._publishTimer.unref?.();
      this._heartbeatTimer = setInterval(() => this._heartbeat(), HEARTBEAT_INTERVAL_MS);
      this._heartbeatTimer.unref?.();
    });

    ws.addEventListener('message', (event) => {
      if (this._ws !== ws) return;
      this._onFrame(event.data);
    });

    ws.addEventListener('close', (event) => {
      if (this._ws !== ws) return;
      this._lastClose = { code: event.code, reason: event.reason || null };
      this._clearTimers();
      this._ws = null;
      // 4031 is the duplicate-connection code the gateway was long believed to
      // use. Observer connections do not trigger it, so seeing it here would mean
      // something about Gather's rules changed and is worth saying out loud.
      const suffix = event.code === 4031 ? ' — duplicate connection rejected' : '';
      this._setHealth(false, `game socket closed (${event.code})${suffix}`);
      this.log(`direct: ${describeClose(event.code, event.reason)}; reconnecting`);
      this._scheduleRetry();
    });

    ws.addEventListener('error', () => {
      if (this._ws !== ws) return;
      // Deliberately silent. This used to log `direct: game socket error` and
      // nothing else, which produced 387 identical lines carrying no information
      // whatsoever — the close code, the only diagnostic fact available, went to
      // `_setHealth` and `_lastClose` and never reached the log at all. So six days
      // of "Gather recycled the connection" and "the laptop slept" were
      // indistinguishable from a real fault, and read as 387 real faults.
      //
      // `close` always follows an `error` and carries the code, so it is the only
      // place worth logging from. Nothing is lost by saying nothing here.
    });
  }

  /**
   * The frames that get us subscribed as an observer.
   *
   * Deliberately does not include `enterSpace`. That is the line between watching
   * a space and being in it, and this collector only ever watches.
   */
  _handshake(token, spaceId) {
    return [
      { type: 'Authenticate', credential: { type: 'JWT', jwt: token } },
      { type: 'ConnectToSpace', spaceId },
      { type: 'Subscribe' },
      {
        type: 'Action',
        txnId: randomUUID(),
        action: 'loadSpaceUser',
        args: [
          'SpaceUser',
          null,
          { connectionTarget: CONNECTION_TARGET, clientPlatform: CLIENT_PLATFORM },
        ],
      },
    ];
  }

  _heartbeat() {
    const ws = this._ws;
    if (!ws || ws.readyState !== 1) return;
    try {
      ws.send(encode({ type: 'Heartbeat', timestamp: Date.now(), origin: 'Client' }));
    } catch {
      // A failed heartbeat means the socket is going; `close` handles it.
    }
  }

  /**
   * Tears the socket down if nothing has arrived for [silenceLimitMs].
   *
   * Returns true when it acted. The teardown is explicit rather than left to the
   * `close` event, because [_closeSocket] nulls `_ws` first and the close handler
   * guards on identity — so a forced close never reaches [_scheduleRetry] by itself.
   */
  _isSilent() {
    const since = Date.now() - this._lastFrameAt;
    if (this._lastFrameAt === 0 || since < this.silenceLimitMs) return false;

    const secs = Math.round(since / 1000);
    this._clearTimers();
    this._closeSocket();
    this._lastClose = { code: null, reason: 'silent' };
    this._setHealth(false, `no frames for ${secs}s — the socket went deaf; reconnecting`);
    this.log(`direct: nothing from Gather for ${secs}s — the socket went deaf; reconnecting`);
    this._scheduleRetry();
    return true;
  }

  _onFrame(data) {
    let frame;
    try {
      frame = decode(Buffer.from(data));
    } catch {
      // Not msgpack. Should not happen on this socket, but never throw in a
      // message handler.
      return;
    }
    if (frame == null || typeof frame !== 'object') return;
    this._frames++;
    // Every frame counts as liveness, heartbeats included — the question the
    // watchdog asks is whether the socket still carries anything at all, not
    // whether anything interesting happened.
    this._lastFrameAt = Date.now();
    if (this.reader.ingest(frame)) this._dirty = true;

    // Interactions go out at once rather than waiting for [PUBLISH_INTERVAL_MS].
    // Coalescing exists because nobody needs every intermediate position; a wave
    // is a single deliberate act by a person and there is nothing to coalesce it
    // with. Emitted after `ingest` so the roster it is judged against is current.
    for (const event of this.reader.takePending()) this.emit('interaction', event);
  }

  _flush() {
    // First, because the block below is what was lying. `_frames` is cumulative and
    // reset only on connect, so once it had ever been above zero this reported full
    // health on every tick for as long as the daemon ran — whether or not a single
    // frame had arrived since. Asking here rather than on the heartbeat also means
    // the answer is never more than one publish interval stale.
    if (this._isSilent()) return;

    if (this._frames > 0) {
      const stats = this.reader.stats();
      if (this.hasState) {
        // Deliberately *not* the frame count. `_setHealth` publishes an event
        // whenever the detail string changes, and a counter changes on every
        // flush — four times a second, for as long as the daemon runs. That
        // would fill the 500-event history the phone replays on reconnect with
        // status noise and push the real events (a wave, someone arriving) out
        // of it within minutes. The user count changes rarely and means
        // something; the frame count lives in `stats()` where polling it is free.
        this._setHealth(true, `${stats.users} space users (observer)`);
      } else if (Date.now() - this._handshakeAt >= HANDSHAKE_GRACE_MS) {
        // Frames arriving but still no state means the handshake was not
        // accepted — Gather stays silent rather than rejecting, so say so.
        this._setHealth(
          false,
          `connected but holding no state (${this._frames} frames, heartbeats only) — ` +
            'the handshake was not accepted',
        );
      }
      // Inside the grace window we leave the status alone: a server heartbeat
      // routinely arrives before the first FullStateChunk, and announcing failure
      // there would emit a spurious unhealthy event on every single connect.
    }
    if (!this._dirty) return;
    this._dirty = false;
    this.emit('roster', this.reader.roster());
  }
}

/**
 * What a close code means, in words, for the log.
 *
 * Exported because it is the whole point of the change that produced it: this
 * collector logged 387 undifferentiated `game socket error` lines over six days, and
 * every one of them was one of the first two cases below — Gather recycling the
 * connection, or a laptop suspending. Neither is a fault. Saying which is what makes
 * the third case, an actual fault, visible at all.
 *
 * @param {number|null} code
 * @param {string} [reason] Gather has never sent one; included because the frame
 *   allows it and inventing a sentence over a real one would be worse.
 */
export function describeClose(code, reason = '') {
  const said = reason ? ` — "${reason}"` : '';
  switch (code) {
    // RFC 6455 1012. Gather's gateway closing us on purpose as it recycles or
    // redeploys. Routine, frequent, and nothing to act on.
    case 1012:
      return `Gather recycled the connection (1012)${said}`;
    // 1006 is synthesised by the client when the peer vanished without a close
    // frame: a suspended laptop, a dropped wifi association, a NAT rebinding.
    case 1006:
      return `the connection dropped without a close frame (1006)${said}`;
    case 1001:
      return `Gather is going away (1001)${said}`;
    case 1000:
      return `Gather closed the connection normally (1000)${said}`;
    // Long believed to be the duplicate-connection code. An observer has never
    // triggered it, so this arriving means Gather's rules changed.
    case 4031:
      return `duplicate connection rejected (4031)${said}`;
    default:
      return `the game socket closed (${code})${said}`;
  }
}
