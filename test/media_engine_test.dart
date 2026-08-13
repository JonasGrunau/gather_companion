/// The media seam, and the states a screen has to be able to tell apart.
///
/// There is no camera in a test runner, so what is under test here is the
/// *contract* — that `LocalMediaState` can distinguish muted from stopped, that a
/// denied permission is distinguishable from a broken one, and that the seam
/// holds without `flutter_webrtc` being imported. The real engine is exercised on
/// a device; see `docs/` and the manual checklist.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/media/media_engine.dart';

import 'fake_media_engine.dart';

void main() {
  group('a failure says whether Settings is the fix', () {
    test('a denied permission points at Settings', () {
      const failure = MediaFailure(MediaFailureKind.permissionDenied, 'nope');
      expect(failure.needsSettings, isTrue);
    });

    test('a busy or missing device does not', () {
      // Sending someone to Settings when the camera is merely in use by another
      // app sends them somewhere that cannot help.
      const failure = MediaFailure(MediaFailureKind.noDevice, 'busy');
      expect(failure.needsSettings, isFalse);
      expect(const MediaFailure(MediaFailureKind.unknown, '?').needsSettings, isFalse);
    });
  });

  group('local state', () {
    test('muted is not the same as stopped', () {
      // A muted mic still holds the capture session, which is why unmuting is
      // instant. A screen that conflates the two offers the wrong button.
      final engine = FakeMediaEngine();
      addTearDown(engine.dispose);

      return engine.startCapture().then((_) async {
        expect(engine.state.capturing, isTrue);
        await engine.setAudioEnabled(false);

        expect(engine.state.audioEnabled, isFalse);
        expect(engine.state.capturing, isTrue, reason: 'still holding the mic');
        expect(engine.state.audioTrackId, isNotNull);
      });
    });

    test('hasVideo is false while the camera is off but still held', () async {
      final engine = FakeMediaEngine();
      addTearDown(engine.dispose);
      await engine.startCapture();
      expect(engine.state.hasVideo, isTrue);

      await engine.setVideoEnabled(false);
      expect(engine.state.hasVideo, isFalse);
      expect(engine.state.capturing, isTrue);
    });

    test('capture can succeed with no camera at all', () async {
      // A device with no usable camera still returns a stream — just without a
      // video track. Assuming we got what we asked for is how a null lands in the
      // renderer.
      final engine = FakeMediaEngine()..hasCamera = false;
      addTearDown(engine.dispose);

      await engine.startCapture();
      expect(engine.state.capturing, isTrue);
      expect(engine.state.audioEnabled, isTrue);
      expect(engine.state.hasVideo, isFalse);
      expect(engine.state.videoTrackId, isNull);
    });

    test('stopping clears the tracks rather than leaving stale ids', () async {
      final engine = FakeMediaEngine();
      addTearDown(engine.dispose);
      await engine.startCapture();
      await engine.stopCapture();

      expect(engine.state.capturing, isFalse);
      expect(engine.state.videoTrackId, isNull);
      expect(engine.state.audioTrackId, isNull);
      expect(engine.state.hasVideo, isFalse);
    });
  });

  test('a failed capture surfaces as state, not just a throw', () async {
    // Both matter: the throw is for the caller that asked, the state is for the
    // screen that has to render something afterwards.
    final engine = FakeMediaEngine(
      failWith: const MediaFailure(MediaFailureKind.permissionDenied, 'denied'),
    );
    addTearDown(engine.dispose);

    await expectLater(engine.startCapture(), throwsA(isA<MediaFailure>()));
    expect(engine.state.capturing, isFalse);
    expect(engine.state.failure?.needsSettings, isTrue);
  });

  test('states are published, so a screen can listen instead of polling', () async {
    final engine = FakeMediaEngine();
    addTearDown(engine.dispose);

    final seen = <bool>[];
    final sub = engine.states.listen((s) => seen.add(s.capturing));
    addTearDown(sub.cancel);

    await engine.startCapture();
    await engine.stopCapture();
    await Future<void>.delayed(Duration.zero);

    expect(seen, containsAllInOrder([true, false]));
  });
}
