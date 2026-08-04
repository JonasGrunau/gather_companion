import assert from 'node:assert/strict';
import { test } from 'node:test';

import { PairingCodes, normalise, pairPayload } from '../lib/pairing.js';
import { encode, render } from '../lib/qr.js';

test('no code exists until pairing is asked for', () => {
  const codes = new PairingCodes();
  assert.equal(codes.pending, null);
  assert.equal(codes.claim('ANYTHING'), 'no-code');
});

test('a minted code can be claimed exactly once', () => {
  const codes = new PairingCodes();
  const { code } = codes.mint();
  assert.equal(code.length, 8);
  assert.equal(codes.claim(code), 'ok');
  assert.equal(codes.claims, 1);
  // Burned: a second phone needs a second `pair`.
  assert.equal(codes.claim(code), 'no-code');
});

test('codes avoid the characters people misread', () => {
  const codes = new PairingCodes();
  for (let i = 0; i < 200; i++) {
    const { code } = codes.mint();
    assert.doesNotMatch(code, /[01ILO]/, `${code} contains an ambiguous character`);
    assert.match(code, /^[2-9A-HJ-NP-Z]{8}$/);
  }
});

test('typed codes tolerate case, spaces and dashes', () => {
  const codes = new PairingCodes();
  const { code } = codes.mint();
  const messy = `${code.slice(0, 4).toLowerCase()} - ${code.slice(4)}`;
  assert.equal(codes.claim(messy), 'ok');
});

test('a misread character fails rather than being guessed at', () => {
  const codes = new PairingCodes();
  codes.mint();
  // O is not in the alphabet; there is no sound mapping back to what was meant,
  // so this must be refused rather than silently pairing.
  assert.equal(codes.claim('OOOOOOOO'), 'wrong');
});

test('wrong guesses destroy the code rather than allowing a grind', () => {
  const codes = new PairingCodes();
  const { code } = codes.mint();
  for (let i = 0; i < 7; i++) assert.equal(codes.claim('ZZZZZZZZ'), 'wrong');
  assert.ok(codes.pending, 'still alive at seven');
  assert.equal(codes.claim('ZZZZZZZZ'), 'wrong');
  assert.equal(codes.pending, null, 'the eighth wrong guess throws it away');
  assert.equal(codes.claim(code), 'no-code', 'even the right code is gone now');
});

test('codes expire', () => {
  let now = 1_000_000;
  const codes = new PairingCodes({ now: () => now });
  const { code } = codes.mint();
  now += 14 * 60_000;
  assert.ok(codes.pending, 'still valid at fourteen minutes');
  now += 2 * 60_000;
  assert.equal(codes.pending, null);
  assert.equal(codes.claim(code), 'expired');
});

test('minting again replaces the outstanding code', () => {
  const codes = new PairingCodes();
  const first = codes.mint().code;
  const second = codes.mint().code;
  assert.notEqual(first, second);
  assert.equal(codes.claim(first), 'wrong');
});

test('normalise keeps only alphabet characters', () => {
  assert.equal(normalise('  ab-cd ef23 '), 'ABCDEF23');
  assert.equal(normalise('O0I1L'), '', 'ambiguous characters are dropped, not mapped');
  assert.equal(normalise(null), '');
});

test('the payload is scannable as a QR alphanumeric symbol', () => {
  const payload = pairPayload({ host: '192.168.178.81', port: 7799, code: 'MAMGT98C' });
  assert.equal(payload, '192.168.178.81:7799:MAMGT98C');
  // Every character has to be in QR alphanumeric mode, or encode() would refuse.
  assert.doesNotThrow(() => encode(payload));
  const rows = render(payload, { indent: '' });
  assert.ok(rows.length > 8, 'a symbol should have been drawn');
});

test('a long hostname payload still encodes', () => {
  // 61 characters is the version-3 ceiling the encoder supports.
  const payload = pairPayload({ host: 'JONAS-MACBOOK.FRITZ.BOX', port: 7799, code: 'MAMGT98C' });
  assert.ok(payload.length <= 61, `payload is ${payload.length} characters`);
  assert.doesNotThrow(() => encode(payload));
});
