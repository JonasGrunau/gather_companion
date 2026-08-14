/// [LiveCall] — the two buttons, and the order everything has to happen in.
///
/// Driven end to end: a real [SfuSession] over the shared [Rig], with only the
/// hardware and mediasoup faked. So these assert on what actually reached the
/// wire rather than on a mock being called, which is the difference between
/// testing the code and testing the test.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/src/media/live_call.dart';
import 'package:gather_companion/src/media/sfu_session.dart';

import 'fake_capture_engine.dart';
import 'sfu_rig.dart';

void main() {
  late Rig rig;
  late FakeCaptureEngine engine;
  late LiveCall call;

  setUp(() {
    rig = Rig();
    engine = FakeCaptureEngine();
    call = LiveCall(
      auth: GatherAuth(
        credentials: const GatherCredentials(refreshToken: 'unused'),
      ),
      spaceId: spaceId,
      srcId: me,
      engine: engine,
      buildSfu: () => rig.session,
    );
  });

  tearDown(() async {
    await call.dispose();
    await rig.close();
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('the microphone', () {
    test('opens capture with only the tracks in use, and publishes it',
        () async {
      expect(await call.setMicOn(true), isNull);

      expect(engine.calls, contains('startCapture(audio: true, video: false)'));
      expect(rig.node().argsFor('produce')?['tag'], 'audio');
      expect(call.state.publishingAudio, isTrue);
      expect(call.state.micOn, isTrue);
    });

    test('muting stops the device and pauses the stream, keeping the producer',
        () async {
      await call.setMicOn(true);
      rig.node().drain();

      await call.setMicOn(false);

      // Both halves, and neither is redundant: the device mute is what makes iOS
      // drop the orange indicator, the pause is what draws the crossed-out
      // microphone next to your name on everybody else's screen.
      expect(engine.calls, contains('setAudioEnabled(false)'));
      expect(rig.node().argsFor('produce-pause'), {'tag': 'audio'});
      expect(rig.session.publishing(SfuTag.audio), isTrue,
          reason: 'closing it would make unmuting a fresh negotiation');
    });
  });

  group('the camera', () {
    test('turning it on later restarts capture and republishes both tracks',
        () async {
      await call.setMicOn(true);
      rig.node().drain();

      expect(await call.setCameraOn(true), isNull);

      // The capture session holds exactly the tracks in use, so growing it means
      // restarting it — the alternative, capturing video and leaving the track
      // disabled, keeps the camera light on for a camera nobody asked for.
      expect(engine.calls, containsAllInOrder(<String>[
        'startCapture(audio: true, video: false)',
        'stopCapture',
        'startCapture(audio: true, video: true)',
      ]));
      final produced = rig.node()
          .sent
          .where((f) => f.method == 'produce')
          .map((f) => f.args['tag'])
          .toList();
      expect(produced, containsAll(<String>['audio', 'video']));
      expect(call.state.publishingVideo, isTrue);
    });
  });

  group('being in a conversation', () {
    test('connects the media plane without anybody tapping anything', () async {
      // The fix this pins, and the reason it matters: the SFU socket is what
      // carries *other people's* audio. Waiting for a tap meant the phone could
      // not hear a conversation until it started talking in one.
      await call.setListeningTo({them});

      expect(rig.session.ready, isTrue);
      expect(rig.node().has('consume-request'), isTrue);
      // And it costs no hardware: no capture session, so no permission prompt
      // and no indicator, for something the person has not asked for.
      expect(engine.calls, isEmpty);
      expect(call.state.media.capturing, isFalse);
    });

    test('standing alone opens nothing at all', () async {
      await call.setListeningTo(const {});

      expect(rig.sockets, isEmpty);
    });

    test('who may see us is handed over before the first track goes out',
        () async {
      await call.setVisibleTo({them});
      await call.setMicOn(true);

      final order = rig.node().sent.map((f) => f.method).toList();
      expect(order.contains('consume-allow'), isTrue);
      expect(order.indexOf('consume-allow'), lessThan(order.indexOf('produce')),
          reason: 'publishing into an empty allow list reaches nobody');
    });

    test('the conversation id reaches the node, once it exists', () async {
      await call.setConversation('bubble-1');
      await call.setMicOn(true);
      await settle();

      expect(rig.node().argsFor('set-player-conversation-metadata'),
          {'meetingId': null, 'clusterId': 'bubble-1'});
    });
  });

  group('when the wire fails', () {
    test('a lost socket gets the same tracks put back', () async {
      await call.setMicOn(true);
      rig.node().drain();

      rig.node().drop();
      rig.node().comeBack();
      await settle();
      await settle();
      await settle();

      expect(rig.node().sent.where((f) => f.method == 'produce'), hasLength(1),
          reason: 'the producers died with the socket and only this class '
              'holds the tracks');
      expect(call.state.publishingAudio, isTrue);
    });

    test('a publish that fails leaves the button on and says why', () async {
      // Connect first, so the failure comes from the wire rather than from
      // there being no wire.
      await call.setListeningTo({them});
      rig.node().failing.add('produce');

      final detail = await call.setMicOn(true);

      // The hardware is live and only the wire failed, so flipping the button
      // back would read as the tap not registering.
      expect(detail, isNotNull);
      expect(call.state.micOn, isTrue);
      expect(call.state.publishingAudio, isFalse);
      expect(call.state.detail, contains('has not picked up'));
    });

    test('the Mac taking it back is named, with what to do about it', () async {
      await call.setMicOn(true);

      for (var i = 0; i < 3; i++) {
        rig.node().push('double-connected', const {});
      }
      await settle();
      await settle();

      expect(rig.session.displaced, isTrue);
      expect(call.state.detail, contains('Quit Gather there'));
      // Still receiving: half a call is much better than none, and the desktop
      // is carrying the microphone.
      expect(rig.session.remotes, isEmpty);
    });
  });

  test('hanging up releases the hardware and the session', () async {
    await call.setMicOn(true);

    await call.hangUp();

    expect(engine.calls, contains('stopCapture'));
    expect(rig.node().disposed, isTrue);
    expect(call.state.micOn, isFalse);
  });
}
