/// [SfuSignalling] against a real Socket.IO server.
///
/// This is where the reverse-engineered risk lives. The media plane was read off
/// a capture rather than from documentation, and Gather's signature failure mode
/// is silence — a wrong-shaped call is not rejected, it simply never answers. So
/// the assertions here are mostly about *shape*: the envelope, the exemptions,
/// and the auth payload, pinned so a future edit cannot quietly change them.
library;

import 'dart:async';

import 'package:gather_client/gather_client.dart';
import 'package:test/test.dart';

import 'fake_gather.dart' show FakeGatherHttp;
import 'fake_sfu.dart';

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
  late FakeSfuServer sfu;
  late FakeGatherHttp http;
  SfuSignalling? signalling;

  setUp(() async {
    sfu = await FakeSfuServer.start();
    http = FakeGatherHttp();
  });

  tearDown(() async {
    await signalling?.dispose();
    signalling = null;
    await sfu.close();
  });

  SfuSignalling build({String spaceId = 'space-1', String? sessionId}) {
    final auth = GatherAuth(
      credentials: const GatherCredentials(refreshToken: 'refresh-1'),
      http: http,
    );
    return signalling = SfuSignalling(
      auth: auth,
      url: sfu.url,
      spaceId: spaceId,
      sessionId: sessionId,
    );
  }

  /// Connects and hands back the server's view of that connection.
  ///
  /// Waits for *both* ends. The server seeing CONNECT is not enough: its reply
  /// still has to travel back before the client will send anything, and a test
  /// that raced that would fail intermittently rather than honestly.
  Future<FakeSfuConnection> connected(SfuSignalling s) async {
    final serverSaw = firstWhere(sfu.onConnected, (_) => true, reason: 'a CONNECT');
    final clientReady =
        firstWhere(s.statuses, (st) => st.healthy, reason: 'a healthy status');
    await s.start();
    final conn = await serverSaw;
    await clientReady;
    return conn;
  }

  group('the handshake', () {
    test('authenticates in the CONNECT packet, not a header or a query', () async {
      final conn = await connected(build());

      // The finding this whole file rests on: the credential rides in the
      // Socket.IO CONNECT payload.
      expect(conn.auth, isNotNull);
      expect(conn.auth!['spaceId'], 'space-1');
      expect(conn.auth!['token'], isA<String>());
      expect((conn.auth!['token'] as String).isNotEmpty, isTrue);
    });

    test('carries a sessionId in the url query', () async {
      await connected(build(sessionId: 'session-abc'));
      expect(sfu.connections.single.uri.queryParameters['sessionId'], 'session-abc');
    });

    test('mints its own sessionId when not given one', () async {
      // It is a client-generated nonce: it appears in no inbound frame, and two
      // captured connections produced two unrelated UUIDs.
      await connected(build());
      final minted = sfu.connections.single.uri.queryParameters['sessionId'];
      expect(minted, isNotNull);
      expect(minted, matches(RegExp(r'^[0-9a-f-]{36}$')));
    });

    test('reports healthy only once connected', () async {
      final s = build();
      expect(s.connected, isFalse);
      // `connected` itself waits for the healthy status, so reaching here is the
      // assertion; waiting again would block on an event already consumed.
      await connected(s);
      expect(s.connected, isTrue);
    });
  });

  group('the envelope', () {
    test('wraps a normal call and numbers it', () async {
      final s = build();
      final conn = await connected(s);

      s.sendWithResponse('produce', {'tag': 'audio'}).ignore();
      await conn.waitForFrames(1);

      final sent = conn.received.single;
      expect(sent.name, 'produce');
      expect(sent.data, {
        'wsSequenceNumber': 1,
        'zodData': {'tag': 'audio'},
      });
    });

    test('the sequence number increments per call', () async {
      final s = build();
      final conn = await connected(s);

      s.sendWithResponse('produce', {'tag': 'audio'}).ignore();
      s.sendWithResponse('produce', {'tag': 'video'}).ignore();
      await conn.waitForFrames(2);

      final numbers = conn.received
          .map((f) => (f.data as Map)['wsSequenceNumber'])
          .toList();
      expect(numbers, [1, 2]);
    });

    test('get-addr and unsubscribe are sent bare', () async {
      // Measured: these went out as plain {srcId, srcStreamId} while everything
      // else on the same socket was wrapped. Wrapping them is the kind of mistake
      // Gather answers with silence.
      final s = build();
      final conn = await connected(s);

      s.sendWithResponse('get-addr', {'srcId': 'a', 'srcStreamId': 'b'}).ignore();
      s.emit('unsubscribe', {'srcId': 'a', 'srcStreamId': 'b'});
      await conn.waitForFrames(2);

      for (final frame in conn.received) {
        expect(
          frame.data,
          {'srcId': 'a', 'srcStreamId': 'b'},
          reason: '${frame.name} must not be wrapped',
        );
      }
    });

    test('a bare call does not consume a sequence number', () async {
      final s = build();
      final conn = await connected(s);

      s.sendWithResponse('get-addr', {'srcId': 'a'}).ignore();
      s.sendWithResponse('produce', {'tag': 'audio'}).ignore();
      await conn.waitForFrames(2);

      final produce = conn.received.firstWhere((f) => f.name == 'produce');
      expect((produce.data as Map)['wsSequenceNumber'], 1);
    });
  });

  group('request and response', () {
    test('an ack answers the call that asked for it', () async {
      final s = build();
      final conn = await connected(s);

      final pending = s.sendWithResponse('consume', {'tag': 'audio'});
      await conn.waitForFrames(1);
      conn.ack(conn.received.single.ackId!, {'id': 'consumer-1', 'producerPaused': true});

      expect(await pending, {'id': 'consumer-1', 'producerPaused': true});
    });

    test('interleaved replies go to the right callers', () async {
      // The whole point of the ack id. Answered out of order on purpose.
      final s = build();
      final conn = await connected(s);

      final first = s.sendWithResponse('consume', {'tag': 'audio'});
      final second = s.sendWithResponse('consume', {'tag': 'video'});
      await conn.waitForFrames(2);

      conn.ack(conn.received[1].ackId!, {'id': 'video-consumer'});
      conn.ack(conn.received[0].ackId!, {'id': 'audio-consumer'});

      expect((await first)['id'], 'audio-consumer');
      expect((await second)['id'], 'video-consumer');
    });

    test('an empty ack is success, not failure', () async {
      // consume-resume and friends answer `[]`.
      final s = build();
      final conn = await connected(s);

      final pending = s.sendWithResponse('consume-resume', {'tag': 'audio'});
      await conn.waitForFrames(1);
      conn.send('43${conn.received.single.ackId}[]');

      expect(await pending, isEmpty);
    });

    test('a call that is never answered fails instead of hanging', () async {
      // Gather goes silent rather than erroring, so a caller that cannot tell
      // "no" from "nothing" would hold a call open forever.
      final s = build();
      await connected(s);

      await expectLater(
        s.sendWithResponse('consume', const {}, const Duration(milliseconds: 200)),
        throwsA(isA<SfuException>()),
      );
    });

    test('calling before connecting refuses rather than queueing', () async {
      final s = build();
      await expectLater(
        s.sendWithResponse('produce', const {}),
        throwsA(isA<SfuException>()),
      );
    });
  });

  group('notifications', () {
    test('consume-try arrives with the whole producer map', () async {
      // It is a full-state announcement, not a delta: callers reconcile against
      // it rather than treating it as an event.
      final s = build();
      final conn = await connected(s);

      final waiting = firstWhere(
        s.notifications,
        (n) => n.name == 'consume-try',
        reason: 'consume-try',
      );
      conn.push('consume-try', {
        'srcId': 'them',
        'srcStreamId': 'space-1',
        'producerIdMap': {'audio': 'p1', 'video': 'p2'},
      });

      final note = await waiting;
      expect(note.data['srcId'], 'them');
      expect(note.data['producerIdMap'], {'audio': 'p1', 'video': 'p2'});
    });

    test('an unwrapped array payload is unwrapped', () async {
      final s = build();
      final conn = await connected(s);

      final waiting =
          firstWhere(s.notifications, (n) => n.name == 'producer-paused');
      conn.push('producer-paused', [
        {'srcId': 'them', 'tag': 'audio'},
      ]);

      expect((await waiting).data['tag'], 'audio');
    });

    test('an unrecognised event still surfaces rather than vanishing', () async {
      // A protocol change should show up, not quietly stop working.
      final s = build();
      final conn = await connected(s);

      final waiting = firstWhere(s.notifications, (n) => n.name == 'something-new');
      conn.push('something-new', {'x': 1});
      expect((await waiting).name, 'something-new');
    });
  });

  test('a refused credential is reported, not retried into silence', () async {
    sfu.refuseWith = 'bad token';
    final s = build();
    final unhealthy = firstWhere(
      s.statuses,
      (st) => !st.healthy && (st.detail ?? '').contains('refused'),
      reason: 'a refusal',
    );
    await s.start();
    expect((await unhealthy).healthy, isFalse);
  });
}
