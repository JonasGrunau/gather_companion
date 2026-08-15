import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  desktopRefreshTokens,
  emailFromIdToken,
  refreshSessionForPairing,
  signOutGather,
  uidFromIdToken,
} from '../lib/gather-auth.js';

/**
 * Builds a Blink structured-clone string: tag 0x22, a LEB128 length, the bytes.
 *
 * This is the shape Firebase's IndexedDB record has inside it, and the only part
 * of it `desktopRefreshTokens` understands. Synthesised rather than copied from a
 * real profile for the obvious reason: a fixture must not contain a live
 * credential.
 */
function blinkString(value) {
  const body = Buffer.from(value, 'latin1');
  const varint = [];
  let n = body.length;
  do {
    let byte = n & 0x7f;
    n >>>= 7;
    if (n > 0) byte |= 0x80;
    varint.push(byte);
  } while (n > 0);
  return Buffer.concat([Buffer.from([0x22]), Buffer.from(varint), body]);
}

/** One IndexedDB-ish record: the key name followed by its string value. */
function record(name, value) {
  return Buffer.concat([blinkString(name), blinkString(value)]);
}

function fixtureDir(files) {
  const dir = mkdtempSync(join(tmpdir(), 'gather-auth-'));
  for (const [name, buf] of Object.entries(files)) writeFileSync(join(dir, name), buf);
  return dir;
}

const LONG = 'A'.repeat(220); // long enough and base64url-ish, like the real thing

test('finds a refresh token in a leveldb file', () => {
  const dir = fixtureDir({
    '000283.ldb': Buffer.concat([
      Buffer.from('garbage\x00\x01'),
      record('refreshToken', LONG),
      record('accessToken', 'ey.short'),
    ]),
  });
  const found = desktopRefreshTokens(dir);
  assert.equal(found.length, 1);
  assert.equal(found[0].token, LONG);
  assert.equal(found[0].file, '000283.ldb');
});

test('prefers the write-ahead log over the settled table', () => {
  // The `.log` holds fresher state than the `.ldb`, so a newer session lives
  // there. Callers try candidates in order, so order is the contract.
  const fresh = 'B'.repeat(220);
  const dir = fixtureDir({
    '000281.log': record('refreshToken', fresh),
    '000283.ldb': record('refreshToken', LONG),
  });
  const tokens = desktopRefreshTokens(dir).map((t) => t.token);
  assert.deepEqual(tokens, [fresh, LONG]);
});

test('ignores short or non-token values sitting next to the same key', () => {
  // The key name appears in more than one record shape; only a plausible token
  // should be offered to Google, or every start-up burns a pointless round trip.
  const dir = fixtureDir({
    '000283.ldb': Buffer.concat([
      record('refreshToken', 'nope'), // too short
      record('refreshToken', `${'C'.repeat(150)} with spaces`), // not base64url
      record('refreshToken', LONG),
    ]),
  });
  const found = desktopRefreshTokens(dir);
  assert.deepEqual(
    found.map((f) => f.token),
    [LONG],
  );
});

test('a missing or unreadable profile yields nothing rather than throwing', () => {
  // The bridge runs on machines that have never installed Gather; that must be a
  // quiet "no session", not a crash in the daemon's start-up path.
  assert.deepEqual(desktopRefreshTokens(join(tmpdir(), 'definitely-not-there-12345')), []);
});

test('a truncated record is skipped instead of over-reading the buffer', () => {
  const partial = record('refreshToken', LONG).subarray(0, 40);
  const dir = fixtureDir({ '000283.ldb': partial });
  assert.deepEqual(desktopRefreshTokens(dir), []);
});

/** A JWT with the claims we read and a signature we never check. */
function jwt(claims) {
  return `eyJhbGciOiJub25lIn0.${Buffer.from(JSON.stringify(claims)).toString('base64url')}.sig`;
}

/** An in-memory stand-in for `~/.gather-app-bridge.json`. */
function fakeConfig(initial = {}) {
  let config = initial;
  return { read: () => config, write: (next) => (config = next), get value() {
    return config;
  } };
}

test('pairing takes the desktop session over the one already stored', async () => {
  // The whole point: whichever account the Mac is signed into now is the account
  // the phone leaves with. A stored session is not evidence of anything — it is
  // what the *last* pairing found.
  const config = fakeConfig({ token: 'pairing-token', gather: { refreshToken: 'old', uid: 'uid-old' } });
  const result = await refreshSessionForPairing({
    adopt: async () => ({ uid: 'uid-new', email: 'new@example.com', file: '000325.log' }),
    read: config.read,
    write: config.write,
    verify: () => assert.fail('a present desktop session must not be second-guessed'),
  });

  assert.equal(result.source, 'desktop');
  assert.equal(result.uid, 'uid-new');
  assert.equal(result.email, 'new@example.com');
  assert.equal(result.previousUid, 'uid-old');
  assert.equal(result.switched, true);
});

test('a first pairing is not reported as an account switch', async () => {
  // `switched` drives a warning about the account changing under you, which is
  // nonsense the first time round and would train people to ignore it.
  const config = fakeConfig({ token: 'pairing-token' });
  const result = await refreshSessionForPairing({
    adopt: async () => ({ uid: 'uid-new', email: 'new@example.com', file: '000325.log' }),
    read: config.read,
    write: config.write,
  });
  assert.equal(result.switched, false);
  assert.equal(result.previousUid, null);
});

test('the stored session is kept when the desktop client offers none', async () => {
  // GatherV2 uninstalled, signed out, or its profile unreadable. The bridge has
  // been independent of it since adoption, so pairing must not start needing it.
  const config = fakeConfig({ token: 'pairing-token', gather: { refreshToken: 'old', uid: 'uid-old' } });
  const result = await refreshSessionForPairing({
    adopt: async () => {
      throw new Error('no Gather session found on this machine');
    },
    read: config.read,
    write: config.write,
    verify: async (token) => {
      assert.equal(token, 'old');
      return { idToken: jwt({ user_id: 'uid-old', email: 'me@example.com' }), refreshToken: 'rotated', uid: 'uid-old' };
    },
  });

  assert.equal(result.source, 'stored');
  assert.equal(result.email, 'me@example.com');
  assert.equal(result.switched, false);
  // Rotation is persisted, or the next pairing would verify a token Google has
  // already replaced.
  assert.equal(config.value.gather.refreshToken, 'rotated');
  assert.equal(config.value.token, 'pairing-token', 'the pairing token is untouched');
});

test('pairing refuses when the desktop has none and the stored one is dead', async () => {
  // The state this whole path exists for. Both halves of the reason are carried:
  // one is fixed by signing in, the other by knowing the session was revoked.
  const config = fakeConfig({ gather: { refreshToken: 'old', uid: 'uid-old' } });
  await assert.rejects(
    refreshSessionForPairing({
      adopt: async () => {
        throw new Error('no Gather session found on this machine');
      },
      read: config.read,
      write: config.write,
      verify: async () => {
        throw new Error('TOKEN_EXPIRED');
      },
    }),
    (error) => /no Gather session found/.test(error.message) && /TOKEN_EXPIRED/.test(error.message),
  );
});

test('pairing refuses when there is nothing stored to fall back to', async () => {
  await assert.rejects(
    refreshSessionForPairing({
      adopt: async () => {
        throw new Error('no Gather session found on this machine');
      },
      read: () => ({}),
      write: () => assert.fail('nothing to write'),
    }),
    /no Gather session found/,
  );
});

test('signing out drops the session and keeps the pairing token', async () => {
  // Fixing an account mix-up must not cost the phone its registration: it would
  // turn a one-command repair into setting push up again from scratch.
  const config = fakeConfig({
    token: 'pairing-token',
    port: 8756,
    gather: { refreshToken: 'old', idToken: jwt({ user_id: 'uid-old', email: 'me@example.com' }) },
  });
  const result = signOutGather({ read: config.read, write: config.write });

  assert.equal(result.hadSession, true);
  assert.equal(result.email, 'me@example.com');
  assert.equal(result.uid, 'uid-old');
  assert.deepEqual(config.value, { token: 'pairing-token', port: 8756 });
});

test('signing out twice is quiet rather than an error', () => {
  const config = fakeConfig({ token: 'pairing-token' });
  assert.equal(signOutGather({ read: config.read, write: config.write }).hadSession, false);
  assert.deepEqual(config.value, { token: 'pairing-token' });
});

test('emailFromIdToken reads the account name, or nothing at all', () => {
  assert.equal(emailFromIdToken(jwt({ email: 'me@example.com' })), 'me@example.com');
  assert.equal(emailFromIdToken(jwt({ user_id: 'uid-1' })), null);
  assert.equal(emailFromIdToken('not-a-jwt'), null);
  assert.equal(emailFromIdToken(undefined), null);
});

test('uidFromIdToken reads the uid out of a JWT payload', () => {
  const claims = Buffer.from(JSON.stringify({ user_id: 'uid-42', exp: 4e9 })).toString('base64url');
  assert.equal(uidFromIdToken(`eyJhbGciOiJub25lIn0.${claims}.sig`), 'uid-42');
  // `sub` is the fallback, and garbage must not throw.
  const sub = Buffer.from(JSON.stringify({ sub: 'uid-7' })).toString('base64url');
  assert.equal(uidFromIdToken(`x.${sub}.y`), 'uid-7');
  assert.equal(uidFromIdToken('not-a-jwt'), null);
  assert.equal(uidFromIdToken(''), null);
});
