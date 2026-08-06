import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/bridge_client.dart';
import 'package:gather_companion/src/settings.dart';

/// A bridge that only does the part [BridgeClient] cares about: accept a socket
/// and say something on it. Counting sockets is the point — the bug these tests
/// exist for was invisible from the client's own state and only showed up as
/// connections piling up on the computer.
class _FakeBridge {
  late final HttpServer _server;
  final List<WebSocket> sockets = [];

  int get port => _server.port;
  int get accepted => sockets.length;
  int get open => sockets.where((s) => s.readyState == WebSocket.open).length;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(_server.forEach((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      // Nothing here reads client messages, but the socket still has to be
      // listened to: without a subscription the incoming close frame is never
      // processed and `readyState` never leaves `open`, which would make every
      // socket in these tests look permanently alive.
      socket.listen((_) {}, onError: (Object _) {}, cancelOnError: true);
      // The real bridge always leads with a snapshot, and that first frame is
      // what flips the client to live.
      socket.add(jsonEncode({
        'kind': 'snapshot',
        'seq': 1,
        'snapshot': {'type': 'presence.snapshot', 'players': <Object?>[]},
      }));
    }));
  }

  Future<void> stop() async {
    for (final socket in sockets) {
      await socket.close();
    }
    await _server.close(force: true);
  }
}

Future<void> _until(bool Function() condition, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('timed out waiting for $what');
}

void main() {
  late _FakeBridge bridge;
  late BridgeClient client;

  setUp(() async {
    bridge = _FakeBridge();
    await bridge.start();
    client = BridgeClient(
      settings: BridgeSettings(host: '127.0.0.1', port: bridge.port, token: 't'),
    );
  });

  tearDown(() async {
    await client.dispose();
    await bridge.stop();
  });

  test('overlapping connects leave exactly one socket open', () async {
    client.connect();
    await _until(() => client.currentStatus.isLive, 'the first connection to go live');
    expect(bridge.open, 1);

    // Resuming, pulling to refresh and a firing retry timer can all land in the
    // same tick on a phone. Each of these used to open its own socket and
    // orphan the one before it: still connected, still subscribed, no longer
    // reachable through the client. They accumulated one per launch, and when
    // one of them eventually died it tore down the healthy socket with it,
    // which is what a reopened app failing to connect actually was.
    client.connect();
    client.connect();
    client.connect();

    await _until(() => client.currentStatus.isLive, 'the link to settle');
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(bridge.open, 1, reason: 'only the newest socket may still be open');
    expect(client.currentStatus.state, LinkState.live);
  });

  test('dispose leaves nothing connected', () async {
    client.connect();
    await _until(() => client.currentStatus.isLive, 'a live link');
    client.connect();
    await _until(() => client.currentStatus.isLive, 'the replacement to go live');

    await client.dispose();
    await _until(() => bridge.open == 0, 'every socket to close');
  });

  test('a dropped connection still retries and recovers', () async {
    client.connect();
    await _until(() => client.currentStatus.isLive, 'a live link');

    // Guards the other direction: generation checks must not deafen the client
    // to a genuine failure on the socket it is actually using.
    await bridge.sockets.last.close();
    await _until(
      () => client.currentStatus.state == LinkState.retrying,
      'the drop to be noticed',
    );
    await _until(() => client.currentStatus.isLive, 'the link to come back');
    expect(bridge.accepted, greaterThanOrEqualTo(2));
    expect(bridge.open, 1);
  });
}
