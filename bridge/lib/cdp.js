import { EventEmitter } from 'node:events';

import { GameProtocolReader } from './game-protocol.js';
import { decode } from './msgpack.js';

export const DEFAULT_CDP_PORT = 9222;

/** The renderer that hosts the Gather app itself. */
const APP_URL = 'app.v2.gather.town';

/** Coalesce roster republishes; positions can patch many times a second. */
const PUBLISH_INTERVAL_MS = 250;

/** Target types that can own a WebSocket. */
const ATTACHABLE = new Set(['page', 'webview', 'iframe', 'other']);

/**
 * Reads the live Gather renderer over the Chrome DevTools Protocol.
 *
 * This is the high-fidelity half of the bridge, and the only way to get the two
 * things the log cannot give: display names and a reliable "someone is
 * following me".
 *
 * ## How it reads the protocol
 *
 * It does *not* inject anything into the page or poke at the app's internals —
 * the production bundle deliberately keeps its MobX stores off `window`
 * (`exposeManagers: {prod: false}`), so scraping them would be guesswork that
 * breaks on every redeploy. Instead it enables CDP's Network domain and reads the
 * WebSocket frames the client is already exchanging with
 * `wss://game-router.v2.gather.town/gather-game-v2`, decodes the msgpack, and
 * interprets the model deltas.
 *
 * That means: no second session, no credentials handled, no duplicate presence
 * in the space, and nothing that depends on minified identifiers.
 *
 * Not opening a second session is not just tidiness. The gateway defines
 * `WSCloseCode.DUPLICATE_CONNECTION = 4031` and keys connection identity on
 * exactly what a second client would reuse (`spaceId` + `authUserId`), with no
 * client-side handler for it — so a second connection could plausibly evict the
 * user's own.
 *
 * ## Why it attaches at the browser level
 *
 * Gather hosts the remote web app in a `BrowserView`, not the top-level window,
 * and also spawns tray and accessory renderers. Picking a single `type: "page"`
 * target out of `/json` can therefore miss the one that owns the game socket
 * entirely. So this connects to the *browser* endpoint, discovers every target,
 * attaches flat sessions to all of them, and enables Network on each — then
 * routes frames by content rather than by which session they arrived on. Targets
 * created later (a reload, a popup) are picked up the same way.
 *
 * ## Requirement
 *
 * The desktop client must have been started with `--remote-debugging-port`. That
 * is a stock Chromium switch which Electron passes straight through; Gather's own
 * `DesktopCliEnableDebugSwitches` gate does not apply to it, because Chromium
 * parses argv before any app code runs. `gather-v2-bridge doctor` prints the
 * exact command.
 *
 * Reconnects indefinitely: sleep, a Gather restart, or a quit-and-relaunch all
 * present as a dead socket and none should need the daemon touched.
 *
 * Emits `roster` ({ selfId, rows }) and `status` ({ healthy, detail }).
 */
export class CdpCollector extends EventEmitter {
  constructor({ port = DEFAULT_CDP_PORT, log = () => {} } = {}) {
    super();
    this.port = port;
    this.log = log;
    this.reader = new GameProtocolReader({ log });

    this._ws = null;
    this._nextId = 1;
    this._pending = new Map();
    this._retryTimer = null;
    this._publishTimer = null;
    this._backoffMs = 1000;
    this._stopped = false;
    this._healthy = false;
    this._lastDetail = null;
    this._dirty = false;
    this._decodedFrames = 0;
    this._uidRead = false;
    /** sessionId -> target url, for the sessions we have attached. */
    this._sessions = new Map();
    /** targetIds we have already claimed, so a re-announce does not double-attach. */
    this._claimedTargets = new Set();
    /** requestIds we have decided are the game socket. */
    this._gameSockets = new Set();
  }

  get healthy() {
    return this._healthy;
  }

  get detail() {
    return this._lastDetail;
  }

  /**
   * Live view of what the protocol reader has seen. Computed fresh on every call
   * — the health `detail` string is only rewritten when health *changes*, so it
   * goes stale immediately and must never be the thing you diagnose from.
   */
  stats() {
    return {
      ...this.reader.stats(),
      decodedFrames: this._decodedFrames,
      gameSockets: this._gameSockets.size,
      sessions: [...this._sessions.values()].map(trim),
      authUserId: this.reader.authUserId,
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

  _clearTimers() {
    if (this._retryTimer) clearTimeout(this._retryTimer);
    if (this._publishTimer) clearInterval(this._publishTimer);
    this._retryTimer = null;
    this._publishTimer = null;
  }

  _closeSocket() {
    const ws = this._ws;
    this._ws = null;
    this._gameSockets.clear();
    this._sessions.clear();
    this._claimedTargets.clear();
    this._uidRead = false;
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

  async _connect() {
    if (this._stopped) return;
    this._clearTimers();
    this._closeSocket();

    let browserUrl;
    try {
      browserUrl = await this._browserEndpoint();
    } catch {
      this._setHealth(false, `devtools port ${this.port} unreachable`);
      this._scheduleRetry();
      return;
    }

    let ws;
    try {
      ws = new WebSocket(browserUrl);
    } catch (err) {
      this._setHealth(false, `cdp connect failed: ${err.message}`);
      this._scheduleRetry();
      return;
    }
    this._ws = ws;

    ws.addEventListener('open', () => {
      this._backoffMs = 1000;
      this._afterConnect().catch((err) => {
        this.log(`cdp setup failed: ${err.message}`);
        this._setHealth(false, err.message);
        this._closeSocket();
        this._scheduleRetry();
      });
    });

    ws.addEventListener('message', (event) => this._onMessage(String(event.data)));

    const onGone = () => {
      if (this._ws !== ws) return;
      this._rejectAllPending(new Error('cdp socket closed'));
      this._clearTimers();
      this._closeSocket();
      this._setHealth(false, 'devtools socket closed');
      this._scheduleRetry();
    };
    ws.addEventListener('close', onGone);
    ws.addEventListener('error', onGone);
  }

  /** The browser-wide endpoint, which can see every WebContents. */
  async _browserEndpoint() {
    const res = await fetch(`http://127.0.0.1:${this.port}/json/version`, {
      signal: AbortSignal.timeout(4000),
    });
    if (!res.ok) throw new Error(`devtools version returned ${res.status}`);
    const body = await res.json();
    const url = body?.webSocketDebuggerUrl;
    if (typeof url !== 'string') throw new Error('devtools gave no browser endpoint');
    return url;
  }

  async _afterConnect() {
    this._setHealth(false, 'attached; waiting for game frames');
    this.log('cdp attached to browser endpoint; discovering targets');
    // Discovery reports every existing target immediately and every new one as
    // it appears, so a reload or a freshly opened window is covered too.
    await this._send('Target.setDiscoverTargets', { discover: true });

    this._publishTimer = setInterval(() => this._flush(), PUBLISH_INTERVAL_MS);
    this._publishTimer.unref?.();
  }

  async _attachTo(targetInfo) {
    if (!ATTACHABLE.has(targetInfo.type)) return;
    // targetCreated and targetInfoChanged can both name the same target before
    // either attach completes, so claim it synchronously.
    if (this._claimedTargets.has(targetInfo.targetId)) return;
    this._claimedTargets.add(targetInfo.targetId);
    try {
      const res = await this._send('Target.attachToTarget', {
        targetId: targetInfo.targetId,
        flatten: true,
      });
      const sessionId = res?.sessionId;
      if (!sessionId) return;
      this._sessions.set(sessionId, targetInfo.url ?? '');
      // Small buffers: we only care about live frames, never about replaying
      // bodies out of the devtools cache.
      await this._send(
        'Network.enable',
        { maxTotalBufferSize: 65536, maxResourceBufferSize: 65536 },
        sessionId,
      );
      if (String(targetInfo.url ?? '').includes(APP_URL)) {
        this.log(`cdp: watching ${targetInfo.type} ${trim(targetInfo.url)}`);
        this._maybeReadUid(sessionId);
      }
    } catch {
      // Targets come and go; a failed attach is not worth surfacing.
    }
  }

  /**
   * Reads the signed-in Firebase uid out of the renderer's IndexedDB, once.
   *
   * That uid is what links my account to my own `SpaceUser` row, which is what
   * makes "following *me*" answerable. `firebaseLocalStorageDb` is the Firebase
   * JS SDK's own persistence store, not anything Gather-specific, so this
   * survives Gather redeploys. Read-only.
   */
  _maybeReadUid(sessionId) {
    if (this._uidRead || this.reader.authUserId) return;
    this._uidRead = true;

    const expression = `
      new Promise((resolve) => {
        let settled = false;
        const done = (v) => { if (!settled) { settled = true; resolve(v); } };
        setTimeout(() => done(null), 3000);
        try {
          const open = indexedDB.open('firebaseLocalStorageDb');
          open.onerror = () => done(null);
          open.onsuccess = () => {
            try {
              const db = open.result;
              const tx = db.transaction('firebaseLocalStorage', 'readonly');
              const all = tx.objectStore('firebaseLocalStorage').getAll();
              all.onerror = () => done(null);
              all.onsuccess = () => {
                for (const row of all.result || []) {
                  const value = row && row.value;
                  if (value && typeof value.uid === 'string') return done(value.uid);
                }
                done(null);
              };
            } catch (e) { done(null); }
          };
        } catch (e) { done(null); }
      })
    `;

    this._send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, sessionId)
      .then((res) => {
        const uid = res?.result?.value;
        if (typeof uid !== 'string') {
          this._uidRead = false;
          this.log('cdp: could not read firebase uid yet; follow detection waits for it');
          return;
        }
        this.reader.authUserId = uid;
        this.log(`cdp: own firebase uid ${uid.slice(0, 8)}…`);
        this._dirty = true;
      })
      .catch(() => {
        this._uidRead = false;
      });
  }

  /**
   * Whether we actually hold state, as opposed to merely being attached.
   *
   * This distinction is the difference between a useful answer and a dangerous
   * one. The full state dump is sent once, when the client's socket connects. If
   * we attach to a socket that was already open — the normal case, since the
   * desktop client is long-lived — we see only heartbeats until something
   * changes. Reporting that as healthy would let the app render a confident
   * "nobody is following you" from an empty roster.
   */
  get hasState() {
    return this.reader.users.size > 0;
  }

  /**
   * Forces the client to reconnect its game socket, so the server resends the
   * full state dump while we are attached.
   *
   * Needed because that dump is sent exactly once per connection. Attaching to a
   * client that has been running for days therefore yields heartbeats and nothing
   * else until something changes — and people who never move stay invisible. A
   * renderer reload costs about two seconds of reconnect and fixes it outright.
   *
   * @returns {Promise<{ ok: boolean, detail: string }>}
   */
  async resync() {
    const entry = [...this._sessions.entries()].find(([, url]) => url.includes(APP_URL));
    if (!entry) return { ok: false, detail: 'no gather renderer session attached' };
    const [sessionId] = entry;
    try {
      await this._send('Page.enable', {}, sessionId);
      await this._send('Page.reload', { ignoreCache: false }, sessionId);
      this.log('cdp: reloaded the renderer to force a state resync');
      return { ok: true, detail: 'renderer reloaded; state should arrive within a few seconds' };
    } catch (err) {
      return { ok: false, detail: err.message };
    }
  }

  _flush() {
    // Recompute health every tick: `detail` is only rewritten when it changes, so
    // a one-shot string set at attach time goes stale immediately.
    if (this._decodedFrames > 0) {
      const stats = this.reader.stats();
      if (this.hasState) {
        this._setHealth(true, `${stats.users} space users, ${this._decodedFrames} frames`);
      } else {
        this._setHealth(
          false,
          `attached but holding no state (${this._decodedFrames} frames, ` +
            'heartbeats only) — the state dump predates the attach; it resolves on ' +
            "the client's next reconnect",
        );
      }
    }
    if (!this._dirty) return;
    this._dirty = false;
    this.emit('roster', this.reader.roster());
  }

  _onMessage(text) {
    let msg;
    try {
      msg = JSON.parse(text);
    } catch {
      return;
    }

    if (msg.id != null) {
      const pending = this._pending.get(msg.id);
      if (!pending) return;
      this._pending.delete(msg.id);
      clearTimeout(pending.timer);
      if (msg.error) pending.reject(new Error(msg.error.message ?? 'cdp error'));
      else pending.resolve(msg.result);
      return;
    }

    switch (msg.method) {
      case 'Target.targetCreated':
        if (msg.params?.targetInfo) this._attachTo(msg.params.targetInfo);
        return;
      case 'Target.targetInfoChanged': {
        // A navigation can turn a blank target into the Gather app.
        const info = msg.params?.targetInfo;
        if (info && String(info.url ?? '').includes(APP_URL)) this._attachTo(info);
        return;
      }
      case 'Target.detachedFromTarget':
        this._sessions.delete(msg.params?.sessionId);
        return;
      case 'Network.webSocketCreated':
        this._onSocketCreated(msg.params);
        return;
      case 'Network.webSocketFrameReceived':
      case 'Network.webSocketFrameSent':
        this._onFrame(msg.params);
        return;
      case 'Network.webSocketClosed':
        this._gameSockets.delete(msg.params?.requestId);
        return;
      default:
        return;
    }
  }

  _onSocketCreated(params) {
    const url = params?.url;
    if (typeof url !== 'string' || !url.includes('gather-game-v2')) return;
    this._gameSockets.add(params.requestId);
    this.reader.noteSocketUrl(url);
    this.log('cdp: game socket opened');
  }

  _onFrame(params) {
    const response = params?.response;
    if (!response) return;
    // opcode 2 is binary; the game protocol is msgpack over binary frames.
    if (response.opcode !== 2) return;

    const payload = response.payloadData;
    if (typeof payload !== 'string' || payload.length === 0) return;

    let frame;
    try {
      frame = decode(Buffer.from(payload, 'base64'));
    } catch {
      // Not msgpack — the media transport also runs binary sockets through here.
      return;
    }
    if (frame == null || typeof frame !== 'object') return;

    // Network.enable only reports frames from now on, so a socket opened before
    // we attached never produced a webSocketCreated event. Decoding successfully
    // into a typed message is itself the proof that this is the game socket.
    if (!this._gameSockets.has(params.requestId)) {
      if (typeof frame.type !== 'string') return;
      this._gameSockets.add(params.requestId);
      this.log('cdp: adopted an already-open game socket');
    }

    this._decodedFrames++;
    if (this.reader.ingest(frame)) this._dirty = true;
  }

  _send(method, params, sessionId) {
    const ws = this._ws;
    if (!ws || ws.readyState !== 1) return Promise.reject(new Error('cdp not connected'));
    const id = this._nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this._pending.delete(id);
        reject(new Error(`cdp ${method} timed out`));
      }, 10_000);
      timer.unref?.();
      this._pending.set(id, { resolve, reject, timer });
      try {
        ws.send(JSON.stringify(sessionId ? { id, method, params, sessionId } : { id, method, params }));
      } catch (err) {
        clearTimeout(timer);
        this._pending.delete(id);
        reject(err);
      }
    });
  }

  _rejectAllPending(err) {
    for (const [, p] of this._pending) {
      clearTimeout(p.timer);
      p.reject(err);
    }
    this._pending.clear();
  }
}

function trim(url) {
  const text = String(url ?? '');
  return text.length > 60 ? `${text.slice(0, 60)}…` : text;
}

/** Whether anything is answering on the devtools port right now. */
export async function probeCdp(port = DEFAULT_CDP_PORT) {
  try {
    const res = await fetch(`http://127.0.0.1:${port}/json/version`, {
      signal: AbortSignal.timeout(2000),
    });
    if (!res.ok) return null;
    return await res.json();
  } catch {
    return null;
  }
}
