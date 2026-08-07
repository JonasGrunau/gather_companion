import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/bridge_client.dart';
import 'package:gather_companion/src/pairing.dart';
import 'package:gather_companion/src/relevance.dart';
import 'package:gather_events/gather_events.dart';

/// End-to-end against a real bridge, exercising the app's own pairing and client
/// code rather than a mock of them.
///
/// Skipped unless a bridge is running and a code was left for it, so `flutter
/// test` stays green on a machine with no Gather on it. To run it:
///
/// ```sh
/// node ../bridge/bin/gather-bridge.js run --port 7830 --token t --log-file /tmp/f.log &
/// node ../bridge/bin/gather-bridge.js pair --port 7830   # note the code
/// GATHER_TEST_PORT=7830 GATHER_TEST_CODE=XXXXXXXX GATHER_TEST_LOG=/tmp/f.log flutter test
/// ```
void main() {
  final port = int.tryParse(Platform.environment['GATHER_TEST_PORT'] ?? '');
  final code = Platform.environment['GATHER_TEST_CODE'];
  final logPath = Platform.environment['GATHER_TEST_LOG'];
  final configured = port != null && code != null && code.isNotEmpty && logPath != null;

  test('pairs with a live bridge and receives a classified feed', () async {
    // ---- pair, with the app's own claim code -------------------------------
    final result = await claimPairing(host: '127.0.0.1', port: port!, code: code!);
    expect(result, isA<PairSuccess>(), reason: 'the code should have been accepted');
    final settings = (result as PairSuccess).settings;
    expect(settings.token, isNotEmpty);
    expect(settings.port, port);

    // A used code must not work twice.
    final replay = await claimPairing(host: '127.0.0.1', port: port, code: code);
    expect(replay, isA<PairFailure>(), reason: 'pairing codes are single use');

    // ---- connect, with the app's own client --------------------------------
    final client = BridgeClient(settings: settings);
    final snapshots = <PresenceSnapshot>[];
    final events = <GatherEvent>[];
    client.snapshots.listen(snapshots.add);
    client.events.listen(events.add);
    client.connect();

    await _until(() => snapshots.isNotEmpty, 'a snapshot on connect');
    expect(snapshots.first.players, isA<List<PlayerRef>>());

    // ---- feed it a real log line and watch it come back --------------------
    // A wave is the one thing still read from the desktop client's log; it
    // exists in no part of Gather's game state, so this is the only signal a
    // written log line can still produce.
    File(logPath!).writeAsStringSync(
      "[2026-08-04 12:00:02.200] [info]  (main)                        "
      "IPC Event: SHOW_NOTIFICATION { type: 'wave' }\n"
      '[2026-08-04 12:00:02.201] [info]  (main)                        '
      'Showing notification 62c41002-9661-4429-b66e-ae369f83e916: wave\n',
      mode: FileMode.append,
    );

    await _until(
      () => events.any((e) => e is NotificationShownEvent),
      'a notification event derived from the log line',
    );

    final wave = events.whereType<NotificationShownEvent>().first;
    expect(wave.notificationType, 'wave');

    // ---- and that the feed would actually show it ---------------------------
    final look = lookOf(wave, (id) => id.substring(0, 8));
    expect(look.relevance, Relevance.notable);

    await client.dispose();
  },
      skip: configured
          ? false
          : 'set GATHER_TEST_PORT, GATHER_TEST_CODE and GATHER_TEST_LOG to run');
}

/// Polls until [condition] holds, so the test does not depend on a fixed sleep.
Future<void> _until(bool Function() condition, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('timed out waiting for $what');
}

/// Unused, but keeps the analyzer honest about the import if the body changes.
// ignore: unused_element
String _pretty(Object? value) => const JsonEncoder.withIndent('  ').convert(value);
