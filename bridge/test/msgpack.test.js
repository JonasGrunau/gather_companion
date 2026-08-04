import assert from 'node:assert/strict';
import { test } from 'node:test';

import { MSGPACK_UNDEFINED, decode } from '../lib/msgpack.js';

/**
 * A minimal encoder, test-only.
 *
 * The library is decode-only on purpose — the bridge never writes to Gather's
 * socket — so fixtures are built here instead of being pasted in as hex.
 */
function enc(value) {
  if (value === null) return Buffer.from([0xc0]);
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
    const head = Buffer.alloc(3);
    head[0] = 0xda;
    head.writeUInt16BE(body.length, 1);
    return Buffer.concat([head, body]);
  }

  if (Array.isArray(value)) {
    const items = value.map(enc);
    if (value.length < 16) {
      return Buffer.concat([Buffer.from([0x90 | value.length]), ...items]);
    }
    const head = Buffer.alloc(3);
    head[0] = 0xdc;
    head.writeUInt16BE(value.length, 1);
    return Buffer.concat([head, ...items]);
  }

  if (typeof value === 'object') {
    const keys = Object.keys(value);
    const parts = keys.flatMap((k) => [enc(k), enc(value[k])]);
    if (keys.length < 16) {
      return Buffer.concat([Buffer.from([0x80 | keys.length]), ...parts]);
    }
    const head = Buffer.alloc(3);
    head[0] = 0xde;
    head.writeUInt16BE(keys.length, 1);
    return Buffer.concat([head, ...parts]);
  }

  throw new Error(`test encoder cannot handle ${typeof value}`);
}

/** Wraps a payload as a msgpack ext of the given type, using ext8 for simplicity. */
function ext(type, payload) {
  const head = Buffer.alloc(3);
  head[0] = 0xc7;
  head[1] = payload.length;
  head.writeInt8(type, 2);
  return Buffer.concat([head, payload]);
}

test('primitives round-trip', () => {
  assert.equal(decode(enc(null)), null);
  assert.equal(decode(enc(true)), true);
  assert.equal(decode(enc(false)), false);
  assert.equal(decode(enc(0)), 0);
  assert.equal(decode(enc(42)), 42);
  assert.equal(decode(enc(-17)), -17);
  assert.equal(decode(enc(70000)), 70000);
  assert.equal(decode(enc(-9007199254740991)), -9007199254740991);
  assert.equal(decode(enc(1.5)), 1.5);
  assert.equal(decode(enc('hello')), 'hello');
  assert.equal(decode(enc('')), '');
  assert.equal(decode(enc('a'.repeat(500))), 'a'.repeat(500));
  assert.equal(decode(enc('mit Umlauten: äöü')), 'mit Umlauten: äöü');
});

test('containers round-trip, including large ones', () => {
  assert.deepEqual(decode(enc([1, 2, 3])), [1, 2, 3]);
  assert.deepEqual(decode(enc([])), []);
  assert.deepEqual(decode(enc({ a: 1, b: 'two' })), { a: 1, b: 'two' });
  assert.deepEqual(decode(enc({})), {});

  const big = Array.from({ length: 40 }, (_, i) => i);
  assert.deepEqual(decode(enc(big)), big);

  const wide = Object.fromEntries(big.map((i) => [`k${i}`, i]));
  assert.deepEqual(decode(enc(wide)), wide);

  assert.deepEqual(decode(enc({ nested: { list: [{ deep: true }] } })), {
    nested: { list: [{ deep: true }] },
  });
});

test('a real-looking heartbeat frame decodes', () => {
  const frame = { type: 'Heartbeat', timestamp: 1769864400000, origin: 'Server' };
  assert.deepEqual(decode(enc(frame)), frame);
});

test('ext 0 value objects flatten with a $type tag', () => {
  // Gather encodes registered value objects as ext 0 wrapping {k: name, v: body}.
  const position = ext(0, enc({ k: 'Position', v: { x: 12, y: 30 } }));
  assert.deepEqual(decode(position), { $type: 'Position', x: 12, y: 30 });

  const direction = ext(0, enc({ k: 'Direction', v: { value: 'Up' } }));
  assert.deepEqual(decode(direction), { $type: 'Direction', value: 'Up' });
});

test('a value object nested inside a patch decodes in place', () => {
  const payload = {
    op: 'replace',
    model: 'SpaceUser',
    id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
    path: '/position',
  };
  const bytes = Buffer.concat([
    Buffer.from([0x85]), // fixmap of 5
    enc('op'),
    enc(payload.op),
    enc('model'),
    enc(payload.model),
    enc('id'),
    enc(payload.id),
    enc('path'),
    enc(payload.path),
    enc('data'),
    ext(0, enc({ k: 'Position', v: { x: 4, y: 7 } })),
  ]);
  assert.deepEqual(decode(bytes), { ...payload, data: { $type: 'Position', x: 4, y: 7 } });
});

test('ext 1 decodes to a Date', () => {
  const millis = 1769864400123;
  const value = decode(ext(1, enc(millis)));
  assert.ok(value instanceof Date);
  assert.equal(value.getTime(), millis);
});

test('ext 2 decodes a Set as an array', () => {
  assert.deepEqual(decode(ext(2, enc(['a', 'b']))), ['a', 'b']);
});

test('ext 4 decodes to the undefined marker', () => {
  assert.equal(decode(ext(4, Buffer.alloc(0))), MSGPACK_UNDEFINED);
});

test('ext 5 decodes an int64 bigint', () => {
  const payload = Buffer.alloc(8);
  payload.writeBigInt64BE(1234567890123n);
  assert.equal(decode(ext(5, payload)), 1234567890123);
});

test('unknown ext types are preserved rather than thrown away', () => {
  const value = decode(ext(9, Buffer.from([1, 2, 3])));
  assert.equal(value.$ext, 9);
  assert.deepEqual([...value.data], [1, 2, 3]);
});

test('truncated input fails loudly instead of returning junk', () => {
  // A fixstr header claiming five bytes, with only two present.
  assert.throws(() => decode(Buffer.from([0xa5, 0x61, 0x62])), /truncated/);
  assert.throws(() => decode(Buffer.from([0xc1])), /never valid/);
});
