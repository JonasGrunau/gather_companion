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

  DirectCollector build({
    String? spaceId = 'space-1',
    Duration? silenceLimit,
    void Function(String)? log,
  }) {
    final auth = GatherAuth(
      credentials: const GatherCredentials(refreshToken: 'refresh-1'),
      http: http,
    );
    return collector = DirectCollector(
      auth: auth,
      spaceId: spaceId,
      socketUrl: gather.url,
      log: log,
      silenceLimit: silenceLimit ?? const Duration(seconds: 45),
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

    test('a gait is its own action, with no arguments at all', () async {
      final c = build()..start();
      final conn = await firstWhere(gather.onDumped, (_) => true, reason: 'a dump');
      await firstWhere(c.rosters, (r) => r.selfId != null, reason: 'selfId');

      expect(c.setGait(Gait.driving).ok, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final sent = conn.received.lastWhere((f) => f['action'] == 'drive');
      // Three separate actions rather than one with a number in it, and each takes
      // nothing — so the tuple is two long, not three padded with null.
      expect(sent['args'], ['SpaceUser', 'me-1']);
    });

    test('each gait names its own action', () async {
      final c = build()..start();
      final conn = await firstWhere(gather.onDumped, (_) => true, reason: 'a dump');
      await firstWhere(c.rosters, (r) => r.selfId != null, reason: 'selfId');

      for (final gait in Gait.values) {
        c.setGait(gait);
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final actions = [
        for (final frame in conn.received)
          if (const {'walk', 'run', 'drive'}.contains(frame['action'])) frame['action'],
      ];
      expect(actions, ['walk', 'run', 'drive']);
    });
  });

  /// The shapes here are transcribed from a capture of the desktop client taken on
  /// 2026-08-13, not inferred. They are asserted literally because the server
  /// rejects a whole action on a schema mismatch — a bare `true` sent as
  /// `{raised: true}` fails, and it fails silently enough to be worth a test.
  group('being a person in the room', () {
    /// Connects, waits until our own row is known, and hands back the socket the
    /// fake saw — everything below needs a `selfId` before it can address anything.
    Future<(DirectCollector, FakeConnection)> connected() async {
      final c = build()..start();
      final conn = await firstWhere(gather.onDumped, (_) => true, reason: 'a dump');
      await firstWhere(c.rosters, (r) => r.selfId != null, reason: 'selfId');
      return (c, conn);
    }

    /// The last frame the fake received for [action], once it has had time to land.
    Future<Map<Object?, Object?>> lastFrame(
      FakeConnection conn,
      String action,
    ) async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return conn.received.lastWhere((f) => f['action'] == action);
    }

    test('setAvailability names the state, and refuses one Gather cannot be set to',
        () async {
      final (c, conn) = await connected();

      expect(c.setAvailability('Busy').ok, isTrue);
      expect((await lastFrame(conn, 'setAvailability'))['args'],
          ['SpaceUser', 'me-1', {'availability': 'Busy'}]);

      // Written by the server when a socket goes away. Claiming it while holding an
      // open one asserts something the connection carrying it contradicts.
      expect(c.setAvailability('Offline').ok, isFalse);
      expect(c.setAvailability('Focused').ok, isFalse);
    });

    test('setCustomStatus carries text, emoji and an expiry as an ext-1 DateTime',
        () async {
      final (c, conn) = await connected();
      final until = DateTime.utc(2026, 8, 13, 18, 33, 7);

      expect(c.setCustomStatus(text: 'Heads down', emoji: '🎧', clearAt: until).ok,
          isTrue);

      final args = (await lastFrame(conn, 'setCustomStatus'))['args'] as List<Object?>;
      expect(args[2], {
        'text': 'Heads down',
        'emoji': '🎧',
        // Survives the encoder's ext 1 and comes back as a DateTime, which is the
        // whole reason `msgpack.dart` learned to write one.
        'clearCondition': {'type': 'DateTime', 'clearAt': until},
      });
    });

    test('setCustomStatus with no expiry omits clearCondition rather than nulling it',
        () async {
      final (c, conn) = await connected();

      expect(c.setCustomStatus(text: 'Back at three').ok, isTrue);

      final args = (await lastFrame(conn, 'setCustomStatus'))['args'] as List<Object?>;
      expect(args[2], {'text': 'Back at three'});
    });

    test('clearCustomStatus and leaveCluster send two arguments, not three', () async {
      final (c, conn) = await connected();

      expect(c.clearCustomStatus().ok, isTrue);
      expect((await lastFrame(conn, 'clearCustomStatus'))['args'],
          ['SpaceUser', 'me-1']);

      expect(c.leaveCluster().ok, isTrue);
      expect((await lastFrame(conn, 'leaveCluster'))['args'], ['SpaceUser', 'me-1']);
    });

    test('setHandRaised sends a bare bool and faceDirection a bare string', () async {
      final (c, conn) = await connected();

      expect(c.setHandRaised(true).ok, isTrue);
      expect((await lastFrame(conn, 'setHandRaised'))['args'],
          ['SpaceUser', 'me-1', true]);

      expect(c.faceDirection('Left').ok, isTrue);
      expect((await lastFrame(conn, 'faceDirection'))['args'],
          ['SpaceUser', 'me-1', 'Left']);

      expect(c.faceDirection('Sideways').ok, isFalse);
    });

    test('broadcastEmote sends the emoji, a count and an empty fan-out list',
        () async {
      final (c, conn) = await connected();

      expect(c.broadcastEmote('👋').ok, isTrue);
      expect((await lastFrame(conn, 'broadcastEmote'))['args'], [
        'SpaceUser',
        'me-1',
        {'emote': '👋', 'count': 1, 'ambientlyConnectedUserIds': <String>[]},
      ]);

      expect(c.broadcastEmote('').ok, isFalse);
    });

    test('every one of them refuses before it knows which avatar is ours', () {
      final c = build();
      expect(c.setAvailability('Busy').ok, isFalse);
      expect(c.setCustomStatus(text: 'x').ok, isFalse);
      expect(c.clearCustomStatus().ok, isFalse);
      expect(c.broadcastEmote('👋').ok, isFalse);
      expect(c.setHandRaised(true).ok, isFalse);
      expect(c.leaveCluster().ok, isFalse);
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

  group('the deaf socket', () {
    // The failure this exists for. Every reconnect in this collector is driven by
    // `onDone`, and a half-open TCP connection never fires one — the peer sent no
    // FIN, so sends keep succeeding and reads simply never deliver anything again.
    // On a phone that is routine: iOS suspends the app, the radio changes cell, wifi
    // drops. Before the watchdog the collector reported full health and a live
    // roster for as long as the process ran while receiving nothing at all.
    //
    // The fake server sends its dump and then nothing, so the silence is real rather
    // than simulated; only the limit is shortened.

    test('a socket that goes silent is torn down and reconnected', () async {
      final lines = <String>[];
      final c = build(silenceLimit: const Duration(milliseconds: 400), log: lines.add)..start();
      await firstWhere(gather.onDumped, (_) => true, reason: 'the first dump');
      await firstWhere(c.rosters, (r) => r.selfId != null, reason: 'selfId');
      expect(c.healthy, isTrue, reason: 'healthy once the dump has landed');

      await firstWhere(gather.onDumped, (_) => true, reason: 'a reconnect')
          .timeout(const Duration(seconds: 5));

      expect(gather.connections.length, greaterThanOrEqualTo(2));
      expect(
        lines.any((l) => l.contains('the socket went deaf')),
        isTrue,
        reason: 'expected the watchdog to say so, got $lines',
      );
    });

    test('a socket still carrying heartbeats is left alone', () async {
      // The other half, and the one that matters more: reconnecting a working socket
      // every few seconds would be worse than the bug being fixed. Nothing here is
      // interesting — only heartbeats — which is exactly what must count as alive.
      final c = build(silenceLimit: const Duration(milliseconds: 400))..start();
      final conn = await firstWhere(gather.onDumped, (_) => true, reason: 'a dump');
      await firstWhere(c.rosters, (r) => r.selfId != null, reason: 'selfId');

      final beat = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => conn.send({'type': 'Heartbeat', 'timestamp': 2, 'origin': 'Server'}),
      );
      addTearDown(beat.cancel);
      await Future<void>.delayed(const Duration(seconds: 2));

      expect(gather.connections, hasLength(1), reason: 'a live socket must not be reconnected');
      expect(c.healthy, isTrue);
    });
  });

  group('what the server made of it', () {
    /// A collector that has connected, been named by the dump, and entered.
    Future<({DirectCollector c, FakeConnection conn})> ready() async {
      final c = build()..start();
      final conn = await firstWhere(gather.onDumped, (_) => true, reason: 'a dump');
      await firstWhere(c.rosters, (r) => r.selfId != null, reason: 'selfId');
      await pumpEventQueue();
      return (c: c, conn: conn);
    }

    test('a refusal is reported, and names the action it answers', () async {
      // The action returned `ok` — the bytes went out — and then did not happen.
      // Nothing about the state would ever say so: validation runs before the
      // action, so there is no patch, no error on the socket, and no close.
      final (:c, :conn) = await ready();
      final refused = c.refusals.first;

      expect(c.setAvailability('Busy').ok, isTrue);
      await pumpEventQueue();
      conn.refuse('setAvailability', 'Cannot set availability while deactivated');

      final refusal = await refused.timeout(const Duration(seconds: 5));
      expect(refusal.action, 'setAvailability');
      expect(refusal.message, 'Cannot set availability while deactivated');
    });

    test('a zod refusal arrives as the field that was wrong', () async {
      final (:c, :conn) = await ready();
      final refused = c.refusals.first;

      c.setCustomStatus(text: 'x' * 5000);
      await pumpEventQueue();
      conn.refuse(
        'setCustomStatus',
        '[{"code":"too_big","path":["text"],"message":"String must contain at most 80 character(s)"}]',
      );

      final refusal = await refused.timeout(const Duration(seconds: 5));
      expect(refusal.message, 'text: String must contain at most 80 character(s)');
    });

    test('a success is not reported as anything', () async {
      final (:c, :conn) = await ready();
      final refusals = <ActionRefused>[];
      final sub = c.refusals.listen(refusals.add);

      c.leaveCluster();
      await pumpEventQueue();
      final sent = conn.received.lastWhere((f) => f['action'] == 'leaveCluster');
      conn.send({
        'type': 'DeltaState',
        'patches': <Object?>[],
        'actionReturns': [
          {
            'txnId': sent['txnId'],
            'result': {'type': 'Success', 'value': null},
          },
        ],
      });
      await pumpEventQueue();

      expect(refusals, isEmpty);
      await sub.cancel();
    });

    test('an ack for a transaction from a previous socket names nothing', () async {
      // Transactions belong to a connection. Carrying them across a reconnect would
      // pair a fresh ack with a stale action name, which is worse than saying
      // nothing — it would put the wrong sentence in front of somebody.
      final (:c, :conn) = await ready();
      final refusals = <ActionRefused>[];
      final sub = c.refusals.listen(refusals.add);

      conn.send({
        'type': 'DeltaState',
        'patches': <Object?>[],
        'actionReturns': [
          {
            'txnId': 'a-transaction-from-nowhere',
            'result': {'type': 'Error', 'error': 'no'},
          },
        ],
      });
      await pumpEventQueue();

      expect(refusals.single.action, 'that');
      expect(refusals.single.message, 'no');
      await sub.cancel();
    });
  });

  group('saying whether anyone is there', () {
    test('the heartbeat carries the desktop client\'s own shape', () async {
      // Both fields read backwards, and both were measured off two live clients
      // rather than reasoned about: the frame the client *sends* says
      // `origin: "Server"`, and its `sequenceNumber` echoes the highest the server
      // has sent rather than counting our own.
      final c = build()..start();
      final conn = await firstWhere(gather.onDumped, (_) => true, reason: 'a dump');
      await firstWhere(c.rosters, (r) => r.selfId != null, reason: 'selfId');

      c.sendHeartbeatNow();
      await pumpEventQueue();

      final beat = conn.received.lastWhere((f) => f['type'] == 'Heartbeat');
      expect(beat['origin'], 'Server');
      expect(beat['sequenceNumber'], c.reader.lastSequence);
      expect(beat['timestamp'], isA<int>());
    });

    test('reportActivity addresses Connection with a null id, not our avatar', () async {
      // The one action here that is not about `SpaceUser`. Sending it against our
      // own row would be a schema failure, which executes nothing and says nothing.
      final c = build()..start();
      final conn = await firstWhere(gather.onDumped, (_) => true, reason: 'a dump');
      await firstWhere(c.rosters, (r) => r.selfId != null, reason: 'selfId');
      await pumpEventQueue();

      expect(c.setActive(false).ok, isTrue);
      await pumpEventQueue();

      final sent = conn.received.lastWhere((f) => f['action'] == 'reportActivity');
      expect(sent['args'], [
        'Connection',
        null,
        {'isActive': false},
      ]);
    });

    test('going quiet needs no avatar, only a socket', () async {
      // Deliberately different from every other action: `reportActivity` is about
      // the connection, so it must work in the window before the dump has named us.
      final c = build();
      expect(c.setActive(false).ok, isFalse, reason: 'no socket at all');
      expect(c.setActive(false).detail, contains('not connected'));
    });
  });

  group('close codes', () {
    // 387 lines of `direct: game socket error` over six days on the bridge, all of
    // them one of the first two cases, neither of them a fault. The code was
    // captured into health detail and never reached the log.
    test('a close code is described in words, so a log of them means something', () {
      expect(describeClose(1012), contains('Gather recycled the connection (1012)'));
      expect(describeClose(1006), contains('dropped without a close frame (1006)'));
      expect(describeClose(4031), contains('duplicate connection rejected'));
      expect(describeClose(1000), contains('closed the connection normally'));
      expect(describeClose(4999), contains('the game socket closed (4999)'));
      expect(describeClose(1006, 'bye'), contains('(1006) — "bye"'));
      expect(describeClose(1006, ''), isNot(contains('—')));
    });
  });
}
