import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { desktopRefreshTokens, uidFromIdToken } from '../lib/gather-auth.js';

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

test('uidFromIdToken reads the uid out of a JWT payload', () => {
  const claims = Buffer.from(JSON.stringify({ user_id: 'uid-42', exp: 4e9 })).toString('base64url');
  assert.equal(uidFromIdToken(`eyJhbGciOiJub25lIn0.${claims}.sig`), 'uid-42');
  // `sub` is the fallback, and garbage must not throw.
  const sub = Buffer.from(JSON.stringify({ sub: 'uid-7' })).toString('base64url');
  assert.equal(uidFromIdToken(`x.${sub}.y`), 'uid-7');
  assert.equal(uidFromIdToken('not-a-jwt'), null);
  assert.equal(uidFromIdToken(''), null);
});
