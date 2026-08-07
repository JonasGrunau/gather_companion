/// MessagePack codec, with the extension types Gather V2 registers.
///
/// A port of the bridge's `bridge/lib/msgpack.js`, and deliberately a close one:
/// two implementations of the same wire format that drift apart are worse than
/// either alone, so the structure, the tag order and the comments track the
/// original. Where Dart makes something simpler it says so.
///
/// Decoding is the deep half — it must understand everything Gather's server
/// sends, including five extension types. Encoding is shallow on purpose: the only
/// frames we send are the handshake, a heartbeat and a `teleport` action, all
/// plain maps of strings and numbers.
///
/// ## Gather's extension codec
///
/// From the v2 bundle (`modmain/80732.js` registering `VALUE_OBJECTS`):
///
///   ext 0  a registered value object, encoded as msgpack `{k: typeName, v: body}`
///          — Position, Direction, Speed, Dimensions, DateRange,
///          SpaceUserAvailability, behaviours
///   ext 1  DateTime, as integer milliseconds
///   ext 2  a JS Set, as an array
///   ext 4  undefined (empty payload)
///   ext 5  bigint, as an 8-byte int64
///
/// Value objects decode to their body with a `$type` tag added, so a Position
/// arrives as `{'$type': 'Position', 'x': 12, 'y': 30}` — flat enough to read
/// directly, tagged enough to tell apart.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Stands in for msgpack `undefined` (ext 4).
///
/// Dart has one kind of nothing where this protocol has two, and the difference
/// carries meaning: an *absent* `followTargetId` means nobody is being followed,
/// while a *null* one is a field explicitly cleared. Collapsing both to `null`
/// would lose that, so undefined decodes to this sentinel and callers test for it.
const Object msgpackUndefined = _MsgpackUndefined();

class _MsgpackUndefined {
  const _MsgpackUndefined();
  @override
  String toString() => 'msgpack.undefined';
}

/// An extension payload we have no decoder for, kept rather than dropped.
class MsgpackExt {
  const MsgpackExt(this.type, this.data);

  final int type;
  final Uint8List data;

  @override
  String toString() => 'MsgpackExt($type, ${data.length}B)';
}

class _Reader {
  _Reader(this.bytes)
      : view = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes);

  final Uint8List bytes;
  final ByteData view;
  int pos = 0;

  int get remaining => bytes.lengthInBytes - pos;

  void need(int n) {
    if (remaining < n) {
      throw FormatException('msgpack: truncated (need $n, have $remaining)');
    }
  }

  int u8() {
    need(1);
    return view.getUint8(pos++);
  }

  int i8() {
    need(1);
    return view.getInt8(pos++);
  }

  int u16() {
    need(2);
    final v = view.getUint16(pos);
    pos += 2;
    return v;
  }

  int i16() {
    need(2);
    final v = view.getInt16(pos);
    pos += 2;
    return v;
  }

  int u32() {
    need(4);
    final v = view.getUint32(pos);
    pos += 4;
    return v;
  }

  int i32() {
    need(4);
    final v = view.getInt32(pos);
    pos += 4;
    return v;
  }

  /// Dart's int is 64-bit, so uint64 is read as int64 and only the astronomically
  /// large values (which this protocol never sends — these are ids and millis)
  /// would wrap. JS needed a BigInt dance here; Dart does not.
  int u64() {
    need(8);
    final v = view.getUint64(pos);
    pos += 8;
    return v;
  }

  int i64() {
    need(8);
    final v = view.getInt64(pos);
    pos += 8;
    return v;
  }

  double f32() {
    need(4);
    final v = view.getFloat32(pos);
    pos += 4;
    return v;
  }

  double f64() {
    need(8);
    final v = view.getFloat64(pos);
    pos += 8;
    return v;
  }

  String str(int length) {
    need(length);
    final slice = Uint8List.sublistView(bytes, pos, pos + length);
    pos += length;
    return utf8.decode(slice, allowMalformed: true);
  }

  Uint8List bin(int length) {
    need(length);
    // Copied rather than viewed: an ext payload is decoded recursively and a view
    // into a frame buffer that the socket may reuse is a bug waiting to happen.
    final out = Uint8List.fromList(Uint8List.sublistView(bytes, pos, pos + length));
    pos += length;
    return out;
  }
}

/// Decodes one msgpack document.
Object? msgpackDecode(List<int> input) {
  final bytes = input is Uint8List ? input : Uint8List.fromList(input);
  return _readValue(_Reader(bytes));
}

Object? _readValue(_Reader r) {
  final tag = r.u8();

  if (tag <= 0x7f) return tag; // positive fixint
  if (tag >= 0xe0) return tag - 0x100; // negative fixint
  if (tag >= 0x80 && tag <= 0x8f) return _readMap(r, tag & 0x0f); // fixmap
  if (tag >= 0x90 && tag <= 0x9f) return _readArray(r, tag & 0x0f); // fixarray
  if (tag >= 0xa0 && tag <= 0xbf) return r.str(tag & 0x1f); // fixstr

  switch (tag) {
    case 0xc0:
      return null;
    case 0xc1:
      throw const FormatException('msgpack: 0xc1 is never valid');
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
      // ext8: size, then type. Read into locals so the order is not left to
      // argument-evaluation rules.
      final length = r.u8();
      return _readExt(r, length, r.i8());
    case 0xc8:
      final length = r.u16();
      return _readExt(r, length, r.i8());
    case 0xc9:
      final length = r.u32();
      return _readExt(r, length, r.i8());
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
      return r.u64();
    case 0xd0:
      return r.i8();
    case 0xd1:
      return r.i16();
    case 0xd2:
      return r.i32();
    case 0xd3:
      return r.i64();
    // fixext 1/2/4/8/16: the type byte comes before the payload.
    case 0xd4:
      return _readExt(r, 1, r.i8());
    case 0xd5:
      return _readExt(r, 2, r.i8());
    case 0xd6:
      return _readExt(r, 4, r.i8());
    case 0xd7:
      return _readExt(r, 8, r.i8());
    case 0xd8:
      return _readExt(r, 16, r.i8());
    case 0xd9:
      return r.str(r.u8());
    case 0xda:
      return r.str(r.u16());
    case 0xdb:
      return r.str(r.u32());
    case 0xdc:
      return _readArray(r, r.u16());
    case 0xdd:
      return _readArray(r, r.u32());
    case 0xde:
      return _readMap(r, r.u16());
    case 0xdf:
      return _readMap(r, r.u32());
    default:
      throw FormatException('msgpack: unknown tag 0x${tag.toRadixString(16)}');
  }
}

List<Object?> _readArray(_Reader r, int length) {
  return List<Object?>.generate(length, (_) => _readValue(r), growable: false);
}

Map<String, Object?> _readMap(_Reader r, int length) {
  final out = <String, Object?>{};
  for (var i = 0; i < length; i++) {
    final key = _readValue(r);
    final value = _readValue(r);
    // Keys are strings in every Gather message; anything else is stringified so
    // nothing is silently dropped.
    out[key is String ? key : '$key'] = value;
  }
  return out;
}

Object? _readExt(_Reader r, int length, int type) {
  final payload = r.bin(length);

  switch (type) {
    case 0:
      // A registered value object: msgpack `{k: typeName, v: body}`.
      final wrapper = msgpackDecode(payload);
      if (wrapper is Map<String, Object?> && wrapper.containsKey('k')) {
        final body = wrapper['v'];
        if (body is Map<String, Object?>) {
          return <String, Object?>{r'$type': wrapper['k'], ...body};
        }
        return <String, Object?>{r'$type': wrapper['k'], 'value': body};
      }
      return wrapper;
    case 1:
      // DateTime as integer milliseconds.
      final millis = msgpackDecode(payload);
      if (millis is int) return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
      return millis;
    case 2:
      // A JS Set, encoded as an array. Kept as a list: everything downstream is
      // JSON-bound anyway.
      final items = msgpackDecode(payload);
      return items is List ? items : const <Object?>[];
    case 4:
      return msgpackUndefined;
    case 5:
      if (payload.lengthInBytes == 8) {
        return ByteData.view(payload.buffer, payload.offsetInBytes, 8).getInt64(0);
      }
      return msgpackDecode(payload);
    case -1:
      // Standard msgpack timestamp, in case the server ever uses it.
      if (payload.lengthInBytes == 4) {
        final seconds = ByteData.view(payload.buffer, payload.offsetInBytes, 4).getUint32(0);
        return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
      }
      if (payload.lengthInBytes == 8) {
        final raw = ByteData.view(payload.buffer, payload.offsetInBytes, 8).getUint64(0);
        final nanos = raw >> 34;
        final seconds = raw & 0x3ffffffff;
        return DateTime.fromMillisecondsSinceEpoch(
          seconds * 1000 + nanos ~/ 1000000,
          isUtc: true,
        );
      }
      return MsgpackExt(type, payload);
    default:
      return MsgpackExt(type, payload);
  }
}

/// MessagePack encoder, scoped to what we actually send.
///
/// The client sends five frame shapes — `Authenticate`, `ConnectToSpace`,
/// `Subscribe`, `Heartbeat` and one `Action` — and every value in them is a
/// string, number, boolean, null, list or plain map. So this handles that and
/// nothing else.
///
/// Refusing loudly matters more than being general. Gather ignores a frame it
/// cannot parse — no error, no close, just silence and heartbeats — so a value
/// silently mangled here would surface as an unexplained failure to connect.
Uint8List msgpackEncode(Object? value) {
  final out = BytesBuilder(copy: false);
  _write(out, value);
  return out.toBytes();
}

void _write(BytesBuilder out, Object? value) {
  if (value == null) {
    out.addByte(0xc0);
    return;
  }
  if (value is bool) {
    out.addByte(value ? 0xc3 : 0xc2);
    return;
  }
  if (value is int) {
    _writeInt(out, value);
    return;
  }
  if (value is double) {
    _writeDouble(out, value);
    return;
  }
  if (value is String) {
    _writeString(out, value);
    return;
  }
  if (value is List) {
    _writeList(out, value);
    return;
  }
  if (value is Map) {
    _writeMap(out, value);
    return;
  }
  throw ArgumentError.value(
    value,
    'value',
    'msgpack encode: unsupported ${value.runtimeType} — convert it to a plain value first',
  );
}

void _writeInt(BytesBuilder out, int value) {
  if (value >= 0 && value <= 0x7f) {
    out.addByte(value);
    return;
  }
  if (value < 0 && value >= -32) {
    out.addByte(0x100 + value);
    return;
  }
  if (value >= 0 && value <= 0xffffffff) {
    out.addByte(0xce); // uint32
    final head = ByteData(4)..setUint32(0, value);
    out.add(head.buffer.asUint8List());
    return;
  }
  // Timestamps are past 2^32 ms, so int64 is the common case here, not a corner.
  out.addByte(0xd3); // int64
  final head = ByteData(8)..setInt64(0, value);
  out.add(head.buffer.asUint8List());
}

void _writeDouble(BytesBuilder out, double value) {
  if (!value.isFinite) {
    throw ArgumentError.value(value, 'value', 'msgpack encode: not a finite number');
  }
  // A whole-number double is written as an integer, because that is what the
  // bridge's JS encoder does — `Number.isInteger(3.0)` is true there, and JS has
  // no separate int type to distinguish `3` from `3.0`. Dart does, so without this
  // the two encoders would disagree on any coordinate that arrived as a double,
  // and the handshake's byte-for-byte equivalence would quietly stop holding.
  if (value == value.roundToDouble() && value.abs() < 9007199254740992.0) {
    _writeInt(out, value.toInt());
    return;
  }
  out.addByte(0xcb); // float64
  final head = ByteData(8)..setFloat64(0, value);
  out.add(head.buffer.asUint8List());
}

void _writeString(BytesBuilder out, String value) {
  final body = utf8.encode(value);
  if (body.length < 32) {
    out.addByte(0xa0 | body.length);
  } else if (body.length <= 0xff) {
    out..addByte(0xd9)..addByte(body.length);
  } else if (body.length <= 0xffff) {
    out.addByte(0xda); // str16
    out.add((ByteData(2)..setUint16(0, body.length)).buffer.asUint8List());
  } else {
    // str32. A Firebase ID token is ~1 KB so str16 covers it, but a token is the
    // one field where truncation would be silent and maddening.
    out.addByte(0xdb);
    out.add((ByteData(4)..setUint32(0, body.length)).buffer.asUint8List());
  }
  out.add(body);
}

void _writeList(BytesBuilder out, List<Object?> value) {
  if (value.length < 16) {
    out.addByte(0x90 | value.length);
  } else {
    out.addByte(0xdc); // array16
    out.add((ByteData(2)..setUint16(0, value.length)).buffer.asUint8List());
  }
  for (final item in value) {
    _write(out, item);
  }
}

void _writeMap(BytesBuilder out, Map<Object?, Object?> value) {
  // Undefined is dropped rather than encoded as nil: an absent optional field and
  // a field explicitly set to null are different things to Gather, and the
  // handshake relies on omitting fields we have no value for.
  final keys = value.keys.where((k) => value[k] != msgpackUndefined).toList(growable: false);
  if (keys.length < 16) {
    out.addByte(0x80 | keys.length);
  } else {
    out.addByte(0xde); // map16
    out.add((ByteData(2)..setUint16(0, keys.length)).buffer.asUint8List());
  }
  for (final key in keys) {
    if (key is! String) {
      throw ArgumentError.value(key, 'key', 'msgpack encode: map keys must be strings');
    }
    _writeString(out, key);
    _write(out, value[key]);
  }
}
