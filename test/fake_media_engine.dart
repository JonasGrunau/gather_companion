/// A [MediaEngine] with no hardware behind it.
///
/// The point of the seam: call logic gets tested on a machine with no camera,
/// no microphone and no permission dialog. If this file ever needs to import
/// `flutter_webrtc` to compile, the seam has leaked and the leak should be fixed
/// rather than followed.
library;

import 'dart:async';

import 'package:gather_companion/src/media/media_engine.dart';

class FakeMediaEngine implements MediaEngine {
  FakeMediaEngine({this.failWith});

  /// When set, [startCapture] throws this instead of succeeding — which is how a
  /// denied permission is exercised without a device that can deny anything.
  MediaFailure? failWith;

  /// Whether a camera exists at all. A stream with no video track is a real
  /// shape: capture succeeds, but there is nothing to draw.
  bool hasCamera = true;

  final List<String> calls = [];

  final _states = StreamController<LocalMediaState>.broadcast();
  LocalMediaState _state = const LocalMediaState();

  @override
  Stream<LocalMediaState> get states => _states.stream;

  @override
  LocalMediaState get state => _state;

  @override
  Future<void> startCapture({bool audio = true, bool video = true}) async {
    calls.add('startCapture(audio: $audio, video: $video)');
    final failure = failWith;
    if (failure != null) {
      _emit(_state.copyWith(capturing: false, failure: failure, clearTracks: true));
      throw failure;
    }
    final withVideo = video && hasCamera;
    _emit(LocalMediaState(
      capturing: true,
      audioEnabled: audio,
      videoEnabled: withVideo,
      videoTrackId: withVideo ? 'fake-video' : null,
      audioTrackId: audio ? 'fake-audio' : null,
      // A share in progress rides through the capture (re)start, as the real
      // engine carries it over.
      screenCapturing: _state.screenCapturing,
      screenTrackId: _state.screenTrackId,
    ));
  }

  @override
  Future<void> stopCapture() async {
    calls.add('stopCapture');
    // Screen is a separate capture and survives a camera/mic stop — including the
    // restart that adds the camera mid-call — exactly as the real engine carries
    // it over.
    _emit(LocalMediaState(
      screenCapturing: _state.screenCapturing,
      screenTrackId: _state.screenTrackId,
    ));
  }

  @override
  Future<void> setAudioEnabled(bool enabled) async {
    calls.add('setAudioEnabled($enabled)');
    if (_state.audioTrackId == null) return;
    _emit(_state.copyWith(audioEnabled: enabled));
  }

  @override
  Future<void> setVideoEnabled(bool enabled) async {
    calls.add('setVideoEnabled($enabled)');
    if (_state.videoTrackId == null) return;
    _emit(_state.copyWith(videoEnabled: enabled));
  }

  @override
  Future<void> switchCamera() async {
    calls.add('switchCamera');
    if (_state.videoTrackId == null) return;
    _emit(_state.copyWith(frontCamera: !_state.frontCamera));
  }

  /// When set, [startScreenCapture] throws this instead of succeeding — the
  /// declined-picker path, exercised without a picker.
  MediaFailure? failScreenWith;

  @override
  Future<void> startScreenCapture() async {
    calls.add('startScreenCapture');
    final failure = failScreenWith;
    if (failure != null) {
      _emit(_state.copyWith(clearScreen: true, failure: failure));
      throw failure;
    }
    _emit(_state.copyWith(
      screenCapturing: true,
      screenTrackId: 'fake-screen',
      clearFailure: true,
    ));
  }

  @override
  Future<void> stopScreenCapture() async {
    calls.add('stopScreenCapture');
    _emit(_state.copyWith(clearScreen: true));
  }

  /// Mimics the OS "Stop" control ending the broadcast from outside the app: the
  /// capture vanishes with no `stopScreenCapture` call, which is the signal
  /// [LiveCall] watches for.
  void endScreenFromOs() {
    _emit(_state.copyWith(clearScreen: true));
  }

  /// What headset, if any, is plugged in — null for none. Lets a test drive the
  /// auto-select path with no device-change callback anywhere near it.
  AudioOutput? headset;

  bool? _speakerOverride;

  @override
  Future<void> prepareAudioSession() async {
    calls.add('prepareAudioSession');
    _applyRoute();
  }

  @override
  Future<void> setSpeakerOn(bool on) async {
    calls.add('setSpeakerOn($on)');
    _speakerOverride = on;
    _applyRoute();
  }

  @override
  Future<void> releaseAudioSession() async {
    calls.add('releaseAudioSession');
    _speakerOverride = null;
  }

  /// Mimics a headset connecting or disconnecting: clears any forced route and
  /// re-routes, exactly as the real engine's device-change listener does.
  void connectHeadset(AudioOutput? which) {
    headset = which;
    _speakerOverride = null;
    _applyRoute();
  }

  void _applyRoute() {
    final speaker = _speakerOverride ?? (headset == null);
    _emit(_state.copyWith(
      audioOutput:
          speaker ? AudioOutput.speaker : (headset ?? AudioOutput.earpiece),
    ));
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    await _states.close();
  }

  void _emit(LocalMediaState next) {
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }
}
