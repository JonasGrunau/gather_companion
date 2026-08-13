/// The one file in the app that touches WebRTC.
///
/// Everything else talks to [MediaEngine]. Keeping the plugin import in a single
/// place is what lets `AppState` and the call logic be tested on a machine with
/// no camera, and it is the same discipline `DirectCollector`'s connect-seam
/// follows for the socket.
///
/// ## What `flutter_webrtc` is left to do
///
/// Audio session management is **not** hand-configured here. Since 1.5.0 the
/// Darwin implementation runs on AVAudioEngine with Apple's platform voice
/// processing — acoustic echo cancellation, noise suppression, automatic gain —
/// and that is materially better than anything worth writing by hand. Taking it
/// over is an option the plugin offers and a decision this app has no reason to
/// make.
///
/// Mute happens at the **audio device**, not on the track, and the platform mute
/// sound is accepted rather than avoided.
///
/// `track.enabled = false` is the obvious alternative and the wrong one here. It
/// stops the frames while the capture session keeps running, which means iOS
/// keeps its orange microphone indicator lit for the whole time you are muted —
/// and somebody watching that dot will reasonably conclude they are still being
/// listened to. Being quietly wrong about whether a microphone is live is not a
/// thing this app should do.
///
/// So mute goes through `Helper.setMicrophoneMuted`, in
/// [MicrophoneMuteMode.voiceProcessing]. That mode plays the platform's
/// mute/unmute sound on every toggle. That is Apple's deliberate affordance, not
/// a defect, and it comes with the thing that makes it worth having: **muted
/// talker detection**, the system noticing when you are speaking while muted.
/// Every call app eventually grows a "you're on mute" tap on the shoulder; this
/// one gets it from the platform.
///
/// The two silent modes exist and are the trade to make if the sound ever becomes
/// the complaint: [MicrophoneMuteMode.inputMixer] is fast and silent but keeps the
/// session running, and [MicrophoneMuteMode.restartEngine] is silent and actually
/// stops capture, at the price of a slower unmute.
///
/// Because the device switch is **global rather than per-track**, the state below
/// is read back with `isMicrophoneMuted()` after every change rather than
/// assumed. Assuming would let the UI and the hardware drift apart, and the
/// direction that drift goes — showing "muted" while live — is the bad one.
///
/// **Unverified on hardware.** The justification above rests on iOS treating a
/// voice-processing mute as "not recording" and dropping the orange indicator,
/// which is the behaviour the API exists to provide. It has not been watched on a
/// real device yet. If the dot stays lit while muted, the reasoning for choosing
/// this over `track.enabled` collapses and the choice should be revisited rather
/// than kept for its own sake.
library;

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'media_engine.dart';

/// Capture constraints, tuned for a proximity call rather than a broadcast.
///
/// 640×480 at 24fps is what Gather's own client settles on for its lowest
/// simulcast layer, and on a phone in someone's hand it is indistinguishable from
/// more. `facingMode: user` because a video call is a face.
const _videoConstraints = <String, dynamic>{
  'mandatory': {
    'minWidth': '320',
    'minHeight': '240',
    'minFrameRate': '15',
  },
  'facingMode': 'user',
  'optional': [
    {'maxWidth': '640'},
    {'maxHeight': '480'},
    {'maxFrameRate': '24'},
  ],
};

class WebrtcMediaEngine implements MediaEngine {
  WebrtcMediaEngine({void Function(String)? log}) : _log = log ?? _noop;

  static void _noop(String _) {}

  final void Function(String) _log;

  final _states = StreamController<LocalMediaState>.broadcast();
  LocalMediaState _state = const LocalMediaState();

  MediaStream? _stream;

  @override
  Stream<LocalMediaState> get states => _states.stream;

  @override
  LocalMediaState get state => _state;

  /// The live capture, for the widget that draws it.
  ///
  /// Deliberately not on [MediaEngine]: a `MediaStream` crossing that interface
  /// would drag the plugin into every file that imports it, and the fake could no
  /// longer stand in. The preview widget reaches for this concrete type instead.
  MediaStream? get localStream => _stream;

  @override
  Future<void> startCapture({bool audio = true, bool video = true}) async {
    if (_stream != null) return;

    _emit(_state.copyWith(clearFailure: true));

    // Stated rather than inherited. `voiceProcessing` is the plugin's default
    // today, but a default that changes underneath us would silently swap the
    // platform mute sound and muted-talker detection for neither, and nothing
    // would fail — it would just quietly stop behaving as documented above.
    // A no-op on platforms that do not support it.
    try {
      await Helper.setMicrophoneMuteMode(MicrophoneMuteMode.voiceProcessing);
    } on Object catch (error) {
      _log('media: could not set the mute mode: $error');
    }

    final MediaStream stream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({
        'audio': audio,
        'video': video ? _videoConstraints : false,
      });
    } on Object catch (error) {
      final failure = _classify(error);
      _log('media: capture failed — ${failure.message}');
      _emit(_state.copyWith(capturing: false, failure: failure, clearTracks: true));
      throw failure;
    }

    _stream = stream;
    // Ask the tracks what we actually got rather than assuming we got what we
    // asked for: a device with no camera still returns a stream, just without a
    // video track in it.
    final videoTrack = stream.getVideoTracks().firstOrNull;
    final audioTrack = stream.getAudioTracks().firstOrNull;

    // The desktop client sets `contentHint` here — `'speech'` for the mic,
    // `'motion'` for the camera. We cannot: it is a browser API and
    // `webrtc_interface` does not surface it on `MediaStreamTrack`.
    //
    // For *these two* tracks that costs approximately nothing, because those two
    // values are already libwebrtc's defaults: audio processing on, and video
    // degrading by resolution before framerate. The hint only earns its keep when
    // you want to deviate — `'music'` to switch audio processing off, or
    // `'detail'`/`'text'` for a screen share, where dropping resolution to hold
    // framerate is what makes shared text unreadable.
    //
    // Both of those are reachable by other means when we need them: audio
    // processing through `getUserMedia` constraints (`echoCancellation`,
    // `noiseSuppression`, `autoGainControl`), and the video tradeoff through
    // `RTCRtpParameters.degradationPreference`
    // (`MAINTAIN_FRAMERATE` / `MAINTAIN_RESOLUTION`) on the sender. So this is a
    // note about where to look later, not a gap.

    _emit(LocalMediaState(
      capturing: true,
      audioEnabled: audioTrack != null,
      videoEnabled: videoTrack != null,
      frontCamera: true,
      videoTrackId: videoTrack?.id,
      audioTrackId: audioTrack?.id,
    ));
    _log('media: capturing '
        '${[if (audioTrack != null) 'audio', if (videoTrack != null) 'video'].join(' + ')}');

    // A fresh session does not imply a fresh device. Something else may hold the
    // mute switch — another app, or a previous run that died before releasing it
    // — so ask rather than open on an optimistic "unmuted".
    if (audioTrack != null) await _syncMuteFromDevice();
  }

  @override
  Future<void> stopCapture() async {
    final stream = _stream;
    _stream = null;

    // Leave the device as we found it. Device mute outlives this object — a
    // session ended while muted would otherwise start the *next* one muted, with
    // nothing on screen explaining why.
    if (stream != null) {
      try {
        await Helper.setMicrophoneMuted(false);
      } on Object {
        /* nothing to do but not leave it stuck */
      }
    }
    if (stream != null) {
      // Stopping each track *and* disposing the stream. Disposing alone leaves
      // the camera light on for a moment on iOS, which looks like a privacy bug
      // whether or not it is one.
      for (final track in [...stream.getTracks()]) {
        try {
          await track.stop();
        } on Object {
          /* already gone */
        }
      }
      try {
        await stream.dispose();
      } on Object {
        /* already gone */
      }
    }
    _emit(const LocalMediaState());
  }

  @override
  Future<void> setAudioEnabled(bool enabled) async {
    if (_stream?.getAudioTracks().firstOrNull == null) return;

    try {
      await Helper.setMicrophoneMuted(!enabled);
    } on Object catch (error) {
      // Do not claim a state we failed to reach. A mute button that lies is
      // worse than one that visibly did nothing.
      _log('media: could not ${enabled ? 'unmute' : 'mute'} the device: $error');
      return;
    }

    await _syncMuteFromDevice();
  }

  /// Reads the device's own answer rather than trusting ours.
  ///
  /// `setMicrophoneMuted` is a global switch, so our idea of it can go stale for
  /// reasons that have nothing to do with this object. On a platform where the
  /// call is a no-op this correctly reports *unmuted*, because nothing was muted.
  Future<void> _syncMuteFromDevice() async {
    bool muted;
    try {
      muted = await Helper.isMicrophoneMuted();
    } on Object catch (error) {
      _log('media: could not read the device mute state: $error');
      return;
    }
    _emit(_state.copyWith(audioEnabled: !muted));
  }

  @override
  Future<void> setVideoEnabled(bool enabled) async {
    final track = _stream?.getVideoTracks().firstOrNull;
    if (track == null) return;
    track.enabled = enabled;
    _emit(_state.copyWith(videoEnabled: enabled));
  }

  @override
  Future<void> switchCamera() async {
    final track = _stream?.getVideoTracks().firstOrNull;
    if (track == null) return;
    try {
      await Helper.switchCamera(track);
      _emit(_state.copyWith(frontCamera: !_state.frontCamera));
    } on Object catch (error) {
      _log('media: could not switch camera: $error');
    }
  }

  @override
  Future<void> dispose() async {
    await stopCapture();
    await _states.close();
  }

  void _emit(LocalMediaState next) {
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }
}

/// Turns the plugin's platform errors into something a screen can act on.
///
/// The strings differ per platform and per OS version, so this matches loosely
/// and falls back to [MediaFailureKind.unknown] rather than guessing — telling
/// someone to open Settings when the real fault was a busy camera sends them
/// somewhere that cannot help.
MediaFailure _classify(Object error) {
  final text = error.toString().toLowerCase();
  if (text.contains('notallowed') ||
      text.contains('permission') ||
      text.contains('denied')) {
    return MediaFailure(
      MediaFailureKind.permissionDenied,
      'Gather Companion needs the microphone and camera.',
    );
  }
  if (text.contains('notfound') ||
      text.contains('no device') ||
      text.contains('notreadable') ||
      text.contains('could not start')) {
    return MediaFailure(
      MediaFailureKind.noDevice,
      'No microphone or camera is available right now.',
    );
  }
  return MediaFailure(MediaFailureKind.unknown, '$error');
}
