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
    ));
  }

  @override
  Future<void> stopCapture() async {
    calls.add('stopCapture');
    _emit(const LocalMediaState());
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
