/**
 * Sends push notifications through Firebase Cloud Messaging, with no dependencies.
 *
 * The bridge's local notifications only fire while the phone app is running. Once
 * iOS suspends it the WebSocket is gone, and a wave or a follow arrives nowhere.
 * Push is the only way to reach a locked or killed phone, and FCM v1 is the only
 * supported way in — the legacy `key=…` server key was switched off in 2024.
 *
 * ## The whole protocol, since it is short
 *
 * 1. Build a JWT asserting "I am this service account and I want the
 *    `firebase.messaging` scope", signed **RS256** with the service account's
 *    private key. `node:crypto` signs RSA-SHA256 natively, which is the only
 *    reason this file needs nothing from npm.
 * 2. Trade it at `oauth2.googleapis.com/token` for an access token, good for an
 *    hour. Cached, and refreshed early — a daemon that only worked for its first
 *    hour would look perfect in testing and be dead by morning.
 * 3. `POST /v1/projects/<id>/messages:send` with `Bearer <access token>`.
 *
 * ## What the payload has to say
 *
 * `notification` is what makes iOS display it while the app is suspended. Without
 * it FCM sends a data-only message, which a killed app never sees — the exact
 * failure this whole feature exists to avoid.
 *
 * `apns-collapse-id` is what keeps a busy space from stacking up a column of
 * near-identical alerts: iOS replaces any undelivered notification with the same
 * id rather than adding to it.
 */

import { createSign } from 'node:crypto';
import { readFileSync } from 'node:fs';

const SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';
const TOKEN_URL = 'https://oauth2.googleapis.com/token';

/** Access tokens last an hour; renew with this much to spare. */
const REFRESH_MARGIN_MS = 300_000;

/** Reads and validates a service account JSON. Throws with a fixable message. */
export function readServiceAccount(file) {
  let raw;
  try {
    raw = readFileSync(file, 'utf8');
  } catch {
    throw new Error(`no FCM service account at ${file}`);
  }

  let json;
  try {
    json = JSON.parse(raw);
  } catch {
    throw new Error(`${file} is not valid JSON`);
  }

  // The single most likely mistake is downloading the wrong file from the
  // Firebase console — GoogleService-Info.plist, or a Web app config — so say
  // which one is wanted rather than failing on a missing property later.
  for (const key of ['client_email', 'private_key', 'project_id']) {
    if (typeof json[key] !== 'string' || !json[key]) {
      throw new Error(
        `${file} is missing "${key}" — this should be the JSON from ` +
          'Firebase console → Project settings → Service accounts → Generate new private key',
      );
    }
  }
  return { clientEmail: json.client_email, privateKey: json.private_key, projectId: json.project_id };
}

function base64url(value) {
  return Buffer.from(value).toString('base64url');
}

/** The signed assertion Google trades for an access token. */
export function buildAssertion({ clientEmail, privateKey }, now = Date.now()) {
  const issuedAt = Math.floor(now / 1000);
  const header = base64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claims = base64url(
    JSON.stringify({
      iss: clientEmail,
      scope: SCOPE,
      aud: TOKEN_URL,
      iat: issuedAt,
      exp: issuedAt + 3600,
    }),
  );
  const signer = createSign('RSA-SHA256');
  signer.update(`${header}.${claims}`);
  return `${header}.${claims}.${signer.sign(privateKey, 'base64url')}`;
}

export class FcmSender {
  /**
   * @param {{ keyFile: string, log?: Function, fetchImpl?: Function }} options
   *   `fetchImpl` is the test seam: the suite must never reach Google.
   */
  constructor({ keyFile, log = () => {}, fetchImpl = fetch }) {
    this.keyFile = keyFile;
    this.log = log;
    this._fetch = fetchImpl;
    this._account = null;
    this._token = null;
    this._expiresAt = 0;
  }

  /** The service account, read once and cached. Throws if it is unusable. */
  account() {
    if (!this._account) this._account = readServiceAccount(this.keyFile);
    return this._account;
  }

  get projectId() {
    return this.account().projectId;
  }

  async accessToken() {
    if (this._token && this._expiresAt - Date.now() > REFRESH_MARGIN_MS) return this._token;

    const res = await this._fetch(TOKEN_URL, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        assertion: buildAssertion(this.account()),
      }),
      signal: AbortSignal.timeout(15_000),
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok || !body.access_token) {
      throw new Error(
        `FCM token exchange failed (${res.status}): ${body.error_description ?? body.error ?? 'no reason given'}`,
      );
    }
    this._token = body.access_token;
    this._expiresAt = Date.now() + (body.expires_in ?? 3600) * 1000;
    this.log('fcm: refreshed the access token');
    return this._token;
  }

  /**
   * Sends one notification.
   *
   * Returns `{ok}` on success, or `{ok:false, drop}` where `drop` means the
   * device token is dead and should be forgotten — a phone that was reinstalled,
   * restored from backup, or simply had the app deleted. Without honouring that,
   * the registry accumulates tokens that can never be delivered to and every
   * event costs a pointless round trip.
   */
  async send({ token, title, body, data = {}, collapseId = null }) {
    const accessToken = await this.accessToken();
    const message = {
      token,
      notification: { title, body },
      // Values must be strings; FCM rejects the message otherwise.
      data: Object.fromEntries(Object.entries(data).map(([k, v]) => [k, String(v)])),
      apns: {
        headers: {
          'apns-priority': '10',
          ...(collapseId ? { 'apns-collapse-id': collapseId.slice(0, 64) } : {}),
        },
        payload: { aps: { sound: 'default', badge: 1 } },
      },
    };

    const res = await this._fetch(
      `https://fcm.googleapis.com/v1/projects/${this.projectId}/messages:send`,
      {
        method: 'POST',
        headers: {
          authorization: `Bearer ${accessToken}`,
          'content-type': 'application/json',
        },
        body: JSON.stringify({ message }),
        signal: AbortSignal.timeout(15_000),
      },
    );

    if (res.ok) return { ok: true };

    const payload = await res.json().catch(() => ({}));
    const status = payload?.error?.status ?? '';
    const detail = payload?.error?.message ?? `HTTP ${res.status}`;
    // UNREGISTERED is the documented "this token is dead" answer; a 404 without
    // one means the same thing. INVALID_ARGUMENT on a token we sent is a
    // malformed token, which is equally never going to work.
    const drop =
      status === 'UNREGISTERED' ||
      status === 'NOT_FOUND' ||
      res.status === 404 ||
      (status === 'INVALID_ARGUMENT' && /token/i.test(detail));
    return { ok: false, drop, detail };
  }
}
