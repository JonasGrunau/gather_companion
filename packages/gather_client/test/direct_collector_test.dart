/// [DirectCollector] against a real WebSocket, and the fold on top of it.
///
/// The counterpart of `bridge/test/direct.test.js`. Nothing here reaches Gather or
/// Google: the socket is a local `HttpServer` and the token endpoint is a fake, so a
/// green run never depends on whether the developer has paired.
library;

import 'dart:async';

import 'package:gather_client/gather_client.dart';
import 'package:gather_events/gather_events.dart';
import 'package:test/test.dart';

import 'fake_gather.dart';

/// Waits for the first stream event satisfying [test], or fails the test.
Future<T> firstWhere<T>(
  Stream<T> stream,
  bool Function(T) test, {
  Duration timeout = const Duration(seconds: 5),
  String? reason,
}) =>
    stream.firstWhere(test).timeout(
          timeout,
          onTimeout: () => throw StateError('timed out waiting for ${reason ?? T}'),
        );

void main() {
  late FakeGatherServer gather;
  late FakeGatherHttp http;
  DirectCollector? collector;

  setUp(() async {
    gather = await FakeGatherServer.start();
    http = FakeGatherHttp();
  });

  tearDown(() async {
    await collector?.dispose();
    collector = null;
    await gather.close();
  });

  DirectCollector build({String? spaceId = 'space-1'}) {
    final auth = GatherAuth(
      credentials: const GatherCredentials(refreshToken: 'refresh-1'),
      http: http,
    );
    return collector = DirectCollector(
      auth: auth,
      spaceId: spaceId,
      socketUrl: gather.url,
    );
  }

  test('the handshake is sent in order, then enters once the dump names us', () async {
    final c = build()..start();
    final conn = await firstWhere(gather.onDumped, (_) => true, reason: 'a dump');

    expect(
      conn.received.take(4).map((f) => f['type']),
      ['Authenticate', 'ConnectToSpace', 'Subscribe', 'Action'],
    );
    expect(conn.received[3]['action'], 'loadSpaceUser');

    // A configured space id carries no spaceUserId, so entering waits for the
    // `Connection` row inside the dump to say which avatar is ours.
    await firstWhere(c.rosters, (r) => r.selfId != null, reason: 'selfId');
    await pumpEventQueue();

    expect(
      conn.received.map((f) => f['action']),
      containsAllInOrder(['loadSpaceUser', 'enterSpace', 'reportActivity']),
    );
    expect(
      conn.received.firstWhere((f) => f['action'] == 'enterSpace')['args'],
      ['SpaceUser', 'me-1'],
    );
    expect(c.stats()['entered'], isTrue);
  });

  test('a space resolved from REST enters in the handshake itself', () async {
    // `/users/me/recent-spaces` hands over spaceUserId, so this path does not have
    // to wait for the dump to say who we are.
    http.spaces = {
      'space-1': {'id': 'space-1', 'name': 'Test Space', 'spaceUserId': 'me-1'},
    };
    build(spaceId: null).start();
    final conn = await firstWhere(gather.onDumped, (_) => true, reason: 'a dump');

    expect(
      conn.received.map((f) => f['action']).whereType<String>(),
      ['loadSpaceUser', 'enterSpace', 'reportActivity'],
      reason: 'entering rides along with the handshake, before any frame arrives',
    );
  });

  test('entering happens once per connection, not once per frame', () async {
    // `numTimesEnteredSpace` is a permanent counter on the user's own profile, so
    // a second enterSpace on the same socket costs something and buys nothing.
    final c = build()..start();
    final conn = await firstWhere(gather.onDumped, (_) => true, reason: 'a dump');
    await firstWhere(c.rosters, (r) => r.selfId != null, reason: 'selfId');

    conn.delta([
      {'op': 'replace', 'model': 'SpaceUser', 'id': 'them-1', 'path': '/position/x', 'data': 9},
    ]);
    await pumpEventQueue();

    expect(conn.received.where((f) => f['action'] == 'enterSpace'), hasLength(1));
  });

  test('the socket url carries the space and our firebase uid', () async {
    build().start();
    final conn = await firstWhere(gather.onDumped, (_) => true, reason: 'a dump');

    expect(conn.url, contains('spaceId=space-1'));
    expect(conn.url, contains('authUserId=uid-1'));
  });

  test('the state dump resolves which avatar is ours', () async {
    final c = build()..start();
    await firstWhere(c.rosters, (r) => r.selfId != null, reason: 'selfId');

    expect(c.selfId, 'me-1');
    expect(c.hasState, isTrue);
    expect(c.reader.spaceName, 'Test Space');
  });

  test('holding no state is not reported as healthy', () async {
    // An empty roster reported as healthy would let the app render a confident
    // "nobody is following you" out of nothing.
    final c = build();
    expect(c.healthy, isFalse);
    expect(c.hasState, isFalse);

    c.start();
    await firstWhere(c.statuses, (s) => s.healthy, reason: 'a healthy status');
    expect(c.hasState, isTrue);
  });

  group('the event bus', () {
    test('a wave arrives even though its frame carries no patches', () async {
      final c = build()..start();
      final conn = await firstWhere(gather.onDumped, (_) => true, reason: 'a dump');

      final waves = c.interactions.where((e) => e.name == 'WaveEvent').first;
      conn.bus([waveEvent()]);

      final wave = await waves.timeout(const Duration(seconds: 5));
      expect(wave.senderId, 'them-1');
      expect(wave.targetUserIds, ['me-1']);
      expect(wave.sentTime, '2026-08-07T14:22:20.563Z');
      expect(wave.isFor('me-1'), isTrue);
      expect(wave.isFor('somebody-else'), isFalse);
    });

    test('a bus-only frame is not counted as unrecognised', () async {
      // The bug this whole channel came from: `patches` is empty, so the frame fell
      // through to the unknown-frame counter and the wave vanished.
      final c = build()..start();
      final conn = await firstWhere(gather.onDumped, (_) => true, reason: 'a dump');

      // Read the counter only once the dump has been *processed*. `SpaceStatus`
      // carries no patches either and is legitimately unrecognised, so sampling
      // before it lands would blame the wave for it.
      await firstWhere(c.rosters, (r) => r.selfId != null, reason: 'selfId');
      final before = c.reader.stats()['unknownFrames'] as int;

      final seen = c.interactions.first;
      conn.bus([waveEvent()]);
      await seen.timeout(const Duration(seconds: 5));

      expect(c.reader.stats()['unknownFrames'], before, reason: 'the wave was understood');
      expect(c.reader.stats()['busEvents'], 1);
    });

    test('chat is carried through without being given wording', () async {
      final c = build()..start();
      final conn = await firstWhere(gather.onDumped, (_) => true, reason: 'a dump');

      final seen = c.interactions.first;
      conn.bus([
        {
          'payload': {'eventName': 'ChatBroadcastNewMessage', 'senderId': 'them-1'},
          'options': <String, Object?>{},
        },
      ]);

      final event = await seen.timeout(const Duration(seconds: 5));
      expect(event.name, 'ChatBroadcastNewMessage');
      expect(event.targetUserIds, isEmpty);
    });
  });

  group('teleport', () {
    test('refuses before it knows which avatar is ours', () {
      final c = build();
      expect(c.teleport(x: 1, y: 1).ok, isFalse);
      expect(c.teleport(x: 1, y: 1).detail, contains('not connected'));
    });

    test('sends flat x/y with a direction', () async {
      final c = build()..start();
      final conn = await firstWhere(gather.onDumped, (_) => true, reason: 'a dump');
      await firstWhere(c.rosters, (r) => r.selfId != null, reason: 'selfId');

      expect(c.teleport(x: 65, y: 38).ok, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final sent = conn.received.lastWhere((f) => f['action'] == 'teleport');
      final args = sent['args'] as List<Object?>;
      expect(args[0], 'SpaceUser');
      expect(args[1], 'me-1');
      // `{position: {x, y}}` is rejected by the real server; flat is the shape.
      expect(args[2], {'x': 65, 'y': 38, 'direction': 'Down'});
    });
  });

  group('a dead credential is told apart from a bad network', () {
    test('a revoked refresh token asks for pairing and stops retrying', () async {
      http
        ..status = 400
        ..errorCode = 'TOKEN_EXPIRED';
      final c = build()..start();

      final status = await firstWhere(c.statuses, (s) => s.needsPairing,
          reason: 'a needsPairing status');
      expect(status.healthy, isFalse);
      expect(status.detail, contains('TOKEN_EXPIRED'));

      // Retrying a revoked token forever would be pointless, and would hide the one
      // thing the user has to act on behind a spinner.
      final refreshes = http.refreshes;
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(http.refreshes, refreshes);
    });

    test('an outage retries quietly rather than sending anyone to re-pair', () async {
      http
        ..status = 503
        ..errorCode = null;
      final c = build()..start();

      final status =
          await firstWhere(c.statuses, (s) => s.detail != null, reason: 'a status');
      expect(status.needsPairing, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 1400));
      expect(http.refreshes, greaterThan(1), reason: 'it kept trying');
    });
  });

  group('the fold on top', () {
    test('somebody following you is observed, not guessed', () async {
      final c = build()..start();
      final conn = await firstWhere(gather.onDumped, (_) => true, reason: 'a dump');
      final tracker = PresenceTracker();

      final events = <GatherEvent>[];
      c.rosters.listen((roster) => events.addAll(tracker.applyRoster(roster).emit));

      await firstWhere(c.rosters, (r) => r.selfId != null, reason: 'selfId');
      conn.delta([
        {
          'op': 'replace',
          'model': 'SpaceUser',
          'id': 'them-1',
          'path': '/followTargetId',
          'data': 'me-1',
        },
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 600));

      final follows = events.whereType<FollowEvent>().toList();
      expect(follows, hasLength(1));
      expect(follows.first.started, isTrue);
      expect(follows.first.followerId, 'them-1');
      expect(follows.first.targetIsSelf, isTrue);
      expect(tracker.snapshot().followers.map((p) => p.id), ['them-1']);
    });

    test('a wave becomes a notification that names the sender', () async {
      final c = build()..start();
      final conn = await firstWhere(gather.onDumped, (_) => true, reason: 'a dump');
      final tracker = PresenceTracker();
      c.rosters.listen(tracker.applyRoster);
      await firstWhere(c.rosters, (r) => r.selfId != null, reason: 'selfId');

      final events = <GatherEvent>[];
      c.interactions.listen((e) => events.addAll(tracker.applyInteraction(e).emit));
      conn.bus([waveEvent()]);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final shown = events.whereType<NotificationShownEvent>().toList();
      expect(shown, hasLength(1));
      expect(shown.first.notificationType, 'wave');
      expect(shown.first.senderId, 'them-1');
      expect(shown.first.body, 'Neighbour waved at you');
      expect(shown.first.at.toIso8601String(), startsWith('2026-08-07T14:22:20.563'));
    });

    test('the same person waving repeatedly is reported once', () async {
      // One person produced 41 WaveEvents in eight seconds on a live space.
      final c = build()..start();
      final conn = await firstWhere(gather.onDumped, (_) => true, reason: 'a dump');
      final tracker = PresenceTracker();
      c.rosters.listen(tracker.applyRoster);
      await firstWhere(c.rosters, (r) => r.selfId != null, reason: 'selfId');

      final events = <GatherEvent>[];
      c.interactions.listen((e) => events.addAll(tracker.applyInteraction(e).emit));
      for (var i = 0; i < 6; i++) {
        conn.bus([waveEvent()]);
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(events.whereType<NotificationShownEvent>(), hasLength(1));
    });

    test('a wave aimed at somebody else is not reported', () async {
      final c = build()..start();
      final conn = await firstWhere(gather.onDumped, (_) => true, reason: 'a dump');
      final tracker = PresenceTracker();
      c.rosters.listen(tracker.applyRoster);
      await firstWhere(c.rosters, (r) => r.selfId != null, reason: 'selfId');

      final events = <GatherEvent>[];
      c.interactions.listen((e) => events.addAll(tracker.applyInteraction(e).emit));
      conn.bus([waveEvent(targetId: 'someone-else')]);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(events, isEmpty);
    });
  });

  test('a reconnect gets a whole fresh dump, which is why resync is a reconnect',
      () async {
    final c = build()..start();
    await firstWhere(gather.onDumped, (_) => true, reason: 'the first dump');

    final second = gather.onDumped.first;
    await c.resync();
    await second.timeout(const Duration(seconds: 5));

    expect(gather.connections, hasLength(2));
    expect(c.stats()['connects'], 2);
  });
}
