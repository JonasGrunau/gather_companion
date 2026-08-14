/// [SfuSession] — the conversation with Gather's media plane.
///
/// `packages/gather_client` tests the *transport* against a real socket; this
/// tests what is said over it and in what order, which is where the
/// reverse-engineered risk actually lives. Both halves it depends on are faked:
/// the signalling ([FakeSignalling]) and mediasoup ([FakeDevice]), the latter
/// because `Device.load()` wants a platform channel this runner does not have.
///
/// The cases worth having are the ones a device cannot be made to perform on
/// cue: a router that has not placed somebody yet, a socket that drops and comes
/// back holding nothing, and a node being drained underneath a live call.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/src/media/call.dart';
import 'package:gather_companion/src/media/sfu_session.dart';

import 'fake_mediasoup.dart';
import 'sfu_rig.dart';

void main() {
  late Rig rig;

  setUp(() => rig = Rig());
  tearDown(() => rig.close());

  /// Let every pending microtask and zero-length timer run.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('assignment', () {
    test('asks the router for our UserAccount id and connects what it names',
        () async {
      await rig.session.start();

      expect(rig.router.argsFor('get-addr'),
          {'srcId': me, 'srcStreamId': spaceId});
      expect(rig.session.sfuAddr, nodeA);
      expect(rig.sockets.containsKey(nodeA), isTrue,
          reason: 'the node the router named should be connected');
      expect(rig.device.loaded, isTrue);
      expect(rig.session.ready, isTrue);
    });

    test('a router that has not placed us yet is asked again, not given up on',
        () async {
      // `addrFound: false` is a normal answer — measured, and documented as
      // such. Treating it as fatal is what made the first tap after opening the
      // app fail permanently.
      rig.addresses.remove(me);
      var asked = 0;
      rig.session.start().ignore();
      await settle();
      asked = rig.router.asked.length;
      expect(asked, greaterThan(0));

      rig.addresses[me] = nodeA;
      await Future<void>.delayed(const Duration(milliseconds: 700));

      expect(rig.session.sfuAddr, nodeA);
      expect(rig.router.asked.length, greaterThan(asked),
          reason: 'it should have asked a second time');
    });

    test('a router that never places us fails rather than hanging', () async {
      rig.addresses.remove(me);
      await expectLater(rig.session.start(), throwsA(isA<SfuException>()));
    });
  });

  group('the allow list', () {
    test('is replayed to a node the moment it connects', () async {
      // It lives on the node, so a list built before the socket existed means
      // nothing to it — the same replay `playerConnectedSFU` does.
      rig.session.setAllowed({them, 'acct-other'});
      await rig.session.start();

      final allows = rig.node().said.where((f) => f.method == 'consume-allow');
      expect(allows.map((f) => f.args['dstId']), containsAll([them, 'acct-other']));
      expect(allows.every((f) => f.args['allowed'] == true), isTrue);
    });

    test('is diffed rather than re-sent, and never aimed at ourselves',
        () async {
      await rig.session.start();
      rig.node().drain();

      rig.session.setAllowed({them, me});
      rig.session.setAllowed({them, 'acct-third'});

      final allows = rig.node().said.where((f) => f.method == 'consume-allow');
      expect(
        allows.map((f) => (f.args['dstId'], f.args['allowed'])),
        [(them, true), ('acct-third', true)],
        reason: 'ourselves is not a peer, and an unchanged grant is not news',
      );
      expect(rig.session.allowed, {them, 'acct-third'});
    });

    test('grants before asking, because consuming is reciprocal', () async {
      await rig.session.start();
      rig.node().drain();

      await rig.session.subscribe(them);

      final order = rig.node().sent.map((f) => f.method).toList();
      expect(order.indexOf('consume-allow'), lessThan(order.indexOf('consume-request')));
      expect(rig.node().argsFor('consume-request'),
          {'srcId': them, 'srcStreamId': spaceId, 'requested': true});
    });
  });

  group('receiving', () {
    test('a peer the router cannot place is kept, and asked for again', () {
      // The bug this pins: dropping them from the subscribed set meant
      // `setSubscriptions` — which diffs against that set — never retried, so a
      // colleague whose client was still connecting stayed silent forever.
      fakeAsync((clock) {
        rig.addresses.remove(them);
        rig.session.start().ignore();
        clock.flushMicrotasks();

        rig.session.subscribe(them).ignore();
        clock.flushMicrotasks();
        expect(rig.node().has('consume-request'), isFalse);

        rig.addresses[them] = nodeA;
        clock.elapse(const Duration(seconds: 11));
        clock.flushMicrotasks();

        expect(rig.node().has('consume-request'), isTrue);
        rig.close().ignore();
        clock.elapse(const Duration(seconds: 1));
      });
    });

    test('consume-try builds a consumer, and an empty map takes it away',
        () async {
      await rig.session.start();
      await rig.session.subscribe(them);

      rig.announce(them, {'audio': 'p-audio'});
      await settle();

      expect(rig.session.remotes, hasLength(1));
      expect(rig.session.remotes.single.srcId, them);
      expect(rig.session.remotes.single.streams.keys, [SfuTag.audio]);
      // The SFU wants telling that the consumer was actually built, which is
      // unusual enough to be worth pinning.
      expect(rig.node().has('consume-created'), isTrue);
      expect(rig.node().has('consume-resume'), isTrue);

      // Full state, not a delta: an empty map means they publish nothing.
      rig.announce(them, {});
      await settle();
      expect(rig.session.remotes, isEmpty);
    });

    test('a producer id that changed under us is a new stream', () async {
      await rig.session.start();
      await rig.session.subscribe(them);

      rig.announce(them, {'video': 'p-1'});
      await settle();
      final first = rig.device.transports
          .expand((t) => t.consumers)
          .singleWhere((c) => c.producerId == 'p-1');

      // They turned the camera off and on again. The old consumer points at a
      // producer that no longer exists.
      rig.announce(them, {'video': 'p-2'});
      await settle();

      expect(first.closed, isTrue);
      expect(rig.session.remotes.single.streams.keys, [SfuTag.video]);
    });

    test('unsubscribing tells the node, the router, and takes the grant back',
        () async {
      await rig.session.start();
      await rig.session.subscribe(them);
      rig.node().drain();
      rig.router.drain();

      await rig.session.unsubscribe(them);

      expect(rig.node().argsFor('consume-request'),
          {'srcId': them, 'srcStreamId': spaceId, 'requested': false});
      expect(rig.router.argsFor('unsubscribe'),
          {'srcId': them, 'srcStreamId': spaceId});
      expect(rig.node().sent.any((f) =>
          f.method == 'consume-allow' && f.args['allowed'] == false), isTrue);
    });
  });

  group('recovery', () {
    test('a socket that comes back is a fresh session, and is rebuilt as one',
        () async {
      await rig.session.start();
      rig.session.setAllowed({them});
      await rig.session.subscribe(them);
      await rig.session.publish(FakeTrack('audio'), FakeStream(), tag: SfuTag.audio);
      rig.node().drain();

      rig.node().drop();
      rig.node().comeBack();
      await settle();
      await settle();

      final sent = rig.node().sent;
      expect(sent.any((f) => f.method == 'consume-allow' && f.args['allowed'] == true),
          isTrue, reason: 'the allow list lives on the node and died with it');
      expect(sent.any((f) => f.method == 'consume-request'), isTrue,
          reason: 'the server has forgotten we wanted them');
      expect(rig.republishes, 1,
          reason: 'the producers went with the socket, and only the caller '
              'holds the tracks to put them back');
    });

    test('a drained node is left for the one the router names next', () async {
      await rig.session.start();
      await rig.session.subscribe(them);
      final old = rig.node();

      // `cordon-sfu` is *router* vocabulary. Nothing was listening to the router
      // before, so this notice could never arrive — which made every other part
      // of draining dead code.
      rig.addresses[me] = nodeB;
      rig.addresses[them] = nodeB;
      rig.router.push('cordon-sfu', {'sfuAddr': nodeA});
      await settle();
      await settle();

      expect(rig.session.sfuAddr, nodeB);
      expect(old.disposed, isTrue);
      expect(rig.node(nodeB).has('get-rtp-capabilities'), isTrue);
      expect(rig.node(nodeB).has('consume-request'), isTrue,
          reason: 'whoever was on the old node has to be asked for again');
      expect(rig.republishes, 1);
    });
  });

  group('publishing', () {
    test('produce carries the tag Gather keys on, and keeps the producer',
        () async {
      await rig.session.start();
      await rig.session.publish(FakeTrack('audio'), FakeStream(), tag: SfuTag.audio);

      expect(rig.node().argsFor('produce')?['tag'], 'audio');
      expect(rig.session.publishing(SfuTag.audio), isTrue);

      // Mute is a pause, not a close: the producer stays so unmuting is not a
      // fresh negotiation, and `produce-pause` carries only a tag.
      rig.session.pause(SfuTag.audio);
      expect(rig.node().argsFor('produce-pause'), {'tag': 'audio'});
      expect(rig.device.transports.first.producers.single.closed, isFalse);
    });

    test('three double-connected notices stand us down for good', () async {
      await rig.session.start();
      await rig.session.publish(FakeTrack('audio'), FakeStream(), tag: SfuTag.audio);
      final producer = rig.device.transports.first.producers.single;

      for (var i = 0; i < 3; i++) {
        rig.node().push('double-connected', const {});
      }
      await settle();

      expect(rig.session.displaced, isTrue);
      expect(producer.closed, isTrue);
      // Sticky, and enforced rather than merely documented: retrying restarts
      // the fight that standing down exists to end.
      await expectLater(
        rig.session.publish(FakeTrack('audio'), FakeStream(), tag: SfuTag.audio),
        throwsA(isA<SfuException>()),
      );
    });

    test('the server steering our quality is debounced, and applied once',
        () async {
      await rig.session.start();
      await rig.session.publish(FakeTrack('video'), FakeStream(), tag: SfuTag.video);
      final producer = rig.device.transports.first.producers.single;

      for (final layer in [0, 1, 2]) {
        rig.node().push('set-max-spatial-layer', {'kind': 'video', 'layer': layer});
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(producer.maxSpatialLayers, [2]);
    });

    test('a transport-create in an unknown shape says exactly that', () async {
      await rig.session.start();
      rig.node().answer('transport-create', (_) => const {});

      // The one thing in the session no capture has ever confirmed. If it is
      // ever wrong, the error has to name it rather than surface as a cast
      // failure inside a callback.
      await expectLater(
        rig.session.publish(FakeTrack('audio'), FakeStream(), tag: SfuTag.audio),
        throwsA(isA<SfuException>().having(
          (e) => e.message, 'message', contains('transport-create'))),
      );
    });

    test('TURN rotation puts the servers in before restarting ICE', () async {
      await rig.session.start();
      await rig.session.publish(FakeTrack('audio'), FakeStream(), tag: SfuTag.audio);

      await rig.session.refreshTurn();

      final transport = rig.device.transports.first;
      expect(transport.lastIceServers, isNotEmpty);
      expect(transport.iceRestarts, 1);
    });
  });

  group('quality and metadata', () {
    test('watching a face asks for the layer, and ranks who matters', () async {
      await rig.session.start();
      await rig.session.subscribe(them);
      rig.node().drain();

      rig.session.setWatching([them], layer: VideoQuality.full.spatialLayer);

      expect(rig.node().argsFor('consume-set-spatial'), {
        'srcId': them,
        'srcStreamId': spaceId,
        'tag': 'video',
        'spatialLayer': 2,
      });
      expect(rig.node().argsFor('consume-set-priority'), {
        'srcStreamId': spaceId,
        'tag': 'video',
        'srcIds': [them],
      });
    });

    test('closing the screen puts everybody back to the smallest layer',
        () async {
      await rig.session.start();
      await rig.session.subscribe(them);
      rig.session.setWatching([them], layer: 2);
      rig.node().drain();

      rig.session.setWatching(const [], layer: 0);

      expect(rig.node().argsFor('consume-set-spatial')?['spatialLayer'], 0);
    });

    test('the conversation is named, nulls included', () async {
      await rig.session.start();
      rig.node().drain();

      rig.session.setConversation(clusterId: 'bubble-1');
      await settle();
      expect(rig.node().argsFor('set-player-conversation-metadata'),
          {'meetingId': null, 'clusterId': 'bubble-1'});

      rig.node().drain();
      rig.session.setConversation(clusterId: null);
      await settle();
      expect(rig.node().argsFor('set-player-conversation-metadata'),
          {'meetingId': null, 'clusterId': null});
    });
  });
}
