/// [Call], actually connected: the capture session, the SFU, and the order the
/// two have to happen in.
///
/// ## Capture is exactly what was asked for, and restarting is the price
///
/// [MediaEngine.startCapture] takes the tracks it wants once and returns early if
/// a session is already open, so a microphone-only capture cannot grow a camera
/// later. The obvious workaround — always capture both and leave the video track
/// disabled — is the one thing this must not do: `track.enabled = false` stops
/// the frames while the capture session keeps running, so iOS keeps the camera
/// indicator lit and the phone claims to be watching the room when it is not.
/// `webrtc_media_engine.dart` makes the same argument about the microphone.
///
/// So the session is opened with precisely the tracks in use, and turning the
/// camera on for the first time *restarts* it. That costs a moment of audio and
/// a republish, and it happens at most once per call, which is a better trade
/// than a camera light nobody asked for.
///
/// ## The SFU is connected on the first publish, not at join
///
/// Steps 1–4 of `SfuSession` (assignment, connection, capabilities) are being
/// *ready* to publish rather than publishing, and the desktop client does them at
/// space join. This does them on the first tap instead: a companion app is open
/// on a phone in someone's pocket far more often than it is used to talk, and a
/// router assignment held all day for a call that never happens is a socket and a
/// battery spent on nothing.
library;

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:gather_client/gather_client.dart';

import 'call.dart';
import 'media_engine.dart';
import 'sfu_session.dart';
import 'webrtc_media_engine.dart';

class LiveCall implements Call {
  LiveCall({
    required GatherAuth auth,
    required String spaceId,
    required String srcId,
    WebrtcMediaEngine? engine,
    SfuSession Function()? buildSfu,
    void Function(String)? log,
  })  : _log = log ?? _noop,
        _engine = engine ?? WebrtcMediaEngine(log: log),
        _buildSfu = buildSfu ??
            (() => SfuSession(
                  auth: auth,
                  spaceId: spaceId,
                  srcId: srcId,
                  log: log,
                )) {
    _engineSub = _engine.states.listen((media) {
      _emit(_state.copyWith(media: media));
    });
  }

  static void _noop(String _) {}

  final void Function(String) _log;
  final WebrtcMediaEngine _engine;
  final SfuSession Function() _buildSfu;

  StreamSubscription<LocalMediaState>? _engineSub;
  SfuSession? _sfu;

  final _states = StreamController<CallState>.broadcast();
  CallState _state = const CallState();

  /// What the person has asked for, which is not the same as what is running.
  /// A tap that fails must not leave the button showing the state it failed to
  /// reach, and these are what the retry on the next tap is judged against.
  bool _wantMic = false;
  bool _wantCamera = false;

  /// Serialises the whole thing. Two taps in quick succession would otherwise
  /// interleave a capture restart with a publish and produce on a dead track.
  Future<void> _work = Future.value();

  @override
  Stream<CallState> get states => _states.stream;

  @override
  CallState get state => _state;

  /// The live capture, for the widget that draws the preview. Concrete on
  /// purpose — a `MediaStream` cannot cross [Call] without dragging the plugin
  /// with it.
  MediaStream? get localStream => _engine.localStream;

  @override
  Future<String?> setMicOn(bool on) => _serialise(() async {
        _wantMic = on;
        if (!on) {
          // Device first, so the indicator goes out at the moment of the tap
          // rather than after a round trip to the SFU.
          await _engine.setAudioEnabled(false);
          _sfu?.pause(SfuTag.audio);
          _emit(_state.copyWith(publishingAudio: false, clearDetail: true));
          return null;
        }

        await _ensureCapture();
        await _engine.setAudioEnabled(true);
        return _publish(SfuTag.audio);
      });

  @override
  Future<String?> setCameraOn(bool on) => _serialise(() async {
        _wantCamera = on;
        if (!on) {
          await _engine.setVideoEnabled(false);
          _sfu?.pause(SfuTag.video);
          _emit(_state.copyWith(publishingVideo: false, clearDetail: true));
          return null;
        }

        await _ensureCapture();
        await _engine.setVideoEnabled(true);
        return _publish(SfuTag.video);
      });

  @override
  Future<void> switchCamera() => _engine.switchCamera();

  /// Opens a capture session holding exactly the tracks in use, restarting it if
  /// the set has grown.
  ///
  /// Only *growing* forces a restart. Turning the camera off leaves its track
  /// captured and disabled, because the alternative — tearing the session down to
  /// drop one track — would cut the audio mid-sentence every time somebody turns
  /// their camera off.
  Future<void> _ensureCapture() async {
    final media = _engine.state;
    final needsVideo = _wantCamera && media.videoTrackId == null;

    if (media.capturing && !needsVideo) return;

    if (media.capturing && needsVideo) {
      _log('call: restarting capture to add the camera');
      // The producers are about to be pointing at tracks that no longer exist.
      await _sfu?.unpublish(SfuTag.audio);
      await _sfu?.unpublish(SfuTag.video);
      _emit(_state.copyWith(publishingAudio: false, publishingVideo: false));
      await _engine.stopCapture();
    }

    // Audio unconditionally: a capture session with no microphone in it would
    // have to be torn down again the moment the mic is unmuted, and the mic is
    // the one people reach for.
    await _engine.startCapture(audio: true, video: _wantCamera);

    // `startCapture` opens every track it was given. Anything not asked for is
    // put back down immediately rather than left running.
    if (!_wantMic) await _engine.setAudioEnabled(false);
    if (!_wantCamera) await _engine.setVideoEnabled(false);
  }

  /// Puts one track on the wire, connecting to the SFU if this is the first.
  Future<String?> _publish(SfuTag tag) async {
    final stream = _engine.localStream;
    final track = switch (tag) {
      SfuTag.audio => stream?.getAudioTracks().firstOrNull,
      SfuTag.video || SfuTag.screen => stream?.getVideoTracks().firstOrNull,
    };
    if (stream == null || track == null) {
      return _fail(tag, 'The ${tag == SfuTag.audio ? 'microphone' : 'camera'} '
          'did not open.');
    }

    try {
      final sfu = await _sfuOrStart();
      if (sfu.publishing(tag)) {
        sfu.resume(tag);
      } else {
        await sfu.publish(track, stream, tag: tag);
      }
    } on Object catch (error) {
      _log('call: publishing ${tag.wire} failed: $error');
      // The hardware is live and only the wire failed, so the button stays on:
      // the person is unmuted, and the sentence says the room cannot hear them
      // yet. Silently flipping it back would read as the tap not registering.
      return _fail(tag, 'You are unmuted, but Gather has not picked up the '
          '${tag == SfuTag.audio ? 'audio' : 'video'} yet.');
    }

    _emit(_state.copyWith(
      publishingAudio: tag == SfuTag.audio ? true : null,
      publishingVideo: tag == SfuTag.video ? true : null,
      clearDetail: true,
    ));
    return null;
  }

  Future<SfuSession> _sfuOrStart() async {
    final existing = _sfu;
    if (existing != null && existing.ready) return existing;
    if (existing != null) {
      // Started once and did not finish — a half-open session is worse than none.
      await existing.stop();
    }
    final sfu = _sfu = _buildSfu();
    await sfu.start();
    return sfu;
  }

  String _fail(SfuTag tag, String sentence) {
    _emit(_state.copyWith(detail: sentence));
    return sentence;
  }

  @override
  Future<void> hangUp() async {
    _wantMic = false;
    _wantCamera = false;
    await _sfu?.stop();
    _sfu = null;
    await _engine.stopCapture();
    _emit(const CallState());
  }

  @override
  Future<void> dispose() async {
    await _engineSub?.cancel();
    _engineSub = null;
    await _sfu?.stop();
    _sfu = null;
    await _engine.dispose();
    if (!_states.isClosed) await _states.close();
  }

  /// Runs [job] after everything already queued, and never lets one failure
  /// poison the queue for the next tap.
  Future<String?> _serialise(Future<String?> Function() job) {
    final next = _work.then((_) => job()).catchError((Object error) {
      _log('call: $error');
      return _fail(SfuTag.audio, 'That did not work: $error');
    });
    _work = next.then((_) {}, onError: (_) {});
    return next;
  }

  void _emit(CallState next) {
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }
}
