/// The Dart codec against the bridge's JS one, byte for byte.
///
/// These hex strings were produced by `bridge/lib/msgpack.js`'s own `encode`, and
/// that matters more than any hand-written expectation: the handshake it emits is
/// the one *verified against live Gather*, captured off the desktop client's own
/// outbound frames. Gather does not reject a malformed handshake — it stays silent
/// and keeps heartbeating — so a divergence here would surface as an unexplained
/// failure to connect, on the phone, in the field.
///
/// Regenerate with:
///
/// ```sh
/// node -e "import('./bridge/lib/msgpack.js').then(({encode}) => \
///   console.log(Buffer.from(encode({type:'Subscribe'})).toString('hex')))"
/// ```
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:gather_client/gather_client.dart';
import 'package:test/test.dart';

/// Frames the collector actually sends, with the bytes the bridge sends for them.
const _jsBytes = <String, String>{
  'subscribe': '81a474797065a9537562736372696265',
  'connect': '82a474797065ae436f6e6e656374546f5370616365a773706163654964d92435'
      '383464323762332d626563302d346137362d386231372d396166343539333934636337',
  'heartbeat': '83a474797065a9486561727462656174a974696d657374616d70d30000019f'
      'd5e54400a66f726967696ea6436c69656e74',
  'load': '84a474797065a6416374696f6ea574786e4964d92431313131313131312d32323232'
      '2d333333332d343434342d353535353535353535353535a6616374696f6ead6c6f616453'
      '7061636555736572a46172677393a9537061636555736572c082b0636f6e6e656374696f'
      '6e546172676574aa4f666669636556696577ae636c69656e74506c6174666f726da74465'
      '736b746f70',
  'teleport': '84a474797065a6416374696f6ea574786e4964d92461616161616161612d6262'
      '62622d636363632d646464642d656565656565656565656565a6616374696f6ea874656c'
      '65706f7274a46172677393a9537061636555736572a46d652d3183a17841a17926a96469'
      '72656374696f6ea4446f776e',
  'negatives': '8aa161ffa162e0a163d3ffffffffffffffdfa164d3ffffffff80000000a165'
      'cb400c000000000000a166c3a167c2a168c0a16990a16a80',
};

/// The same values, built in the same key order. Order is load-bearing: msgpack
/// maps are ordered on the wire, and both encoders walk insertion order.
final _values = <String, Object?>{
  'subscribe': {'type': 'Subscribe'},
  'connect': {'type': 'ConnectToSpace', 'spaceId': '584d27b3-bec0-4a76-8b17-9af459394cc7'},
  'heartbeat': {'type': 'Heartbeat', 'timestamp': 1786000000000, 'origin': 'Client'},
  'load': {
    'type': 'Action',
    'txnId': '11111111-2222-3333-4444-555555555555',
    'action': 'loadSpaceUser',
    'args': [
      'SpaceUser',
      null,
      {'connectionTarget': 'OfficeView', 'clientPlatform': 'Desktop'},
    ],
  },
  'teleport': {
    'type': 'Action',
    'txnId': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
    'action': 'teleport',
    'args': [
      'SpaceUser',
      'me-1',
      {'x': 65, 'y': 38, 'direction': 'Down'},
    ],
  },
  'negatives': {
    'a': -1,
    'b': -32,
    'c': -33,
    'd': -2147483648,
    'e': 3.5,
    'f': true,
    'g': false,
    'h': null,
    'i': <Object?>[],
    'j': <String, Object?>{},
  },
};

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _unhex(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

void main() {
  group('encode matches the bridge byte for byte', () {
    for (final name in _jsBytes.keys) {
      test(name, () {
        expect(_hex(msgpackEncode(_values[name])), _jsBytes[name]);
      });
    }
  });

  test('a long token uses str16, because truncating one would be maddening', () {
    // A Firebase ID token is ~1 KB. str8 caps at 255 and would silently cut it.
    final jwt = 'a' * 900;
    final bytes = msgpackEncode({
      'type': 'Authenticate',
      'credential': {'type': 'JWT', 'jwt': jwt},
    });
    expect(_hex(bytes).contains('da0384'), isTrue, reason: 'str16 with length 900');

    final round = msgpackDecode(bytes) as Map<String, Object?>;
    expect((round['credential'] as Map)['jwt'], jwt);
  });

  test('every frame round-trips through our own decoder', () {
    for (final entry in _values.entries) {
      final decoded = msgpackDecode(msgpackEncode(entry.value));
      expect(decoded, isA<Map<String, Object?>>(), reason: entry.key);
    }
  });

  test('the bridge\'s bytes decode to the same values we encoded from', () {
    // The other direction: proves the decoder reads what the *server* would send,
    // not merely what our own encoder produces.
    for (final name in _jsBytes.keys) {
      expect(msgpackDecode(_unhex(_jsBytes[name]!)), _values[name], reason: name);
    }
  });

  group('Gather\'s extension types', () {
    /// ext 0: a value object, `{k: typeName, v: body}`, wrapped in fixext/ext8.
    Uint8List ext(int type, Uint8List payload) {
      final out = BytesBuilder();
      const fixed = {1: 0xd4, 2: 0xd5, 4: 0xd6, 8: 0xd7, 16: 0xd8};
      if (fixed.containsKey(payload.length)) {
        out.addByte(fixed[payload.length]!);
      } else {
        out..addByte(0xc7)..addByte(payload.length);
      }
      out.addByte(type & 0xff);
      out.add(payload);
      return out.toBytes();
    }

    test('a Position decodes flat, with a \$type tag', () {
      final body = msgpackEncode({
        'k': 'Position',
        'v': {'x': 12, 'y': 30},
      });
      expect(msgpackDecode(ext(0, body)), {r'$type': 'Position', 'x': 12, 'y': 30});
    });

    test('a value object whose body is not a map keeps it under `value`', () {
      final body = msgpackEncode({'k': 'Direction', 'v': 'Down'});
      expect(msgpackDecode(ext(0, body)), {r'$type': 'Direction', 'value': 'Down'});
    });

    test('a DateTime is integer milliseconds', () {
      final body = msgpackEncode(1786000000000);
      expect(
        msgpackDecode(ext(1, body)),
        DateTime.fromMillisecondsSinceEpoch(1786000000000, isUtc: true),
      );
    });

    test('a Set arrives as a list', () {
      expect(msgpackDecode(ext(2, msgpackEncode(['a', 'b']))), ['a', 'b']);
    });

    test('undefined is not null, because the difference carries meaning', () {
      // An absent `followTargetId` means nobody is being followed; a null one is a
      // field explicitly cleared. `GameProtocolReader` relies on telling them apart.
      expect(msgpackDecode(ext(4, Uint8List(0))), same(msgpackUndefined));
      expect(msgpackDecode(ext(4, Uint8List(0))), isNot(isNull));
    });

    test('a bigint comes back as an int, since Dart\'s is already 64-bit', () {
      final payload = Uint8List(8);
      ByteData.view(payload.buffer).setInt64(0, 9007199254740993);
      expect(msgpackDecode(ext(5, payload)), 9007199254740993);
    });

    test('an unknown extension is kept rather than dropped', () {
      final decoded = msgpackDecode(ext(9, Uint8List.fromList([1, 2, 3, 4])));
      expect(decoded, isA<MsgpackExt>());
      expect((decoded as MsgpackExt).type, 9);
    });
  });

  group('refusing rather than guessing', () {
    test('a truncated frame throws instead of returning half a value', () {
      expect(() => msgpackDecode(_unhex('82a474797065')), throwsFormatException);
    });

    test('0xc1 is never valid', () {
      expect(() => msgpackDecode(Uint8List.fromList([0xc1])), throwsFormatException);
    });

    test('a value Gather could not read is refused, not mangled', () {
      // Gather ignores a frame it cannot parse in silence, so guessing here would
      // surface as a mysterious failure to connect.
      expect(() => msgpackEncode({1: 'int key'}), throwsArgumentError);
      expect(() => msgpackEncode(double.infinity), throwsArgumentError);
      expect(() => msgpackEncode(Object()), throwsArgumentError);
    });

    test('a DateTime goes out as ext 1, the way one comes back', () {
      // This used to be on the refused list, and it was correct to be: nothing we
      // sent carried a time. `setCustomStatus` does — `clearCondition.clearAt` is
      // when Gather should take the status line down by itself — so the encoder
      // learned the shape its own decoder had always known.
      final when = DateTime.utc(2026, 8, 13, 18, 33, 7);
      expect(msgpackDecode(msgpackEncode(when)), when);

      // Nine bytes of int64 payload, so it lands in ext8 rather than any of the
      // fixed-width forms: 0xc7, length, type.
      final bytes = msgpackEncode(when);
      expect(bytes[0], 0xc7);
      expect(bytes[1], 9);
      expect(bytes[2], 1);
    });

    test('undefined is dropped from a map, null is kept', () {
      // The handshake relies on omitting fields we have no value for.
      final bytes = msgpackEncode({'a': msgpackUndefined, 'b': null});
      expect(msgpackDecode(bytes), {'b': null});
    });
  });

  test('utf-8 survives the round trip', () {
    const name = 'Zoë 👋 田中';
    final decoded = msgpackDecode(msgpackEncode({'name': name})) as Map<String, Object?>;
    expect(decoded['name'], name);
    // And the length prefix counts bytes, not runes.
    expect(msgpackEncode(name).length, utf8.encode(name).length + 1);
  });
}
