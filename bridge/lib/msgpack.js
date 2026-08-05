/**
 * MessagePack decoder, with the extension types Gather V2 registers.
 *
 * Decode only — the bridge reads the desktop client's existing, already
 * authenticated stream and never speaks on it.
 *
 * Hand-written rather than pulling in `@msgpack/msgpack` for one structural
 * reason: `install` copies only `bridge/lib` and `bridge/bin` into
 * ~/.gather-app-bridge and runs that copy straight from launchd, with no
 * node_modules to resolve. Every dependency would have to be vendored into that
 * copy or the LaunchAgent breaks. A self-contained decoder keeps that property.
 *
 * ## Gather's extension codec
 *
 * From the v2 bundle (`modmain/80732.js` registering `VALUE_OBJECTS`):
 *
 *   ext 0  a registered value object, encoded as msgpack `{k: typeName, v: body}`
 *          — Position, Direction, Speed, Dimensions, DateRange,
 *          SpaceUserAvailability, behaviours
 *   ext 1  DateTime, as integer milliseconds
 *   ext 2  a JS Set, as an array
 *   ext 4  undefined (empty payload)
 *   ext 5  bigint, as an 8-byte int64
 *
 * Value objects decode to their body with a `$type` tag added, so a Position
 * arrives as `{ $type: 'Position', x: 12, y: 30 }` — flat enough to read
 * directly, tagged enough to tell apart.
 */

/** Marker for msgpack `undefined` (ext 4), which JSON cannot represent. */
export const MSGPACK_UNDEFINED = Symbol('msgpack.undefined');

class Reader {
  constructor(buffer) {
    this.view = new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength);
    this.bytes = buffer;
    this.pos = 0;
  }

  get remaining() {
    return this.bytes.byteLength - this.pos;
  }

  need(n) {
    if (this.remaining < n) throw new RangeError(`msgpack: truncated (need ${n}, have ${this.remaining})`);
  }

  u8() {
    this.need(1);
    return this.view.getUint8(this.pos++);
  }

  i8() {
    this.need(1);
    return this.view.getInt8(this.pos++);
  }

  u16() {
    this.need(2);
    const v = this.view.getUint16(this.pos);
    this.pos += 2;
    return v;
  }

  i16() {
    this.need(2);
    const v = this.view.getInt16(this.pos);
    this.pos += 2;
    return v;
  }

  u32() {
    this.need(4);
    const v = this.view.getUint32(this.pos);
    this.pos += 4;
    return v;
  }

  i32() {
    this.need(4);
    const v = this.view.getInt32(this.pos);
    this.pos += 4;
    return v;
  }

  u64() {
    this.need(8);
    const v = this.view.getBigUint64(this.pos);
    this.pos += 8;
    return v;
  }

  i64() {
    this.need(8);
    const v = this.view.getBigInt64(this.pos);
    this.pos += 8;
    return v;
  }

  f32() {
    this.need(4);
    const v = this.view.getFloat32(this.pos);
    this.pos += 4;
    return v;
  }

  f64() {
    this.need(8);
    const v = this.view.getFloat64(this.pos);
    this.pos += 8;
    return v;
  }

  str(length) {
    this.need(length);
    const slice = this.bytes.subarray(this.pos, this.pos + length);
    this.pos += length;
    return new TextDecoder('utf-8').decode(slice);
  }

  bin(length) {
    this.need(length);
    const slice = this.bytes.subarray(this.pos, this.pos + length);
    this.pos += length;
    return Buffer.from(slice);
  }
}

/** Decodes one msgpack document from a Buffer/Uint8Array. */
export function decode(input) {
  const bytes = input instanceof Uint8Array ? input : new Uint8Array(input);
  const reader = new Reader(bytes);
  return readValue(reader);
}

function readValue(r) {
  const tag = r.u8();

  // positive fixint
  if (tag <= 0x7f) return tag;
  // negative fixint
  if (tag >= 0xe0) return tag - 0x100;
  // fixmap
  if (tag >= 0x80 && tag <= 0x8f) return readMap(r, tag & 0x0f);
  // fixarray
  if (tag >= 0x90 && tag <= 0x9f) return readArray(r, tag & 0x0f);
  // fixstr
  if (tag >= 0xa0 && tag <= 0xbf) return r.str(tag & 0x1f);

  switch (tag) {
    case 0xc0:
      return null;
    case 0xc1:
      throw new Error('msgpack: 0xc1 is never valid');
    case 0xc2:
      return false;
    case 0xc3:
      return true;
    case 0xc4:
      return r.bin(r.u8());
    case 0xc5:
      return r.bin(r.u16());
    case 0xc6:
      return r.bin(r.u32());
    case 0xc7:
      return readExt(r, r.u8(), r.i8());
    case 0xc8:
      return readExt(r, r.u16(), r.i8());
    case 0xc9:
      return readExt(r, r.u32(), r.i8());
    case 0xca:
      return r.f32();
    case 0xcb:
      return r.f64();
    case 0xcc:
      return r.u8();
    case 0xcd:
      return r.u16();
    case 0xce:
      return r.u32();
    case 0xcf:
      return toSafeNumber(r.u64());
    case 0xd0:
      return r.i8();
    case 0xd1:
      return r.i16();
    case 0xd2:
      return r.i32();
    case 0xd3:
      return toSafeNumber(r.i64());
    case 0xd4:
      return readExt(r, 1, r.i8());
    case 0xd5:
      return readExt(r, 2, r.i8());
    case 0xd6:
      return readExt(r, 4, r.i8());
    case 0xd7:
      return readExt(r, 8, r.i8());
    case 0xd8:
      return readExt(r, 16, r.i8());
    case 0xd9:
      return r.str(r.u8());
    case 0xda:
      return r.str(r.u16());
    case 0xdb:
      return r.str(r.u32());
    case 0xdc:
      return readArray(r, r.u16());
    case 0xdd:
      return readArray(r, r.u32());
    case 0xde:
      return readMap(r, r.u16());
    case 0xdf:
      return readMap(r, r.u32());
    default:
      throw new Error(`msgpack: unknown tag 0x${tag.toString(16)}`);
  }
}

function readArray(r, length) {
  const out = new Array(length);
  for (let i = 0; i < length; i++) out[i] = readValue(r);
  return out;
}

function readMap(r, length) {
  const out = {};
  for (let i = 0; i < length; i++) {
    const key = readValue(r);
    const value = readValue(r);
    // Keys are strings in every Gather message; anything else is stringified so
    // nothing is silently dropped.
    out[typeof key === 'string' ? key : String(key)] = value;
  }
  return out;
}

function readExt(r, length, type) {
  const payload = r.bin(length);

  switch (type) {
    case 0: {
      // A registered value object: msgpack `{k: typeName, v: body}`.
      const wrapper = decode(payload);
      if (wrapper && typeof wrapper === 'object' && 'k' in wrapper) {
        const body = wrapper.v;
        if (body && typeof body === 'object' && !Array.isArray(body)) {
          return { $type: wrapper.k, ...body };
        }
        return { $type: wrapper.k, value: body };
      }
      return wrapper;
    }
    case 1: {
      // DateTime as integer milliseconds.
      const millis = decode(payload);
      const n = typeof millis === 'bigint' ? Number(millis) : millis;
      return typeof n === 'number' ? new Date(n) : n;
    }
    case 2: {
      // A JS Set, encoded as an array. Kept as an array: everything downstream
      // is JSON-bound anyway.
      const items = decode(payload);
      return Array.isArray(items) ? items : [];
    }
    case 4:
      return MSGPACK_UNDEFINED;
    case 5: {
      if (payload.byteLength === 8) {
        const view = new DataView(payload.buffer, payload.byteOffset, 8);
        return toSafeNumber(view.getBigInt64(0));
      }
      return decode(payload);
    }
    case -1: {
      // Standard msgpack timestamp, in case the server ever uses it.
      if (payload.byteLength === 4) {
        const view = new DataView(payload.buffer, payload.byteOffset, 4);
        return new Date(view.getUint32(0) * 1000);
      }
      if (payload.byteLength === 8) {
        const view = new DataView(payload.buffer, payload.byteOffset, 8);
        const raw = view.getBigUint64(0);
        const nanos = Number(raw >> 34n);
        const seconds = Number(raw & 0x3ffffffffn);
        return new Date(seconds * 1000 + Math.floor(nanos / 1e6));
      }
      return payload;
    }
    default:
      return { $ext: type, data: payload };
  }
}

/** int64s in this protocol are ids and timestamps; keep them numbers when safe. */
function toSafeNumber(big) {
  if (big >= BigInt(Number.MIN_SAFE_INTEGER) && big <= BigInt(Number.MAX_SAFE_INTEGER)) {
    return Number(big);
  }
  return big;
}
