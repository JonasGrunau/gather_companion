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
      const uid = session.uid ?? uidFromIdToken(session.idToken);
      const config = readConfig();
      writeConfig({
        ...config,
        gather: { refreshToken: session.refreshToken, idToken: session.idToken, uid },
      });
      log(`gather auth: adopted the desktop session from ${file}`);
      // The email comes back for one reason: to say out loud *which* account was
      // adopted. A uid prefix cannot be recognised, and this bridge has already
      // once switched accounts without anybody noticing.
      return { uid, email: emailFromIdToken(session.idToken), file };
    } catch (error) {
      reasons.push(`${file}: ${error.message}`);
    }
  }
  throw new Error(`every stored session was rejected (${reasons.join('; ')})`);
}

/**
 * The session `pair` hands over: whichever one the desktop client is signed into
 * *now*.
 *
 * Adoption was written as a one-off setup step, and the stored copy treated as
 * permanent. That held right until the desktop client signed into a second
 * account, which revokes the first one's refresh token. From then on the bridge
 * held a corpse and could not tell: [hasGatherSession] still said yes,
 * `/pair/claim` still handed it over, and the phone got `TOKEN_EXPIRED`, decided
 * the only fix was to pair again, and was handed the same dead token — a loop
 * with no way out from the phone's end.
 *
 * So pairing re-reads the desktop client every time, which is also the behaviour
 * to want for its own sake: the account you last used on the Mac is the account
 * your phone gets, with nothing to remember.
 *
 * The stored session is the fallback, never the source, and only when it still
 * works. Preferring it over a *missing* desktop session keeps `pair` working on a
 * Mac where GatherV2 has since been deleted; never preferring it over a present
 * one is what "last used" means.
 */
export async function refreshSessionForPairing({
  log = () => {},
  adopt = adoptDesktopSession,
  read = readConfig,
  write = writeConfig,
  verify = exchange,
} = {}) {
  const before = read().gather ?? null;
  const previousUid = before?.uid ?? uidFromIdToken(before?.idToken);

  try {
    const { uid, email, file } = await adopt({ log });
    return {
      uid,
      email,
      file,
      source: 'desktop',
      previousUid,
      switched: Boolean(previousUid) && uid !== previousUid,
    };
  } catch (error) {
    if (!before?.refreshToken) throw error;

    let session;
    try {
      session = await verify(before.refreshToken);
    } catch (dead) {
      // Both ways out are blocked, and they are two different repairs — one is
      // "sign in to GatherV2", the other is "that session was revoked" — so the
      // message carries both rather than only the one we tried last.
      throw new Error(
        `${error.message}; and the session already stored is dead too (${dead.message})`,
      );
    }

    const uid = session.uid ?? previousUid ?? uidFromIdToken(session.idToken);
    write({
      ...read(),
      gather: { refreshToken: session.refreshToken, idToken: session.idToken, uid },
    });
    log('gather auth: kept the stored session — the desktop client offered none');
    return {
      uid,
      email: emailFromIdToken(session.idToken),
      source: 'stored',
      previousUid,
      switched: false,
      detail: error.message,
    };
  }
}

/**
 * Forgets the adopted Gather session.
 *
 * The way out of a wrong account without hand-editing JSON, and the counterpart
 * to adoption now that adoption happens on its own at every pairing.
 *
 * What it cannot do is reach the copy already on the phone: that refresh token
 * sits in the phone's keychain and only pairing again replaces it. So this ends
 * the *bridge's* access, not the phone's, and the caller should say so rather
 * than implying a sign-out everywhere.
 */
export function signOutGather({ read = readConfig, write = writeConfig } = {}) {
  const { gather, ...rest } = read();
  write(rest);
  return {
    hadSession: typeof gather?.refreshToken === 'string' && gather.refreshToken.length > 0,
    uid: gather?.uid ?? uidFromIdToken(gather?.idToken),
    email: emailFromIdToken(gather?.idToken),
  };
}

/**
 * True when we hold a refresh token, without touching the network.
 *
 * "Hold one", not "have a working one" — the two came apart badly once, so
 * anything reporting to a human should verify rather than call this. It is the
 * right check only where a network round trip would be wrong: a status line that
 * must stay instant, or a guard before bothering to try at all.
 */
export function hasGatherSession() {
  const token = readConfig().gather?.refreshToken;
  return typeof token === 'string' && token.length > 0;
}

/**
 * The session, packaged for handing to a paired phone.
 *
 * The phone cannot adopt a session itself — it has no access to this machine's
 * disk — so pairing is the only moment it can be given one. What crosses is the
 * *refresh* token, not an ID token: ID tokens last an hour, and a phone that had
 * to re-pair hourly would be useless.
 *
 * ## What this widens
 *
 * `/pair/claim` is the one unauthenticated route, because handing over a
 * credential is its whole purpose. Until now the credential it handed over was
 * scoped to this bridge on this LAN. Now it is the user's Gather identity, so a
 * stolen code is worth more. The protections are unchanged and still the right
 * ones — no code exists until someone runs `pair`, it is single-use, it expires in
 * fifteen minutes, and eight wrong guesses destroy it — but the stakes are higher,
 * which is worth stating where somebody will read it.
 *
 * Returns null when no session has been adopted, so pairing can say so plainly
 * rather than handing over a phone that will never connect.
 *
 * Reads the config and does not verify it, which is safe only because of when it
 * runs: `pair` calls [refreshSessionForPairing] before a code is ever issued, so
 * by the time a phone claims one the stored session has just been proved live.
 * Verifying here instead would put a network round trip inside the one
 * unauthenticated route, where a slow or hostile network becomes a way to hold the
 * handler open.
 */
export function gatherSessionForHandover() {
  const gather = readConfig().gather;
  if (typeof gather?.refreshToken !== 'string' || !gather.refreshToken) return null;
  return {
    refreshToken: gather.refreshToken,
    uid: gather.uid ?? uidFromIdToken(gather.idToken),
  };
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

/**
 * The account's email address, likewise straight out of the token.
 *
 * Only ever for showing a human which identity is in play. Nothing routes on it —
 * the uid is the identity — but "grunau@safenow.de" is recognisable at a glance
 * and `RY4VoMwW…` is not, which is the whole difference between noticing that the
 * account changed and not noticing for two days.
 */
export function emailFromIdToken(idToken) {
  return claimsOf(idToken)?.email ?? null;
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
