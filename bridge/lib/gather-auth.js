/**
 * Gather's own authentication, for the direct collector.
 *
 * The CDP collector never needed this: it read the desktop client's already
 * authenticated socket. Connecting ourselves means holding a real credential.
 *
 * ## How we get one, and why not by logging in
 *
 * Gather is a Firebase Auth app. The obvious route — email OTP via
 * `POST /auth/otp-requests` — does not work for an existing account: that
 * endpoint is itself authenticated (403 without a token, so you must sign in
 * anonymously first), and `verify` then accepts a correct code and fails
 * `404 "No UserAccount found"`. See docs/gather-api.md.
 *
 * So we adopt the session the desktop client already has. Firebase persists the
 * signed-in user in IndexedDB under `firebase:authUser:<key>:[DEFAULT]`, which
 * includes a long-lived refresh token. Reading it once is enough: from then on
 * we mint our own ID tokens and never touch the desktop client, the debug port
 * or CDP again.
 *
 * ## Trust
 *
 * This reads the user's live Gather credential off their own disk and stores a
 * refresh token in `~/.gather-app-bridge.json` at 0600 — the same file and the
 * same permissions as the pairing token. It grants the bridge the user's own
 * Gather identity, which is precisely what it needs to see the user's own space,
 * and no more than the desktop client on the same machine already has. It is
 * never sent anywhere except to Google's token endpoint and Gather's own hosts.
 */

import { readFileSync, readdirSync } from 'node:fs';

import { gatherIdbDir, readConfig, writeConfig } from './paths.js';

/** Firebase web API key, from the prod bundle. Public by design for web apps. */
export const FIREBASE_KEY = 'AIzaSyDPwTbXLMPbIkg6UKr49VrHWwkrOdRh__E';

/**
 * REST base. The `/api/v2` prefix is not part of the host constant in Gather's
 * own bundle: `/api/v2/users/me` answers 403, while `/users/me` answers 404.
 */
export const API_BASE = 'https://api.v2.gather.town/api/v2';

/** Refresh this many ms before expiry, so a request never races the deadline. */
const REFRESH_MARGIN_MS = 120_000;

/**
 * Finds candidate refresh tokens in the desktop client's IndexedDB.
 *
 * The value is a Blink structured-clone blob. We do not decode the record
 * structure — only locate a known key inside it, which is enough because Blink
 * writes strings plainly: tag `0x22`, a LEB128 length, then the bytes.
 *
 * Returns newest-first. Several may be present (the `.log` write-ahead and the
 * `.ldb` table can both hold one, and old sessions linger), so callers should
 * try them in order rather than trusting the first.
 */
export function desktopRefreshTokens(dir = gatherIdbDir) {
  let files;
  try {
    files = readdirSync(dir).filter((name) => /\.(log|ldb)$/.test(name));
  } catch {
    return [];
  }

  // LevelDB writes land in the `.log` write-ahead file first and are only later
  // compacted into a `.ldb` table, so after a token refresh the current token is
  // in the `.log` and the `.ldb` still holds the previous one. Read `.log` first.
  files.sort((a, b) => Number(a.endsWith('.ldb')) - Number(b.endsWith('.ldb')));

  const found = [];
  for (const name of files) {
    let buf;
    try {
      buf = readFileSync(`${dir}/${name}`);
    } catch {
      continue;
    }
    const key = 'refreshToken';
    const inFile = [];
    for (let at = buf.indexOf(key); at !== -1; at = buf.indexOf(key, at + 1)) {
      const token = readBlinkString(buf, at + key.length);
      // Firebase refresh tokens are long and base64url-ish. Anything shorter is
      // a different field that merely sits next to the same name.
      if (token && token.length > 100 && /^[A-Za-z0-9_-]+$/.test(token)) {
        inFile.push({ file: name, token });
      }
    }
    // Within one file records are appended, so the last occurrence is the newest.
    found.push(...inFile.reverse());
  }
  return found;
}

/** Reads a Blink structured-clone string at `i`, or null if that is not one. */
function readBlinkString(buf, i) {
  if (buf[i] !== 0x22) return null;
  let length = 0;
  let shift = 0;
  let j = i + 1;
  for (; j < buf.length; j++) {
    length |= (buf[j] & 0x7f) << shift;
    if ((buf[j] & 0x80) === 0) {
      j++;
      break;
    }
    shift += 7;
    if (shift > 28) return null;
  }
  if (length <= 0 || length > 4096 || j + length > buf.length) return null;
  return buf.subarray(j, j + length).toString('latin1');
}

/** Exchanges a refresh token for a fresh ID token. Throws with Google's reason. */
async function exchange(refreshToken) {
  const res = await fetch(`https://securetoken.googleapis.com/v1/token?key=${FIREBASE_KEY}`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'refresh_token', refresh_token: refreshToken }),
    signal: AbortSignal.timeout(15_000),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(body?.error?.message ?? `token endpoint returned ${res.status}`);
  }
  return {
    idToken: body.id_token,
    // Google may hand back a rotated refresh token; keep whichever is current.
    refreshToken: body.refresh_token ?? refreshToken,
    uid: body.user_id ?? null,
  };
}

/**
 * Copies the desktop client's session into our own config.
 *
 * Tries each candidate against Google and keeps the first that works, rather
 * than guessing which LevelDB file is current. Returns `{uid, file}`.
 */
export async function adoptDesktopSession({ log = () => {} } = {}) {
  const candidates = desktopRefreshTokens();
  if (candidates.length === 0) {
    throw new Error(
      'no Gather session found on this machine — sign in to the GatherV2 desktop app first',
    );
  }

  const tried = new Set();
  const reasons = [];
  for (const { file, token } of candidates) {
    if (tried.has(token)) continue;
    tried.add(token);
    try {
      const session = await exchange(token);
      const config = readConfig();
      writeConfig({
        ...config,
        gather: {
          refreshToken: session.refreshToken,
          idToken: session.idToken,
          uid: session.uid ?? uidFromIdToken(session.idToken),
        },
      });
      log(`gather auth: adopted the desktop session from ${file}`);
      return { uid: session.uid ?? uidFromIdToken(session.idToken), file };
    } catch (error) {
      reasons.push(`${file}: ${error.message}`);
    }
  }
  throw new Error(`every stored session was rejected (${reasons.join('; ')})`);
}

/** True when we hold a refresh token, without touching the network. */
export function hasGatherSession() {
  return typeof readConfig().gather?.refreshToken === 'string';
}

/** The adopted Firebase uid, if we have one. */
export function gatherUid() {
  const gather = readConfig().gather;
  return gather?.uid ?? (gather?.idToken ? uidFromIdToken(gather.idToken) : null);
}

/**
 * A currently-valid ID token, refreshing when it is close to expiry.
 *
 * ID tokens last about an hour, so for a daemon this is the path that actually
 * matters — a collector that only worked for the first hour would look fine in
 * testing and fail overnight.
 */
export async function getIdToken({ log = () => {} } = {}) {
  const config = readConfig();
  const gather = config.gather;
  if (!gather?.refreshToken) {
    throw new Error('no Gather session — run `gather-bridge adopt`');
  }
  if (gather.idToken && expiryOf(gather.idToken) - Date.now() > REFRESH_MARGIN_MS) {
    return gather.idToken;
  }

  const session = await exchange(gather.refreshToken);
  writeConfig({
    ...readConfig(),
    gather: {
      refreshToken: session.refreshToken,
      idToken: session.idToken,
      uid: session.uid ?? gather.uid ?? uidFromIdToken(session.idToken),
    },
  });
  log('gather auth: refreshed the id token');
  return session.idToken;
}

/** One authenticated GET against Gather's REST API. */
export async function apiGet(path, { log = () => {} } = {}) {
  const token = await getIdToken({ log });
  const res = await fetch(`${API_BASE}${path}`, {
    headers: { authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(15_000),
  });
  if (!res.ok) throw new Error(`GET ${path} returned ${res.status}`);
  return res.json();
}

/**
 * The spaces this account has been in recently.
 *
 * Answers a map keyed by space id, not a list. Each entry carries `spaceUserId`
 * — our own SpaceUser id for that space — which is the identity the protocol
 * reader otherwise has to derive from a `Connection` row.
 */
export async function recentSpaces(options) {
  const body = await apiGet('/users/me/recent-spaces', options);
  return Object.values(body ?? {}).filter((row) => row && typeof row.id === 'string');
}

/** Firebase puts the uid in the ID token; no API call needed. */
export function uidFromIdToken(idToken) {
  return claimsOf(idToken)?.user_id ?? claimsOf(idToken)?.sub ?? null;
}

function expiryOf(idToken) {
  const exp = claimsOf(idToken)?.exp;
  return typeof exp === 'number' ? exp * 1000 : 0;
}

function claimsOf(idToken) {
  try {
    const payload = String(idToken).split('.')[1];
    if (!payload) return null;
    return JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
  } catch {
    return null;
  }
}
