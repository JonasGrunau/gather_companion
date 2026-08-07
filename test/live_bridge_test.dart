import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/pairing.dart';
import 'package:gather_companion/src/settings.dart';

/// End-to-end against a real bridge, exercising the app's own pairing code rather
/// than a mock of it.
///
/// Pairing is the whole of what the app still asks the computer for, which makes it
/// the only thing worth an integration test here. What it has to get right changed:
/// the response now carries a **second** credential — the Gather refresh token — and
/// getting that wrong means an app that pairs successfully and then never connects,
/// which is the most confusing failure this project can produce.
///
/// Skipped unless a bridge is running and a code was left for it, so `flutter test`
/// stays green on a machine with no Gather on it. To run it:
///
/// ```sh
/// node ../bridge/bin/gather-bridge.js run --port 7830 --token t --log-file /tmp/f.log &
/// node ../bridge/bin/gather-bridge.js pair --port 7830   # note the code
/// GATHER_TEST_PORT=7830 GATHER_TEST_CODE=XXXXXXXX flutter test test/live_bridge_test.dart
/// ```
void main() {
  final port = int.tryParse(Platform.environment['GATHER_TEST_PORT'] ?? '');
  final code = Platform.environment['GATHER_TEST_CODE'];
  final configured = port != null && code != null && code.isNotEmpty;

  test('pairs with a live bridge and is handed both credentials', () async {
    final result = await claimPairing(host: '127.0.0.1', port: port!, code: code!);
    expect(result, isA<PairSuccess>(), reason: 'the code should have been accepted');
    final success = result as PairSuccess;

    // The bridge token, which is now good for exactly one thing: telling the bridge
    // where to send pushes.
    expect(success.settings.token, isNotEmpty);
    expect(success.settings.port, port);
    expect(success.name, isNotEmpty);

    if (success.canReachGather) {
      // A refresh token, not an ID token. ID tokens last an hour, and a phone that had
      // to re-pair hourly would be useless.
      expect(success.gather.refreshToken.length, greaterThan(100));
      expect(
        success.gather.refreshToken,
        matches(RegExp(r'^[A-Za-z0-9_-]+$')),
        reason: 'Firebase refresh tokens are base64url',
      );
      expect(success.spaceId, isNotNull, reason: 'so the first connection needs no REST call');
    } else {
      // A bridge that has not run `adopt`. Everything else about pairing worked, and
      // the app is expected to say so rather than land on a feed it can never fill.
      expect(success.gather.refreshToken, isEmpty);
    }

    // A used code must not work twice.
    final replay = await claimPairing(host: '127.0.0.1', port: port, code: code);
    expect(replay, isA<PairFailure>(), reason: 'pairing codes are single use');
  },
      skip: configured ? false : 'set GATHER_TEST_PORT and GATHER_TEST_CODE to run');

  test('an unreachable computer fails with something a person can act on', () async {
    // Port 1 is never a bridge. The wording matters more than the failure: on iOS the
    // *first* connection to a private address is what raises the local-network prompt,
    // and that attempt fails while the prompt is still open.
    final result = await claimPairing(host: '127.0.0.1', port: 1, code: 'ABCDEFGH');

    expect(result, isA<PairFailure>());
    expect((result as PairFailure).message, isNotEmpty);
  });

  test('a bare code with no address is still readable', () {
    // Typed by hand, from a terminal the phone cannot see.
    expect(PairPayload.parse('abcd-efgh')?.code, 'ABCDEFGH');
    expect(PairPayload.parse('studio.local:7799:ABCDEFGH')?.host, 'studio.local');
    expect(PairPayload.parse('studio.local:7799:ABCDEFGH')?.port, 7799);
    // `0`, `1`, `I`, `L` and `O` are not in the alphabet, so this cannot be a code and
    // must not be guessed into one.
    expect(PairPayload.parse('OOOOOOOO'), isNull);
  });

  test('the default port is the bridge default', () {
    expect(BridgeSettings.defaultPort, 7799);
  });
}
