/**
 * What does the desktop client actually say to Gather's media SFU?
 *
 * `docs/gather-api.md` describes the media plane from the bundle: standard
 * mediasoup, `wss://router.v2.gather.town` for assignment, per-node SFU sockets
 * for media, socket.io handshakes carrying `{spaceId, token}`. Reading a minified
 * bundle tells you what the code *can* do. This tells you what it *did*.
 *
 * The distinction is not academic. The game socket's handshake went unmapped for
 * weeks because the bundle does not contain the action names, and it was only
 * settled by capturing the client's own outbound frames. The same trap is set
 * here: the method table in that document was produced by grepping for
 * `sendWithResponse(` literals, and it is missing transport creation entirely.
 *
 * Three deliberate choices, each for a reason:
 *
 *   1. **Every socket is captured, not just the SFU's.** If the SFU credential
 *      turns out to be minted somewhere else — an unmapped game-socket action, a
 *      REST call — a probe filtered to `router.v2.gather.town` would record a
 *      token it cannot explain. The game socket is decoded as msgpack, everything
 *      else through a JSON/engine.io/hexdump ladder.
 *   2. **The upgrade is captured too.** `webSocketWillSendHandshakeRequest`
 *      carries the request headers and `webSocketCreated` carries the full URL
 *      with its query string. Between them they answer the first question
 *      outright: is the credential in the URL, in a header, or in a frame? The
 *      game socket answered "in a frame"; do not assume this one does.
 *   3. **Redaction is the default, not a post-step.** This capture contains live
 *      JWTs, TURN credentials, DTLS fingerprints, and ICE candidates naming your
 *      LAN and public IP addresses. `--raw` is opt-in and gitignored.
 *      It is also a *privacy* problem, which is the less obvious half: capturing
 *      every socket means the game socket's state dump rides along, and that dump
 *      carries real colleagues — names, emails, tile positions. Those are stripped
 *      by key (`PERSONAL_KEYS`) rather than by pattern, because a name is not a
 *      shape. **Read the transcript before sharing it**; a model this probe has
 *      never seen could carry an identity under a key the list does not name.
 *
 * Read-only. It attaches to a client you are already running and never sends a
 * frame to Gather. `--reload` restarts the renderer, which costs ~2s and is the
 * only way to see a handshake that already happened.
 *
 * ```sh
 * # The desktop client must be started with a debug port:
 * open -a GatherV2 --args --remote-debugging-port=9222
 *
 * node tool/probe-sfu.mjs watch                 # attach and wait; walk into a bubble
 * node tool/probe-sfu.mjs watch --seconds 120
 * node tool/probe-sfu.mjs reload                # force a fresh handshake now
 * node tool/probe-sfu.mjs watch --raw capture.jsonl
 * ```
 *
 * `watch` is the one to reach for. The SFU sockets open when a call starts, so
 * the way to catch the handshake cold is to attach first and *then* walk your
 * avatar up to a colleague. `reload` catches the router socket, which the client
 * opens on startup, but restarts the renderer to do it.
 */

import { writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

import { decode } from '../bridge/lib/msgpack.js';

const DEFAULT_PORT = 9222;
const APP_URL = 'app.v2.gather.town';

/** Target types worth attaching to. Gather hosts the app in a BrowserView. */
const ATTACHABLE = new Set(['page', 'webview', 'iframe', 'other']);

const dim = (s) => `\x1b[2m${s}\x1b[0m`;
const bold = (s) => `\x1b[1m${s}\x1b[0m`;
const green = (s) => `\x1b[32m${s}\x1b[0m`;
const yellow = (s) => `\x1b[33m${s}\x1b[0m`;

// ─────────────────────────────────────────────────────────────────────────────
// Redaction
//
// Applied to the transcript that gets read, quoted and committed. The rule is
// "replace the value, keep the shape", because the shape is the whole point of
// the capture: `<redacted jwt 918B>` still tells you a JWT lived there.
// ─────────────────────────────────────────────────────────────────────────────

/** Keys whose values are secret whatever they look like. */
const SECRET_KEYS =
  /^(token|jwt|credential|password|secret|apikey|api_key|accesstoken|access_token|refreshtoken|refresh_token|idtoken|id_token|authorization|cookie|usernamefragment|password_|ice_?password)$/i;

/**
 * Keys carrying somebody's identity rather than a credential.
 *
 * A capture is not only a security problem, it is a privacy one. Because this
 * probe records *every* socket, the game socket's state dump comes along with it
 * — and that dump carries real colleagues: names, email addresses and tile
 * positions. Nothing here is secret in the credential sense and none of it is
 * needed to understand the media protocol, so it goes.
 *
 * Names cannot be found by pattern, only by key, which is why this list matters
 * more than the regexes below. A key not on this list keeps its value.
 */
const PERSONAL_KEYS =
  /^(email|name|displayname|firstname|lastname|fullname|hubspotcontactid|phone|imagepath|profileimage|avatarurl|picture)$/i;

const JWT = /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+/g;
const IPV4 = /\b(?:\d{1,3}\.){3}\d{1,3}\b/g;
const IPV6 = /\b(?:[0-9a-f]{1,4}:){2,7}[0-9a-f]{1,4}\b/gi;
/** mediasoup/ICE secrets that are not JWT-shaped and have no telltale key. */
const FINGERPRINT = /\b(?:[0-9A-F]{2}:){10,}[0-9A-F]{2}\b/g;
const EMAIL = /\b[\w.+-]+@[\w-]+\.[\w.-]+\b/g;

function redactString(text) {
  if (typeof text !== 'string') return text;
  return text
    .replace(JWT, (m) => `<redacted jwt ${m.length}B>`)
    .replace(FINGERPRINT, '<redacted fingerprint>')
    .replace(EMAIL, '<redacted email>')
    .replace(IPV4, '<redacted ipv4>')
    .replace(IPV6, '<redacted ipv6>');
}

export function redact(value, depth = 0) {
  if (depth > 12) return '<deep>';
  if (typeof value === 'string') return redactString(value);
  if (Array.isArray(value)) return value.map((v) => redact(v, depth + 1));
  if (value && typeof value === 'object') {
    const out = {};
    for (const [key, v] of Object.entries(value)) {
      if (SECRET_KEYS.test(key)) {
        const size = typeof v === 'string' ? `${v.length}B` : typeof v;
        out[key] = `<redacted ${key} ${size}>`;
        continue;
      }
      if (PERSONAL_KEYS.test(key) && typeof v === 'string') {
        out[key] = `<redacted ${key}>`;
        continue;
      }
      out[key] = redact(v, depth + 1);
    }
    return out;
  }
  return value;
}

// ─────────────────────────────────────────────────────────────────────────────
// Decoding
//
// Four transports arrive on the same CDP events, so the payload is tried against
// each in turn rather than guessed from the URL — a socket that opened before we
// attached has no `webSocketCreated` event and therefore no URL at all.
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Socket.IO rides on Engine.IO, which frames as `<engine digit><payload>`; the
 * Socket.IO layer then adds its own `<socket digit>[namespace,][ackId]<json>`.
 * Decoding both is what turns `42["produce",{…}]` into a method name and args,
 * which is the entire deliverable of this probe.
 */
const ENGINE_TYPES = {
  0: 'open',
  1: 'close',
  2: 'ping',
  3: 'pong',
  4: 'message',
  5: 'upgrade',
  6: 'noop',
};
const SOCKET_TYPES = {
  0: 'CONNECT',
  1: 'DISCONNECT',
  2: 'EVENT',
  3: 'ACK',
  4: 'CONNECT_ERROR',
  5: 'BINARY_EVENT',
  6: 'BINARY_ACK',
};

export function decodeSocketIo(text) {
  if (typeof text !== 'string' || text.length === 0) return null;
  const engine = ENGINE_TYPES[text[0]];
  if (!engine) return null;
  const rest = text.slice(1);
  if (engine !== 'message') {
    // `0{…}` is the Engine.IO handshake and carries sid/upgrades/timeouts.
    let body = null;
    if (rest.startsWith('{')) {
      try {
        body = JSON.parse(rest);
      } catch {
        body = rest || null;
      }
    } else if (rest) {
      body = rest;
    }
    return { engine, ...(body == null ? {} : { body }) };
  }

  const socket = SOCKET_TYPES[rest[0]];
  if (!socket) return { engine, raw: rest };

  // After the type digit: an optional `/namespace,`, then an optional numeric
  // ack id, then the JSON payload.
  let cursor = 1;
  let namespace = '/';
  if (rest[cursor] === '/') {
    const comma = rest.indexOf(',', cursor);
    const end = comma === -1 ? rest.length : comma;
    namespace = rest.slice(cursor, end);
    cursor = comma === -1 ? rest.length : comma + 1;
  }
  const ackMatch = /^\d+/.exec(rest.slice(cursor));
  let ackId;
  if (ackMatch) {
    ackId = Number(ackMatch[0]);
    cursor += ackMatch[0].length;
  }

  const json = rest.slice(cursor);
  let payload = null;
  if (json) {
    try {
      payload = JSON.parse(json);
    } catch {
      payload = json;
    }
  }

  const out = { engine, socket, namespace };
  if (ackId !== undefined) out.ackId = ackId;

  // An EVENT payload is `[name, ...args]`; splitting it is what makes the
  // grammar summary possible.
  if (socket === 'EVENT' && Array.isArray(payload) && typeof payload[0] === 'string') {
    out.event = payload[0];
    out.args = payload.slice(1);
  } else if (payload != null) {
    out.payload = payload;
  }
  return out;
}

/**
 * msgpack, then Socket.IO/JSON text, then a hexdump of the first bytes.
 *
 * **`payloadData` is not always base64.** CDP sends it verbatim as a UTF-8 string
 * when the opcode is 1 (text) and base64-encodes it only when the opcode is 2
 * (binary). Treating it as base64 unconditionally is the mistake that turns every
 * Engine.IO ping — a one-character text frame, `"2"` — into an empty buffer, and
 * so makes an entire Socket.IO conversation read as `empty ×7`. Ask the opcode.
 */
function decodePayload(payloadData, opcode) {
  const raw = String(payloadData ?? '');
  const isText = opcode === 1;
  const buffer = isText ? Buffer.from(raw, 'utf8') : Buffer.from(raw, 'base64');
  if (buffer.length === 0) return { kind: 'empty' };

  if (isText) {
    const sio = decodeSocketIo(raw);
    if (sio) return { kind: 'socket.io', ...sio };
    try {
      return { kind: 'json', body: JSON.parse(raw) };
    } catch {
      return { kind: 'text', text: raw };
    }
  }

  // Binary. The game socket is msgpack; Socket.IO sends binary attachments for
  // any payload containing a Buffer, and Gather may also run a msgpack parser
  // over Socket.IO, so try msgpack before giving up.
  try {
    const frame = decode(buffer);
    if (frame != null && typeof frame === 'object') return { kind: 'msgpack', frame };
  } catch {
    /* not msgpack */
  }

  // Binary frames can still be UTF-8 text in practice; round-tripping proves it
  // rather than assuming it.
  const text = buffer.toString('utf8');
  if (Buffer.from(text, 'utf8').equals(buffer)) {
    const sio = decodeSocketIo(text);
    if (sio) return { kind: 'socket.io', ...sio };
    try {
      return { kind: 'json', body: JSON.parse(text) };
    } catch {
      return { kind: 'text', text };
    }
  }

  return { kind: 'binary', bytes: buffer.length, head: buffer.subarray(0, 64).toString('hex') };
}

// ─────────────────────────────────────────────────────────────────────────────
// The CDP client
//
// Structure recovered from `bridge/lib/cdp.js`, deleted in 80a2ab8 when the
// direct connection replaced it. Attaching at the *browser* endpoint rather than
// a page endpoint is the load-bearing part: Gather hosts the app in a
// BrowserView alongside tray and accessory renderers, and picking one
// `type:"page"` target out of `/json` misses whichever one owns the socket.
// ─────────────────────────────────────────────────────────────────────────────

class CdpTap {
  constructor({ port, onRecord, log }) {
    this.port = port;
    this.onRecord = onRecord;
    this.log = log;
    this._ws = null;
    this._nextId = 1;
    this._pending = new Map();
    this._sessions = new Map();
    this._claimed = new Set();
    /** requestId -> what we know about that socket. */
    this.sockets = new Map();
  }

  async open() {
    const res = await fetch(`http://127.0.0.1:${this.port}/json/version`, {
      signal: AbortSignal.timeout(4000),
    });
    if (!res.ok) throw new Error(`devtools version returned ${res.status}`);
    const body = await res.json();
    const url = body?.webSocketDebuggerUrl;
    if (typeof url !== 'string') throw new Error('devtools gave no browser endpoint');

    this.log(dim(`attaching to ${body.Browser ?? 'browser'}`));
    const ws = new WebSocket(url);
    this._ws = ws;

    await new Promise((resolve, reject) => {
      ws.addEventListener('open', resolve, { once: true });
      ws.addEventListener('error', () => reject(new Error('devtools socket failed')), {
        once: true,
      });
    });

    ws.addEventListener('message', (event) => this._onMessage(String(event.data)));
    ws.addEventListener('close', () => this._rejectAllPending(new Error('cdp socket closed')));

    // Discovery reports every existing target immediately and every new one as it
    // appears, so a reload or a freshly opened window is covered too.
    await this._send('Target.setDiscoverTargets', { discover: true });
  }

  /** The Gather renderer's session, for `Page.reload`. */
  gatherSession() {
    const entry = [...this._sessions.entries()].find(([, url]) => url.includes(APP_URL));
    return entry?.[0] ?? null;
  }

  async reload() {
    const sessionId = this.gatherSession();
    if (!sessionId) throw new Error('no Gather renderer attached — is the app signed in?');
    await this._send('Page.enable', {}, sessionId);
    await this._send('Page.reload', { ignoreCache: false }, sessionId);
  }

  close() {
    try {
      this._ws?.close();
    } catch {
      /* already gone */
    }
  }

  async _attachTo(info) {
    if (!ATTACHABLE.has(info.type)) return;
    // targetCreated and targetInfoChanged can both name the same target before
    // either attach completes, so claim it synchronously.
    if (this._claimed.has(info.targetId)) return;
    this._claimed.add(info.targetId);
    try {
      const res = await this._send('Target.attachToTarget', {
        targetId: info.targetId,
        flatten: true,
      });
      const sessionId = res?.sessionId;
      if (!sessionId) return;
      this._sessions.set(sessionId, info.url ?? '');
      await this._send(
        'Network.enable',
        { maxTotalBufferSize: 65536, maxResourceBufferSize: 65536 },
        sessionId,
      );
      if (String(info.url ?? '').includes(APP_URL)) {
        this.log(dim(`watching ${info.type} ${trim(info.url)}`));
      }
    } catch {
      // Targets come and go; a failed attach is not worth surfacing.
    }
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

    const p = msg.params ?? {};
    switch (msg.method) {
      case 'Target.targetCreated':
        if (p.targetInfo) this._attachTo(p.targetInfo);
        return;
      case 'Target.targetInfoChanged':
        if (p.targetInfo && String(p.targetInfo.url ?? '').includes(APP_URL)) {
          this._attachTo(p.targetInfo);
        }
        return;
      case 'Target.detachedFromTarget':
        this._sessions.delete(p.sessionId);
        return;

      case 'Network.webSocketCreated':
        this.sockets.set(p.requestId, { url: p.url, frames: 0 });
        this.onRecord({ event: 'created', requestId: p.requestId, url: p.url });
        return;

      // The two events `bridge/lib/cdp.js` never subscribed to, and the reason
      // this probe exists: they carry the URL query string and the request
      // headers, which is where a credential lives if it is not in a frame.
      case 'Network.webSocketWillSendHandshakeRequest':
        this.onRecord({
          event: 'handshake-request',
          requestId: p.requestId,
          url: this.sockets.get(p.requestId)?.url,
          headers: p.request?.headers,
        });
        return;
      case 'Network.webSocketHandshakeResponseReceived':
        this.onRecord({
          event: 'handshake-response',
          requestId: p.requestId,
          url: this.sockets.get(p.requestId)?.url,
          status: p.response?.status,
          headers: p.response?.headers,
        });
        return;

      case 'Network.webSocketFrameSent':
        this._onFrame(p, 'sent');
        return;
      case 'Network.webSocketFrameReceived':
        this._onFrame(p, 'received');
        return;

      case 'Network.webSocketFrameError':
        this.onRecord({ event: 'frame-error', requestId: p.requestId, error: p.errorMessage });
        return;
      case 'Network.webSocketClosed':
        this.onRecord({ event: 'closed', requestId: p.requestId });
        return;
      default:
        return;
    }
  }

  _onFrame(params, direction) {
    const response = params?.response;
    if (!response) return;
    const socket = this.sockets.get(params.requestId) ?? { url: undefined, frames: 0 };
    socket.frames++;
    this.sockets.set(params.requestId, socket);

    this.onRecord({
      event: 'frame',
      direction,
      requestId: params.requestId,
      url: socket.url,
      opcode: response.opcode,
      decoded: decodePayload(response.payloadData, response.opcode),
    });
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
        ws.send(
          JSON.stringify(sessionId ? { id, method, params, sessionId } : { id, method, params }),
        );
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

function trim(url, limit = 70) {
  const text = String(url ?? '');
  return text.length > limit ? `${text.slice(0, limit)}…` : text;
}

/**
 * What kind of socket a URL is, for grouping and for the live log.
 *
 * Measured 2026-08-13, and the shapes differ from what the bundle implied. The
 * real media node is
 * `wss://sfu-v2.eu-central-1-a.prod.aws.gather.town/ip-10-206-193-211/socket.io/`
 * — host prefix `sfu-v2.`, not `sfu.`, and the `ip-…` is a *path* segment naming
 * the node's private address, not a subdomain. Matching only `sfu.` files a real
 * SFU socket under "other" and hides the thing the probe exists to find.
 */
function classify(url) {
  const text = String(url ?? '');
  if (text.includes('gather-game-v2')) return 'game';
  if (text.includes('router.v2.gather.town')) return 'router';
  if (/\/\/sfu[-.]/.test(text) || /\/ip-[\d-]+\//.test(text) || /\/\/ip-/.test(text)) return 'sfu';
  if (!text) return 'unknown';
  return 'other';
}

// ─────────────────────────────────────────────────────────────────────────────
// The grammar summary
//
// The transcript is evidence; this is the artifact. It answers the questions a
// Dart implementation has to know before a line of it can be written: where does
// the credential live, what is the correlation key, and what is the full ordered
// method vocabulary.
// ─────────────────────────────────────────────────────────────────────────────

function summarise(records) {
  const bySocket = new Map();
  for (const r of records) {
    const key = r.requestId ?? '—';
    if (!bySocket.has(key)) bySocket.set(key, { url: r.url, records: [] });
    const entry = bySocket.get(key);
    if (!entry.url && r.url) entry.url = r.url;
    entry.records.push(r);
  }

  console.log(bold('\n══ grammar ═════════════════════════════════════════════════'));
  if (bySocket.size === 0) {
    console.log(dim('  no sockets captured'));
    return;
  }

  for (const [requestId, { url, records: rs }] of bySocket) {
    const kind = classify(url);
    // The game socket is already mapped; the point here is everything else.
    const label = kind === 'game' ? dim('game (already mapped)') : bold(kind);
    console.log(`\n${label}  ${dim(trim(url ?? `requestId ${requestId}`, 90))}`);

    const handshake = rs.find((r) => r.event === 'handshake-request');
    if (handshake) {
      const headerNames = Object.keys(handshake.headers ?? {});
      const interesting = headerNames.filter((h) =>
        /auth|cookie|token|key|sec-websocket-protocol/i.test(h),
      );
      console.log(`  upgrade headers: ${headerNames.length}` +
        (interesting.length ? `, credential-shaped: ${green(interesting.join(', '))}` : ''));
    }
    const query = url && url.includes('?') ? url.slice(url.indexOf('?') + 1) : null;
    if (query) console.log(`  url query: ${yellow(query)}`);

    // Where the credential lives, stated rather than implied.
    const authFrame = rs.find(
      (r) =>
        r.event === 'frame' &&
        r.direction === 'sent' &&
        JSON.stringify(r.decoded ?? {}).includes('redacted'),
    );
    if (authFrame) {
      console.log(`  ${green('credential appears in a frame')} (${authFrame.decoded?.kind})`);
    }

    const events = { sent: new Map(), received: new Map() };
    const acks = { sent: 0, received: 0 };
    const order = [];
    for (const r of rs) {
      if (r.event !== 'frame') continue;
      const d = r.decoded ?? {};
      if (d.socket === 'ACK') acks[r.direction]++;
      const name =
        d.event ??
        (d.socket ? `<${d.socket}>` : null) ??
        (d.kind === 'msgpack' ? `msgpack:${d.frame?.type ?? '?'}` : null) ??
        (d.engine ? `<engine:${d.engine}>` : d.kind);
      if (!name) continue;
      const bucket = events[r.direction];
      bucket.set(name, (bucket.get(name) ?? 0) + 1);
      if (order.length < 24) order.push(`${r.direction === 'sent' ? '→' : '←'} ${name}`);
    }

    const fmt = (m) =>
      [...m.entries()]
        .sort((a, b) => b[1] - a[1])
        .map(([k, n]) => `${k}${n > 1 ? dim(`×${n}`) : ''}`)
        .join(', ') || dim('none');
    console.log(`  client → server: ${fmt(events.sent)}`);
    console.log(`  server → client: ${fmt(events.received)}`);
    if (acks.sent || acks.received) {
      console.log(
        `  ${green('acks')}: ${acks.sent} sent, ${acks.received} received ` +
          dim('— socket.io ack ids are the correlation key for sendWithResponse'),
      );
    }
    if (order.length) console.log(dim(`  first frames: ${order.join('  ')}`));
  }
}

// ─────────────────────────────────────────────────────────────────────────────

async function main() {
  const argv = process.argv.slice(2);
  const mode = argv.find((a) => !a.startsWith('-')) ?? 'watch';
  const flag = (name, fallback) => {
    const i = argv.indexOf(`--${name}`);
    return i === -1 ? fallback : argv[i + 1];
  };

  if (mode === 'help' || argv.includes('--help')) {
    console.log(
      [
        'node tool/probe-sfu.mjs watch [--seconds N] [--out FILE] [--raw FILE] [--port N]',
        'node tool/probe-sfu.mjs reload [...]   force a fresh handshake (~2s renderer restart)',
        '',
        'Start the client with a debug port first:',
        '  open -a GatherV2 --args --remote-debugging-port=9222',
      ].join('\n'),
    );
    return;
  }
  if (mode !== 'watch' && mode !== 'reload') {
    throw new Error(`unknown command "${mode}" — try watch, reload or help`);
  }

  const port = Number(flag('port', DEFAULT_PORT));
  const seconds = Number(flag('seconds', 0));
  const outPath = flag('out', 'sfu-capture.redacted.jsonl');
  const rawPath = flag('raw', null);

  const raw = [];
  const redacted = [];
  const log = (line) => console.log(line);

  const tap = new CdpTap({
    port,
    log,
    onRecord: (record) => {
      const stamped = { t: Date.now(), ...record };
      raw.push(stamped);
      const safe = redact(stamped);
      redacted.push(safe);

      // Live feed, so you can tell whether walking into a bubble did anything.
      if (record.event === 'created') {
        const kind = classify(record.url);
        if (kind !== 'game') log(`${green('socket')} ${bold(kind)} ${dim(trim(record.url, 80))}`);
      } else if (record.event === 'frame') {
        const kind = classify(record.url);
        if (kind === 'game' || kind === 'unknown') return;
        const d = safe.decoded ?? {};
        const name = d.event ?? d.socket ?? d.engine ?? d.kind;
        const arrow = record.direction === 'sent' ? '→' : '←';
        log(`  ${arrow} ${bold(kind)} ${name}${d.ackId !== undefined ? dim(` #${d.ackId}`) : ''}`);
      }
    },
  });

  try {
    await tap.open();
  } catch (err) {
    throw new Error(
      `${err.message}\n\nIs the client running with a debug port?\n` +
        '  open -a GatherV2 --args --remote-debugging-port=9222',
    );
  }

  // Attachment is driven by Target.targetCreated events, which arrive right
  // after setDiscoverTargets; give them a beat before reloading anything.
  await new Promise((r) => setTimeout(r, 1500));

  if (mode === 'reload') {
    log(yellow('reloading the renderer to force a fresh handshake…'));
    await tap.reload();
  } else {
    log(
      yellow('\nattached. Now walk your avatar up to a colleague to open a call.') +
        dim('\n(the SFU sockets open when a call starts, not when the app does)'),
    );
  }

  const stop = () => {
    tap.close();
    writeFileSync(outPath, redacted.map((r) => JSON.stringify(r)).join('\n') + '\n');
    let note = `\n${bold('wrote')} ${outPath} ${dim(`(${redacted.length} records, redacted)`)}`;
    if (rawPath) {
      writeFileSync(rawPath, raw.map((r) => JSON.stringify(r)).join('\n') + '\n');
      note += `\n${bold('wrote')} ${rawPath} ${yellow('(UNREDACTED — contains live credentials, do not commit)')}`;
    }
    console.log(note);
    summarise(redacted);
    process.exit(0);
  };

  process.on('SIGINT', stop);
  if (seconds > 0) {
    log(dim(`stopping in ${seconds}s`));
    setTimeout(stop, seconds * 1000);
  } else {
    log(dim('Ctrl-C to stop and print the grammar'));
  }
}

// Guarded so `decodeSocketIo` and `redact` can be imported and checked without
// attaching to anything. The Socket.IO framing is fiddly — namespace, then an
// optional ack id, then the JSON — and a capture is expensive to repeat: it needs
// a live call with a real colleague. Getting the parser wrong is therefore a
// mistake you discover at the worst possible moment.
if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  main().catch((error) => {
    console.error(`probe failed: ${error.message}`);
    process.exit(1);
  });
}
