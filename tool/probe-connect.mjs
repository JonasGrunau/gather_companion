#!/usr/bin/env node
/**
 * Spike: can the companion be a first-class Gather client instead of a
 * side-channel reader?
 *
 * Today the bridge never talks to Gather — it decodes the desktop client's
 * already-authenticated socket over CDP (`bridge/lib/cdp.js`). This script tests
 * the alternative: authenticate ourselves, open our own game socket, and see
 * whether we get the same roster.
 *
 * THROWAWAY. Nothing here is imported by the bridge or the app. It reuses the
 * bridge's decoder and interpreter unchanged so that a successful run proves the
 * *protocol* half with zero new interpretation code — if `roster()` comes out
 * right, the existing production code already understands a direct connection.
 *
 * ## Safety
 *
 * The repo believes the gateway evicts a duplicate `spaceId`+`authUserId` with
 * close code 4031 (`bridge/lib/cdp.js:37-41`), which would kick the user out of
 * their own Gather session. That could not be confirmed from the client bundle —
 * see the Unverified section of `docs/gather-api.md` — so `connect` refuses to
 * run without `--yes` and prints what it is about to risk. Use a scratch space.
 *
 * On the wire this is read-only: it sends the handshake and nothing else. No
 * movement, no chat, no state mutation.
 *
 * ## Usage
 *
 *   node tool/probe-connect.mjs adopt              # reuse the desktop session (preferred)
 *   node tool/probe-connect.mjs login              # email OTP -> cached tokens (see below)
 *   node tool/probe-connect.mjs whoami             # prove the token on REST
 *   node tool/probe-connect.mjs refresh            # prove refresh works (~1h)
 *   node tool/probe-connect.mjs spaces             # list spaces + their ids
 *   node tool/probe-connect.mjs connect --space <uuid> --yes [--seconds 30]
 *
 * `adopt` is the path that works. `login` (email OTP) is kept because it is the
 * only self-serve route and a second account would need it, but it is **not
 * currently usable for an existing account**: `/auth/otp-requests/verify`
 * accepts a correct code and then fails `404 "No UserAccount found"`. The code
 * itself is fine — a deliberately wrong code returns `400 "That code is invalid
 * or has expired"` instead — so the failure is after OTP validation, in the
 * server's account lookup for the anonymous caller. No client->server call site
 * for this flow exists in the web bundle either, so it may be a partially
 * shipped path. Unresolved; see docs/gather-api.md.
 *
 * The handshake field names are guesses — no client->server frame has ever been
 * captured. `connect` logs every server frame verbatim so each rejection tells
 * us the next field name; edit `handshake()` below and re-run.
 */

import { createInterface } from 'node:readline/promises';
import { randomUUID } from 'node:crypto';
import { chmodSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

import { decode } from '../bridge/lib/msgpack.js';
import { GameProtocolReader } from '../bridge/lib/game-protocol.js';

/** Firebase web API key, straight out of the prod bundle. Public by design. */
const FIREBASE_KEY = 'AIzaSyDPwTbXLMPbIkg6UKr49VrHWwkrOdRh__E';
/**
 * The `HttpV2Paths` enum in the bundle is relative to `/api/v2`, not to the host
 * root. Verified 2026-08-06: `/api/v2/users/me` answers 403 (route exists,
 * unauthorized) while `/users/me`, `/api/users/me`, `/v2/users/me` all 404.
 */
const API_BASE = 'https://api.v2.gather.town/api/v2';
const GAME_SOCKET = 'wss://game-router.v2.gather.town/gather-game-v2';

/** Separate from the bridge's own config so the spike cannot corrupt it. */
const CACHE_FILE = join(homedir(), '.gather-app-bridge-probe.json');

// ---------------------------------------------------------------------------
// msgpack encoder
// ---------------------------------------------------------------------------

/**
 * Copied from `bridge/test/msgpack.test.js`, where it lives as a deliberately
 * test-only helper (`bridge/test/AGENTS.md:29-40`) and is not exported.
 *
 * `bridge/lib/msgpack.js` is decode-only because the bridge never writes to
 * Gather's socket. This probe does, so it needs an encoder. Copied rather than
 * promoted into `lib/` — whether the library should gain an encoder is a real
 * decision, and a spike should not make it by accident.
 */
export function enc(value) {
  if (value === null || value === undefined) return Buffer.from([0xc0]);
  if (value === true) return Buffer.from([0xc3]);
  if (value === false) return Buffer.from([0xc2]);

  if (typeof value === 'number') {
    if (Number.isInteger(value) && value >= 0 && value <= 0x7f) return Buffer.from([value]);
    if (Number.isInteger(value) && value < 0 && value >= -32) return Buffer.from([0x100 + value]);
    if (Number.isInteger(value) && value >= 0 && value <= 0xffffffff) {
      const b = Buffer.alloc(5);
      b[0] = 0xce;
      b.writeUInt32BE(value, 1);
      return b;
    }
    if (Number.isInteger(value)) {
      const b = Buffer.alloc(9);
      b[0] = 0xd3;
      b.writeBigInt64BE(BigInt(value), 1);
      return b;
    }
    const b = Buffer.alloc(9);
    b[0] = 0xcb;
    b.writeDoubleBE(value, 1);
    return b;
  }

  if (typeof value === 'string') {
    const body = Buffer.from(value, 'utf8');
    if (body.length < 32) return Buffer.concat([Buffer.from([0xa0 | body.length]), body]);
    // str32 rather than the test helper's str16: ID tokens run past 64 KB limits
    // in theory, and guessing wrong here would corrupt the auth frame silently.
    const head = Buffer.alloc(5);
    head[0] = 0xdb;
    head.writeUInt32BE(body.length, 1);
    return Buffer.concat([head, body]);
  }

  if (Array.isArray(value)) {
    const items = value.map(enc);
    if (value.length < 16) return Buffer.concat([Buffer.from([0x90 | value.length]), ...items]);
    const head = Buffer.alloc(3);
    head[0] = 0xdc;
    head.writeUInt16BE(value.length, 1);
    return Buffer.concat([head, ...items]);
  }

  if (typeof value === 'object') {
    const keys = Object.keys(value).filter((k) => value[k] !== undefined);
    const parts = keys.flatMap((k) => [enc(k), enc(value[k])]);
    if (keys.length < 16) return Buffer.concat([Buffer.from([0x80 | keys.length]), ...parts]);
    const head = Buffer.alloc(3);
    head[0] = 0xde;
    head.writeUInt16BE(keys.length, 1);
    return Buffer.concat([head, ...parts]);
  }

  throw new Error(`probe encoder cannot handle ${typeof value}`);
}

// ---------------------------------------------------------------------------
// Token cache
// ---------------------------------------------------------------------------

function readCache() {
  try {
    return JSON.parse(readFileSync(CACHE_FILE, 'utf8'));
  } catch {
    return {};
  }
}

function writeCache(patch) {
  const next = { ...readCache(), ...patch };
  writeFileSync(CACHE_FILE, `${JSON.stringify(next, null, 2)}\n`);
  // Same posture as bridge/lib/paths.js:49 — these are live credentials.
  chmodSync(CACHE_FILE, 0o600);
  return next;
}

/** Firebase uid lives in the ID token; no need to ask the API for it. */
function uidFromIdToken(idToken) {
  const [, payload] = idToken.split('.');
  if (!payload) return null;
  const json = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
  return json.user_id ?? json.sub ?? null;
}

function expiryOf(idToken) {
  try {
    const [, payload] = idToken.split('.');
    const json = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
    return json.exp ? json.exp * 1000 : 0;
  } catch {
    return 0;
  }
}

/**
 * Returns a valid ID token, refreshing if it is within two minutes of expiry.
 * ID tokens last ~1h, so any daemon built on this needs exactly this path — it
 * is the thing most likely to be got wrong and not noticed for an hour.
 */
async function idToken() {
  const cache = readCache();
  if (!cache.refreshToken) {
    throw new Error('not signed in — run: node tool/probe-connect.mjs login');
  }
  if (cache.idToken && expiryOf(cache.idToken) - Date.now() > 120_000) {
    return cache.idToken;
  }

  const res = await fetch(`https://securetoken.googleapis.com/v1/token?key=${FIREBASE_KEY}`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'refresh_token',
      refresh_token: cache.refreshToken,
    }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(`token refresh failed (${res.status}): ${JSON.stringify(body)}`);

  const next = writeCache({
    idToken: body.id_token,
    refreshToken: body.refresh_token ?? cache.refreshToken,
  });
  console.log(`refreshed id token, valid ${Math.round((expiryOf(next.idToken) - Date.now()) / 60000)} min`);
  return next.idToken;
}

async function api(path, { method = 'GET', body } = {}) {
  const token = await idToken();
  const res = await fetch(`${API_BASE}${path}`, {
    method,
    headers: {
      authorization: `Bearer ${token}`,
      ...(body ? { 'content-type': 'application/json' } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    parsed = text;
  }
  if (!res.ok) throw new Error(`${method} ${path} -> ${res.status}: ${text.slice(0, 400)}`);
  return parsed;
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

/** Where the GatherV2 desktop client persists its Firebase session. */
const DESKTOP_IDB = join(
  homedir(),
  'Library/Application Support/GatherV2/IndexedDB/https_app.v2.gather.town_0.indexeddb.leveldb',
);

/**
 * Pulls the refresh token out of the desktop client's IndexedDB.
 *
 * Firebase persists the signed-in user under `firebase:authUser:<key>:[DEFAULT]`
 * in the `firebaseLocalStorage` store. The value is a Blink structured-clone
 * blob, but its strings are plain: tag `0x22`, a LEB128 length, then the bytes.
 * That is enough to find `refreshToken` without a LevelDB library — we are not
 * decoding the record structure, just locating a known key inside it.
 *
 * Why bother: it is the only bootstrap that needs no login flow and no second
 * account. It yields exactly the identity the desktop client uses, which is what
 * the eviction experiment needs. And because refresh tokens are long-lived, this
 * is a one-time read — after it, nothing here depends on the desktop client, the
 * debug port, or CDP ever again.
 *
 * This reads the user's live credential from their own machine into a 0600 file.
 * Same trust boundary the bridge already operates in, but worth stating.
 */
function desktopRefreshTokens() {
  /** Blink string: expects tag 0x22 at `i`, returns {value, end}. */
  const readString = (buf, i) => {
    if (buf[i] !== 0x22) return null;
    let len = 0;
    let shift = 0;
    let j = i + 1;
    for (; j < buf.length; j++) {
      len |= (buf[j] & 0x7f) << shift;
      if ((buf[j] & 0x80) === 0) {
        j++;
        break;
      }
      shift += 7;
      if (shift > 28) return null;
    }
    if (len <= 0 || len > 4096 || j + len > buf.length) return null;
    return { value: buf.slice(j, j + len).toString('latin1'), end: j + len };
  };

  const found = [];
  let files;
  try {
    files = readdirSync(DESKTOP_IDB).filter((f) => /\.(log|ldb)$/.test(f));
  } catch {
    throw new Error(`cannot read the desktop session at ${DESKTOP_IDB}`);
  }

  for (const file of files) {
    const buf = readFileSync(join(DESKTOP_IDB, file));
    for (let at = buf.indexOf('refreshToken'); at !== -1; at = buf.indexOf('refreshToken', at + 1)) {
      const token = readString(buf, at + 'refreshToken'.length);
      // Firebase refresh tokens are long and base64url-ish; anything else is a
      // different field that merely happens to sit next to the name.
      if (token && token.value.length > 100 && /^[A-Za-z0-9_-]+$/.test(token.value)) {
        found.push({ file, token: token.value });
      }
    }
  }
  // Newest last: the .log write-ahead holds fresher state than the .ldb table.
  return found.reverse();
}

/**
 * Seeds the token cache from the desktop client. Tries each candidate against
 * Google's refresh endpoint and keeps the first that actually works, which is
 * simpler and more honest than guessing which LevelDB file is current.
 */
async function adopt() {
  const candidates = desktopRefreshTokens();
  if (!candidates.length) {
    throw new Error(
      'no refresh token found — is GatherV2 signed in? Looked in:\n' + `  ${DESKTOP_IDB}`,
    );
  }
  console.log(`found ${candidates.length} candidate token(s) in the desktop session`);

  const seen = new Set();
  for (const { file, token } of candidates) {
    if (seen.has(token)) continue;
    seen.add(token);

    const res = await fetch(`https://securetoken.googleapis.com/v1/token?key=${FIREBASE_KEY}`, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ grant_type: 'refresh_token', refresh_token: token }),
    });
    const body = await res.json();
    if (!res.ok) {
      console.log(`  ${file}: rejected (${body?.error?.message ?? res.status})`);
      continue;
    }

    writeCache({
      idToken: body.id_token,
      refreshToken: body.refresh_token ?? token,
      uid: body.user_id ?? uidFromIdToken(body.id_token),
      adoptedFrom: file,
    });
    console.log(`  ${file}: accepted`);
    console.log(`adopted desktop session, uid ${String(body.user_id).slice(0, 8)}…`);
    console.log(`tokens cached at ${CACHE_FILE} (0600)`);
    return;
  }
  throw new Error('every candidate token was rejected — sign in to GatherV2 again and retry');
}

/**
 * Firebase anonymous sign-in — `accounts:signUp` with `returnSecureToken`, which
 * is what the web `signInAnonymously()` does under the hood. Returns an ID token
 * for a throwaway anonymous user.
 *
 * This exists because `/auth/otp-requests` itself is authenticated: hitting it
 * cold returns 403 "Authentication is required". The client signs in anonymously
 * first and requests the OTP as that anonymous user (verified 2026-08-06).
 */
async function signInAnonymously() {
  const res = await fetch(
    `https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${FIREBASE_KEY}`,
    {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ returnSecureToken: true }),
    },
  );
  const body = await res.json();
  if (!res.ok) throw new Error(`anonymous sign-in failed (${res.status}): ${JSON.stringify(body)}`);
  return body.idToken;
}

/**
 * Email OTP sign-in. Anonymous first, then the OTP is requested and verified as
 * that anonymous user. The verify response shape is unknown (inferred to be a
 * Firebase custom token because `signInWithCustomToken` is in the bundle), so
 * this dumps its keys before trying to interpret it.
 */
async function login() {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  try {
    const email = (await rl.question('email: ')).trim();
    if (!email) throw new Error('no email given');

    console.log('signing in anonymously to authorise the OTP request…');
    const anonToken = await signInAnonymously();

    const request = await fetch(`${API_BASE}/auth/otp-requests`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${anonToken}` },
      body: JSON.stringify({ email }),
    });
    const requestBody = await request.text();
    console.log(`POST /auth/otp-requests -> ${request.status} ${requestBody.slice(0, 300)}`);
    if (!request.ok) throw new Error('could not request an OTP — body above');

    const code = (await rl.question('code from the email: ')).trim();
    const verify = await fetch(`${API_BASE}/auth/otp-requests/verify`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${anonToken}` },
      body: JSON.stringify({ email, otp: code }),
    });
    const verified = await verify.json();
    if (!verify.ok) throw new Error(`verify failed (${verify.status}): ${JSON.stringify(verified)}`);

    // The shape is the unknown. Log the keys, never the values.
    console.log('verify response keys:', Object.keys(verified).join(', '));

    const custom =
      verified.customToken ?? verified.token ?? verified.firebaseToken;

    let session;
    if (verified.idToken && verified.refreshToken) {
      // Verify already returned a usable Firebase session — no swap needed. This
      // is the case if verify upgrades the anonymous account in place.
      session = verified;
    } else if (custom) {
      // Verify returned a Firebase custom token; exchange it for a real session.
      const swap = await fetch(
        `https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=${FIREBASE_KEY}`,
        {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ token: custom, returnSecureToken: true }),
        },
      );
      session = await swap.json();
      if (!swap.ok) throw new Error(`custom-token swap failed: ${JSON.stringify(session)}`);
    } else {
      console.log(JSON.stringify(verified, null, 2));
      throw new Error('no token field recognised in the verify response — see keys above');
    }

    writeCache({
      email,
      idToken: session.idToken,
      refreshToken: session.refreshToken,
      uid: session.localId ?? uidFromIdToken(session.idToken),
    });
    console.log(`signed in, uid ${String(session.localId).slice(0, 8)}…, tokens cached at ${CACHE_FILE}`);
  } finally {
    rl.close();
  }
}

async function whoami() {
  const me = await api('/users/me');
  console.log(JSON.stringify(me, null, 2));
}

/**
 * `/users/me/recent-spaces` answers a map keyed by space id, not a list:
 *
 *   { "<spaceId>": { id, name, lastVisited, currentUserRole, spaceUserId } }
 *
 * Note `spaceUserId` — that is our own SpaceUser id for the space, handed over
 * before we open any socket. `GameProtocolReader` currently derives the same
 * thing the hard way, by matching a `Connection` row's `authUserId` against a
 * uid read out of IndexedDB (`bridge/lib/game-protocol.js:158-180`). A direct
 * client can just be told.
 */
async function spaces() {
  const recent = await api('/users/me/recent-spaces');
  const rows = Array.isArray(recent) ? recent : Object.values(recent ?? {});
  if (!rows.length) {
    console.log('no recent spaces returned; raw response:');
    console.log(JSON.stringify(recent, null, 2));
    return;
  }
  for (const row of rows) {
    console.log(
      `${row.id ?? '?'}  ${(row.name ?? '').padEnd(24)} role=${row.currentUserRole ?? '?'}  me=${row.spaceUserId ?? '?'}`,
    );
  }
}

/**
 * The real handshake, captured off the desktop client's own outbound frames via
 * CDP `Network.webSocketFrameSent` (2026-08-06). Not guesses any more.
 *
 * Three corrections to what we assumed:
 *   - `Authenticate` wraps the token: `credential: {type:'JWT', jwt}`. A flat
 *     `token` field is ignored — the server does not answer, it just keeps
 *     heartbeating and eventually drops you.
 *   - `Subscribe` takes **no arguments at all**. You cannot narrow the stream by
 *     model from the client; `ModelSubscription` is server-side bookkeeping.
 *   - State is loaded by an `Action`, not by connecting. `loadSpaceUser` is what
 *     materialises your SpaceUser and starts the state dump.
 *
 * And the important structural find: **`enterSpace` is a separate action.**
 * `loadSpaceUser` gets you the space's state; `enterSpace` is what actually puts
 * your avatar in it and flips `Connection.entered`. Skipping it is a real
 * observer mode, not a hypothesis.
 */
function handshake({ token, spaceId, spaceUserId, enter }) {
  const action = (name, args) => ({
    type: 'Action',
    txnId: randomUUID(),
    action: name,
    args,
  });

  return [
    { type: 'Authenticate', credential: { type: 'JWT', jwt: token } },
    { type: 'ConnectToSpace', spaceId },
    { type: 'Subscribe' },
    action('loadSpaceUser', [
      'SpaceUser',
      null,
      // clientPlatform is honest about what we are; the desktop client sends
      // 'Desktop'. connectionTarget 'OfficeView' is what it uses too.
      { connectionTarget: 'OfficeView', clientPlatform: 'Desktop' },
    ]),
    // Only when explicitly asked for: this is the line between watching and
    // joining, and joining is what puts an avatar in the space.
    ...(enter && spaceUserId ? [action('enterSpace', ['SpaceUser', spaceUserId])] : []),
  ];
}

async function connect(args) {
  const spaceId = args.space;
  if (!spaceId) throw new Error('need --space <uuid>');
  if (!args.yes) {
    console.error(
      [
        '',
        'REFUSING TO CONNECT without --yes.',
        '',
        'A second connection on the same account MAY evict your desktop Gather',
        'session (close 4031, unconfirmed — docs/gather-api.md, Unverified #1).',
        `Space to connect to: ${spaceId}`,
        '',
        'Use a scratch space you own, then re-run with --yes.',
        '',
      ].join('\n'),
    );
    process.exitCode = 1;
    return;
  }

  const token = await idToken();
  const authUserId = readCache().uid ?? uidFromIdToken(token);
  const enter = args.enter === true; // default false: watch without joining
  const seconds = Number(args.seconds ?? 30);

  // Our own SpaceUser id, needed only for `enterSpace`. REST hands it over, so
  // there is no need to resolve it from a Connection row first.
  let spaceUserId = null;
  try {
    const recent = await api('/users/me/recent-spaces');
    spaceUserId = Object.values(recent ?? {}).find((s) => s?.id === spaceId)?.spaceUserId ?? null;
  } catch (error) {
    console.log(`could not look up our spaceUserId: ${error.message}`);
  }

  const url = `${GAME_SOCKET}?spaceId=${encodeURIComponent(spaceId)}&authUserId=${encodeURIComponent(authUserId)}`;
  console.log(
    `connecting as uid ${String(authUserId).slice(0, 8)}…  enterSpace=${enter}  me=${spaceUserId ?? 'unknown'}`,
  );
  console.log(url.replace(authUserId, `${String(authUserId).slice(0, 8)}…`));

  const reader = new GameProtocolReader({ log: (m) => console.log(`  reader: ${m}`) });
  reader.authUserId = authUserId;
  reader.noteSocketUrl(url);

  const ws = new WebSocket(url);
  ws.binaryType = 'arraybuffer';
  const seen = new Map();
  let frames = 0;

  ws.addEventListener('open', () => {
    console.log('socket open; sending handshake');
    for (const frame of handshake({ token, spaceId, spaceUserId, enter })) {
      console.log(`  -> ${frame.type}`);
      ws.send(enc(frame));
    }
  });

  ws.addEventListener('message', (event) => {
    frames++;
    let frame;
    try {
      frame = decode(Buffer.from(event.data));
    } catch (error) {
      console.log(`  <- undecodable (${event.data.byteLength}B): ${error.message}`);
      return;
    }
    const type = frame?.type ?? '(untyped)';
    seen.set(type, (seen.get(type) ?? 0) + 1);

    // Heartbeats are the bulk of traffic and carry nothing; everything else is
    // the thing we are here to learn, so log it in full the first time.
    if (type !== 'Heartbeat' && seen.get(type) === 1) {
      console.log(`  <- ${type}  keys: ${Object.keys(frame ?? {}).join(', ')}`);
      const preview = JSON.stringify(frame, (k, v) => (typeof v === 'bigint' ? String(v) : v));
      console.log(`     ${preview.slice(0, 600)}${preview.length > 600 ? '…' : ''}`);
    }
    reader.ingest(frame);
  });

  ws.addEventListener('error', () => console.log('  socket error'));

  const closed = new Promise((resolve) => {
    ws.addEventListener('close', (event) => {
      // THE measurement for the eviction experiment.
      console.log(`\nsocket closed: code=${event.code} reason=${JSON.stringify(event.reason)}`);
      resolve();
    });
  });

  const timer = setTimeout(() => ws.close(), seconds * 1000);
  await closed;
  clearTimeout(timer);

  console.log(`\n${frames} frames; types: ${[...seen].map(([t, n]) => `${t}×${n}`).join(', ') || 'none'}`);
  console.log(`reader stats: ${JSON.stringify(reader.stats())}`);

  // roster() answers {selfId, rows}, not an array.
  const { selfId, rows } = reader.roster();
  console.log(`\nroster: ${rows.length} players (selfId ${selfId ?? 'unresolved'})`);
  for (const player of rows.slice(0, 25)) {
    console.log(
      `  ${player.id?.slice(0, 8)}  ${(player.name ?? '?').padEnd(22)} ${player.x},${player.y}`,
    );
  }
}

/**
 * What does the wire actually tell us about the floor plan?
 *
 * Party mode currently guesses at walkability by remembering tiles it has seen a
 * body on, because the real collision data has never been decoded. But the state
 * dump already carries the whole map — `MapArea` ×93, `MapObject` ×1140,
 * `CatalogItemVariant` ×477 with a `collision` field — we simply throw it away in
 * `GameProtocolReader`. The blocker is not access, it is that nobody has ever
 * looked at how `collision` is encoded.
 *
 * So this looks. It connects read-only, keeps the map models the reader drops, and
 * prints the shape of the fields that a real walkability grid would have to be
 * built from. It also tries the obvious REST routes, because a served map would be
 * simpler than reconstructing one.
 *
 * Read-only on the wire, exactly like `connect`: handshake, listen, close.
 */
async function map(args) {
  const spaceId = args.space;
  if (!spaceId) throw new Error('need --space <uuid>');
  if (!args.yes) {
    console.error(
      [
        '',
        'REFUSING TO CONNECT without --yes.',
        '',
        'Same risk as `connect`: a second connection on the same account MAY evict',
        `your desktop session. Space: ${spaceId}`,
        '',
      ].join('\n'),
    );
    process.exitCode = 1;
    return;
  }

  const token = await idToken();
  const authUserId = readCache().uid ?? uidFromIdToken(token);
  const seconds = Number(args.seconds ?? 30);

  // --- route 1: is it served over REST? -----------------------------------
  console.log('REST routes:');
  for (const path of [
    `/spaces/${spaceId}`,
    `/spaces/${spaceId}/maps`,
    `/spaces/${spaceId}/floors`,
    `/spaces/${spaceId}/map`,
  ]) {
    try {
      const body = await api(path);
      const preview = JSON.stringify(body).slice(0, 300);
      console.log(`  200 ${path}\n      ${preview}…`);
    } catch (error) {
      console.log(`  --- ${path}: ${error.message.slice(0, 120)}`);
    }
  }

  // --- route 2: what the state dump already hands us ----------------------
  const WANTED = new Set([
    'MapArea',
    'MapObject',
    'CatalogItemVariant',
    'FloorMap',
    'MapEntityIdentifier',
  ]);
  const rows = new Map([...WANTED].map((m) => [m, []]));

  const url = `${GAME_SOCKET}?spaceId=${encodeURIComponent(spaceId)}&authUserId=${encodeURIComponent(authUserId)}`;
  const ws = new WebSocket(url);
  ws.binaryType = 'arraybuffer';

  ws.addEventListener('open', () => {
    for (const frame of handshake({ token, spaceId, spaceUserId: null, enter: false })) {
      ws.send(enc(frame));
    }
  });

  ws.addEventListener('message', (event) => {
    let frame;
    try {
      frame = decode(Buffer.from(event.data));
    } catch {
      return;
    }
    const patches = [
      ...(Array.isArray(frame?.fullStatePatches) ? frame.fullStatePatches : []),
      ...(Array.isArray(frame?.patches) ? frame.patches : []),
    ];
    for (const patch of patches) {
      if (patch?.op !== 'addmodel' || !WANTED.has(patch.model)) continue;
      rows.get(patch.model).push(patch.data);
    }
  });

  const closed = new Promise((resolve) => ws.addEventListener('close', resolve));
  const timer = setTimeout(() => ws.close(), seconds * 1000);
  await closed;
  clearTimeout(timer);

  console.log('\nmap models in the state dump:');
  for (const [model, list] of rows) console.log(`  ${model.padEnd(22)} ${list.length}`);

  // msgpack ext values decode to objects carrying Symbol keys, and `undefined`
  // (ext-4) comes back as a Symbol outright, so nothing here may assume a value
  // survives String().
  const show = (value) => {
    if (typeof value === 'symbol') return `«${String(value)}»`;
    if (value === null || value === undefined) return String(value);
    if (typeof value === 'bigint') return `${value}n`;
    if (typeof value !== 'object') return `${typeof value} ${JSON.stringify(value)}`;
    try {
      return JSON.stringify(value, (k, v) =>
        typeof v === 'symbol' ? String(v) : typeof v === 'bigint' ? String(v) : v,
      );
    } catch (error) {
      return `<unstringifiable ${error.message}>`;
    }
  };
  const kind = (value) =>
    typeof value === 'symbol'
      ? 'symbol'
      : value === null
        ? 'null'
        : Array.isArray(value)
          ? 'array'
          : typeof value;

  // THE question: how is walkability encoded?
  const variants = rows.get('CatalogItemVariant');
  const withPoints = variants.filter((v) => v?.collision?.points?.length);
  console.log(
    `\ncollision (${variants.length} variants; ${withPoints.length} carry a non-empty points list):`,
  );
  for (const v of withPoints.slice(0, 6)) {
    console.log(`  points  ${show(v.collision.points).slice(0, 200)}`);
    console.log(
      `     dimensionsInPixels ${show(v.dimensionsInPixels)}  origin ${v.originX},${v.originY}  sittable ${show(v.sittable)}`,
    );
  }
  // The distribution matters: if most variants collide over their whole box, a
  // points list may be the exception rather than the rule.
  const counts = new Map();
  for (const v of variants) {
    const n = v?.collision?.points?.length ?? -1;
    counts.set(n, (counts.get(n) ?? 0) + 1);
  }
  console.log(
    `  points-per-variant: ${[...counts].sort((a, b) => a[0] - b[0]).map(([n, c]) => `${n === -1 ? 'none' : n}×${c}`).join(' ')}`,
  );

  for (const model of ['FloorMap', 'MapArea', 'MapObject']) {
    const list = rows.get(model);
    if (!list.length) continue;
    console.log(`\n${model} — field shapes across ${list.length} rows:`);
    const fields = new Map();
    for (const row of list) {
      for (const [k, v] of Object.entries(row ?? {})) {
        if (!fields.has(k)) fields.set(k, new Set());
        fields.get(k).add(kind(v));
      }
    }
    for (const [k, kinds] of fields) console.log(`  ${k.padEnd(24)} ${[...kinds].join('|')}`);
    console.log(`  sample: ${show(list[0]).slice(0, 700)}`);
  }

  // The base area is the whole floor, and its dimensions are the grid we would be
  // painting walkability onto.
  const floor = rows.get('FloorMap')[0];
  const base = rows.get('MapArea').find((a) => a?.id === floor?.baseAreaId);
  console.log(`\nbase area: ${show(base ?? null).slice(0, 400)}`);
}

/**
 * Turn the map models into a walkable grid, and check the answer against reality.
 *
 * The decoding, as read off `map`:
 *
 *  - `FloorMap.baseAreaId` names the base `MapArea`, whose `dimensionsInTiles` is
 *    the whole grid (124×82 here).
 *  - `MapArea` and `MapObject` both carry `relativeX/relativeY` against a parent —
 *    `parentAreaId` or `parentObjectId` — so an absolute position is the sum up
 *    the chain. Objects nest inside objects, not just inside areas.
 *  - `CatalogItemVariant.collision.points` is a list of tile offsets the object
 *    blocks. 341 of 477 variants block nothing at all; the rest block 1–6 tiles.
 *    Offsets are near-integers with a sub-tile render nudge (-0.0625, 0.9375), so
 *    they round to tiles.
 *
 * The check is what makes this trustworthy: **every member of the space is
 * standing somewhere**, so if the derived grid says a tile somebody occupies is a
 * wall, the decoding is wrong. That turns 111 live positions into a test.
 */
async function walkable(args) {
  const spaceId = args.space;
  if (!spaceId) throw new Error('need --space <uuid>');
  if (!args.yes) throw new Error('refusing without --yes (same risk as `connect`)');

  const token = await idToken();
  const authUserId = readCache().uid ?? uidFromIdToken(token);
  const seconds = Number(args.seconds ?? 25);

  const KEEP = new Set(['MapArea', 'MapObject', 'CatalogItemVariant', 'CatalogItem', 'FloorMap', 'SpaceUser']);
  const rows = new Map([...KEEP].map((m) => [m, new Map()]));

  const url = `${GAME_SOCKET}?spaceId=${encodeURIComponent(spaceId)}&authUserId=${encodeURIComponent(authUserId)}`;
  const ws = new WebSocket(url);
  ws.binaryType = 'arraybuffer';
  ws.addEventListener('open', () => {
    for (const frame of handshake({ token, spaceId, spaceUserId: null, enter: false })) {
      ws.send(enc(frame));
    }
  });
  ws.addEventListener('message', (event) => {
    let frame;
    try {
      frame = decode(Buffer.from(event.data));
    } catch {
      return;
    }
    for (const patch of [
      ...(Array.isArray(frame?.fullStatePatches) ? frame.fullStatePatches : []),
      ...(Array.isArray(frame?.patches) ? frame.patches : []),
    ]) {
      if (patch?.op !== 'addmodel' || !KEEP.has(patch.model)) continue;
      if (patch.data?.id) rows.get(patch.model).set(patch.data.id, patch.data);
    }
  });
  const closed = new Promise((resolve) => ws.addEventListener('close', resolve));
  const timer = setTimeout(() => ws.close(), seconds * 1000);
  await closed;
  clearTimeout(timer);

  // One capture, many hypotheses: getting the rounding rule right takes several
  // passes over the same data, and each pass should not be another socket into
  // somebody's workspace.
  if (typeof args.dump === 'string') {
    const plain = JSON.stringify(
      Object.fromEntries([...rows].map(([m, byId]) => [m, [...byId.values()]])),
      (k, v) => (typeof v === 'symbol' ? undefined : typeof v === 'bigint' ? String(v) : v),
    );
    writeFileSync(args.dump, plain);
    console.log(`wrote ${args.dump} (${(plain.length / 1e6).toFixed(1)} MB)`);
  }

  const areas = rows.get('MapArea');
  const objects = rows.get('MapObject');
  const variants = rows.get('CatalogItemVariant');
  const floor = [...rows.get('FloorMap').values()][0];
  const base = areas.get(floor?.baseAreaId);
  const size = base?.dimensionsInTiles;
  if (!size) throw new Error('no base area — cannot size the grid');

  const str = (v) => (typeof v === 'string' ? v : null); // msgpack undefined is a Symbol
  const live = (row) => row && typeof row.deletedAt !== 'string';

  /** Absolute tile position, walking up the parent chain. */
  const originOf = (row, depth = 0) => {
    if (!row || depth > 24) return null;
    const x = Number(row.relativeX ?? 0);
    const y = Number(row.relativeY ?? 0);
    const parentId = str(row.parentObjectId) ?? str(row.parentAreaId);
    if (!parentId) return { x, y };
    const parent = objects.get(parentId) ?? areas.get(parentId);
    if (!parent) return null; // an unresolvable chain must not become a wrong tile
    const up = originOf(parent, depth + 1);
    return up && { x: up.x + x, y: up.y + y };
  };

  const blocked = new Set();
  let placed = 0;
  let unresolved = 0;
  for (const object of objects.values()) {
    if (!live(object)) continue;
    const points = variants.get(object.catalogItemVariantId)?.collision?.points;
    if (!Array.isArray(points) || !points.length) continue;
    const at = originOf(object);
    if (!at) {
      unresolved++;
      continue;
    }
    placed++;
    for (const p of points) {
      blocked.add(`${Math.round(at.x + Number(p.x ?? 0))},${Math.round(at.y + Number(p.y ?? 0))}`);
    }
  }

  const total = size.width * size.height;
  console.log(`grid ${size.width}x${size.height} = ${total} tiles`);
  console.log(`${placed} colliding objects placed, ${unresolved} with an unresolvable parent`);
  console.log(`blocked ${blocked.size}  ->  walkable ${total - blocked.size}`);

  // THE check: everybody is standing somewhere, so nobody may be inside a wall.
  const people = [...rows.get('SpaceUser').values()].filter((u) => u?.position);
  const inside = people.filter((u) =>
    blocked.has(`${Math.round(u.position.x)},${Math.round(u.position.y)}`),
  );
  console.log(
    `\n${people.length} members with a position; ${inside.length} of them stand on a tile we call blocked`,
  );
  for (const u of inside.slice(0, 8)) {
    console.log(`  ${(u.name ?? u.id).slice(0, 28).padEnd(28)} at ${u.position.x},${u.position.y}`);
  }

  // Eyeball it: a real office should read as rooms and corridors, not noise.
  console.log('\ntop-left 100x40 (# blocked, · walkable, o somebody standing):');
  const standing = new Set(people.map((u) => `${Math.round(u.position.x)},${Math.round(u.position.y)}`));
  for (let y = 0; y < Math.min(40, size.height); y++) {
    let line = '';
    for (let x = 0; x < Math.min(100, size.width); x++) {
      const k = `${x},${y}`;
      line += standing.has(k) ? 'o' : blocked.has(k) ? '#' : '·';
    }
    console.log('  ' + line);
  }
}

// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    const token = argv[i];
    if (!token.startsWith('--')) continue;
    const key = token.slice(2);
    const next = argv[i + 1];
    if (next && !next.startsWith('--')) {
      args[key] = next;
      i++;
    } else {
      args[key] = true;
    }
  }
  return args;
}

// Guarded so the encoder can be imported and checked against the real decoder
// without the CLI firing on import.
if (import.meta.main) {
  const [command, ...rest] = process.argv.slice(2);
  const args = parseArgs(rest);

  try {
    switch (command) {
      case 'adopt':
        await adopt();
        break;
      case 'login':
        await login();
        break;
      case 'whoami':
        await whoami();
        break;
      case 'refresh':
        writeCache({ idToken: null });
        await idToken();
        break;
      case 'spaces':
        await spaces();
        break;
      case 'connect':
        await connect(args);
        break;
      case 'map':
        await map(args);
        break;
      case 'walkable':
        await walkable(args);
        break;
      default:
        console.log(
          'commands: adopt | login | whoami | refresh | spaces | connect --space <uuid> --yes | map/walkable --space <uuid> --yes',
        );
        process.exitCode = 1;
    }
  } catch (error) {
    console.error(`\n${error.message}`);
    process.exitCode = 1;
  }
}
