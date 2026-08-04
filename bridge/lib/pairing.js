import { randomInt } from 'node:crypto';

/**
 * Short-lived pairing codes, so the phone never has to be told a 48-character
 * token by hand.
 *
 * The long token stays the actual credential — every request and socket carries
 * it. What the QR square and the typed fallback carry is a *code*, which proves
 * the holder was looking at the terminal, and which is exchanged once for the
 * token.
 *
 * Deliberate properties:
 *
 *  - **Only exists on request.** No code is live until someone runs `pair`, so
 *    the unauthenticated claim endpoint has nothing to give away the rest of the
 *    time.
 *  - **Single use.** Claiming burns it. A second phone needs a second `pair`.
 *  - **Expires.** Fifteen minutes, matching how long a terminal window is
 *    plausibly still showing the square.
 *  - **Brute-force is bounded.** The alphabet is 31 characters over 8 places
 *    (~39 bits), and a handful of wrong guesses destroys the code rather than
 *    letting someone grind at it.
 */

/**
 * Unambiguous uppercase alphabet: no `0`/`O`, no `1`/`I`/`L`.
 *
 * Every character is also in QR alphanumeric mode, which is what keeps the
 * symbol at version 2 and the encoder simple.
 */
const ALPHABET = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';

const CODE_LENGTH = 8;
const TTL_MS = 15 * 60_000;

/** Wrong guesses before the code is thrown away. */
const MAX_ATTEMPTS = 8;

export class PairingCodes {
  /** @param {{ now?: () => number, log?: (msg: string) => void }} [options] */
  constructor({ now = () => Date.now(), log = () => {} } = {}) {
    this._now = now;
    this._log = log;
    /** @type {{ code: string, expiresAt: number, attempts: number } | null} */
    this._current = null;
    this._claims = 0;
  }

  /** Mints a fresh code, replacing any outstanding one. */
  mint() {
    let code = '';
    for (let i = 0; i < CODE_LENGTH; i++) code += ALPHABET[randomInt(ALPHABET.length)];
    this._current = { code, expiresAt: this._now() + TTL_MS, attempts: 0 };
    this._log(`pairing code ${code} (valid 15 minutes)`);
    return { code, expiresAt: this._current.expiresAt };
  }

  /**
   * The live code, or null when there is none or it has expired.
   *
   * Deliberately does not discard an expired code: `claim` needs it to still be
   * there to answer "that code has expired, run pair again" rather than the
   * vaguer "no pairing code is active". An expired code is harmless to keep —
   * every claim checks the deadline first.
   */
  get pending() {
    const current = this._current;
    if (!current) return null;
    if (this._now() > current.expiresAt) return null;
    return { code: current.code, expiresAt: current.expiresAt };
  }

  /** How many phones have paired since the daemon started. */
  get claims() {
    return this._claims;
  }

  /**
   * Redeems a code. Case- and separator-insensitive, because it is typed by
   * hand as often as it is scanned.
   *
   * @returns {'ok' | 'no-code' | 'expired' | 'wrong'}
   */
  claim(raw) {
    const current = this._current;
    if (!current) return 'no-code';
    if (this._now() > current.expiresAt) {
      this._current = null;
      return 'expired';
    }

    const offered = normalise(raw);
    if (offered !== current.code) {
      current.attempts++;
      if (current.attempts >= MAX_ATTEMPTS) {
        this._current = null;
        this._log(`pairing code discarded after ${MAX_ATTEMPTS} wrong attempts`);
      }
      return 'wrong';
    }

    this._current = null;
    this._claims++;
    this._log('a phone paired with this bridge');
    return 'ok';
  }
}

/**
 * Cleans up a scanned or typed code.
 *
 * Lowercase is accepted, and so are the spaces and dashes people insert to make
 * eight characters readable. Everything outside the alphabet is dropped — which
 * includes `0`, `1`, `I`, `L` and `O`, the characters the alphabet excludes
 * precisely because they are misread.
 *
 * Note what this deliberately does *not* do: guess. There is no sound mapping
 * from a reported `O` back to the intended character (`Q`? `D`?), so a genuine
 * misread ends up the wrong length and fails the comparison, and the person is
 * told the code was wrong. Silently pairing on a mistyped code would be worse
 * than making them look again.
 */
export function normalise(raw) {
  const upper = String(raw ?? '').toUpperCase();
  let out = '';
  for (const ch of upper) {
    if (ALPHABET.includes(ch)) out += ch;
  }
  return out;
}

/** The payload a phone scans: where to come back to, and the code. */
export function pairPayload({ host, port, code }) {
  return `${host}:${port}:${code}`.toUpperCase();
}
