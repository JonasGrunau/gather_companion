/// The line between "what the call is doing" and "what the hardware is doing".
///
/// Everything above this interface — deciding who to call, when to publish, when
/// to tear down — is ordinary logic and should be testable with `flutter test` on
/// a machine with no camera. Everything below it needs a real device, a real
/// microphone, and permissions a test runner cannot grant.
///
/// So the seam sits here, and it is the twin of the one `AppState` already has
/// for `DirectCollector`: production injects [WebrtcMediaEngine], tests inject a
/// fake. **Nothing in this file imports `flutter_webrtc`**, which is the property
/// that makes that possible — one import in the wrong place and the fake stops
/// being able to stand in.
///
/// The interface is deliberately about *state and identity*, not about native
/// objects. A `MediaStream` cannot cross this boundary without dragging the
/// plugin with it, so rendering is looked up separately by the widget layer,
/// which has its own seam for the same reason.
library;

/// Why capture failed, when it did.
///
/// The distinction that matters to a person is [permissionDenied] versus
/// everything else: one is fixed in Settings and the other is not, and rendering
/// a spinner for the first is the exact mistake `lib/ui/AGENTS.md` warns about.
enum MediaFailureKind {
  /// The user said no, or has said no before and iOS is not asking again.
  permissionDenied,

  /// No camera or microphone the OS is willing to hand over — a simulator, or a
  /// device where another app holds the capture session.
  noDevice,

  /// Anything else. Worth retrying; not worth explaining.
  unknown,
}

/// Where the remote audio is coming out, as the UI needs to name it.
///
/// Deliberately the four a person can see on the device, not the plugin's notion
/// of a route: the button draws a different glyph for each, and `bluetooth` and
/// `wired` both mean "a headset is in", which is the state that overrides the
/// speaker/earpiece choice.
enum AudioOutput { speaker, earpiece, bluetooth, wired }

class MediaFailure implements Exception {
  const MediaFailure(this.kind, this.message);

  final MediaFailureKind kind;
  final String message;

  /// Whether telling the user to open Settings is the honest advice.
  bool get needsSettings => kind == MediaFailureKind.permissionDenied;

  @override
  String toString() => 'MediaFailure(${kind.name}, $message)';
}

/// What our own microphone and camera are doing.
///
/// `enabled` is not the same as `capturing`: a muted microphone is still a live
/// capture session holding the hardware, which is why unmuting is instant and
/// starting is not.
class LocalMediaState {
  const LocalMediaState({
    this.capturing = false,
    this.audioEnabled = false,
    this.videoEnabled = false,
    this.frontCamera = true,
    this.audioOutput = AudioOutput.speaker,
    this.videoTrackId,
    this.audioTrackId,
    this.screenCapturing = false,
    this.screenTrackId,
    this.failure,
  });

  final bool capturing;
  final bool audioEnabled;
  final bool videoEnabled;
  final bool frontCamera;

  /// The screen share is a *second* capture, independent of the camera/mic one
  /// above: it comes from `getDisplayMedia` (ReplayKit on iOS, MediaProjection on
  /// Android), not `getUserMedia`, and lives or dies on its own. Kept beside the
  /// camera fields rather than folded into [capturing] because a person can share
  /// their screen with their camera still on, and the two capture sessions start
  /// and stop for unrelated reasons.
  ///
  /// [screenTrackId] going null while [screenCapturing] was true is how the engine
  /// reports the OS tore the broadcast down from under us — the system "Stop"
  /// control, an incoming phone call, a permission revoked — so the caller can
  /// drop the producer rather than keep publishing a dead track.
  final bool screenCapturing;
  final String? screenTrackId;

  /// Where the sound is coming out. The speaker until routing is applied: that
  /// is the default [WebrtcMediaEngine] itself settles on (no headset ⇒ speaker,
  /// the desk-companion route), so starting here means the control shows the real
  /// route from the first frame instead of flipping earpiece→speaker once the
  /// session comes up.
  final AudioOutput audioOutput;

  /// Track identities, so a caller can tell one capture session from the next
  /// without holding a native object.
  final String? videoTrackId;
  final String? audioTrackId;

  final MediaFailure? failure;

  /// Whether there is a live video track worth drawing.
  bool get hasVideo => capturing && videoEnabled && videoTrackId != null;

  /// Whether there is a live screen-share track worth publishing.
  bool get hasScreen => screenCapturing && screenTrackId != null;

  LocalMediaState copyWith({
    bool? capturing,
    bool? audioEnabled,
    bool? videoEnabled,
    bool? frontCamera,
    AudioOutput? audioOutput,
    String? videoTrackId,
    String? audioTrackId,
    bool? screenCapturing,
    String? screenTrackId,
    MediaFailure? failure,
    bool clearFailure = false,
    bool clearTracks = false,
    bool clearScreen = false,
  }) =>
      LocalMediaState(
        capturing: capturing ?? this.capturing,
        audioEnabled: audioEnabled ?? this.audioEnabled,
        videoEnabled: videoEnabled ?? this.videoEnabled,
        frontCamera: frontCamera ?? this.frontCamera,
        audioOutput: audioOutput ?? this.audioOutput,
        videoTrackId: clearTracks ? null : (videoTrackId ?? this.videoTrackId),
        audioTrackId: clearTracks ? null : (audioTrackId ?? this.audioTrackId),
        // Screen is its own capture, so [clearTracks] — which follows a camera/mic
        // stop — must not touch it; only [clearScreen] drops the screen fields.
        screenCapturing:
            clearScreen ? false : (screenCapturing ?? this.screenCapturing),
        screenTrackId:
            clearScreen ? null : (screenTrackId ?? this.screenTrackId),
        failure: clearFailure ? null : (failure ?? this.failure),
      );

  @override
  String toString() => 'LocalMediaState(capturing: $capturing, '
      'audio: $audioEnabled, video: $videoEnabled, out: ${audioOutput.name}'
      '${screenCapturing ? ', screen' : ''}'
      '${failure == null ? '' : ', $failure'})';
}

/// Holding the hardware, and nothing else.
///
/// Publishing to Gather is a separate concern layered on top — this only knows
/// how to open a capture session and how to let go of one.
abstract class MediaEngine {
  /// The current state, and every change to it.
  Stream<LocalMediaState> get states;
  LocalMediaState get state;

  /// Opens a capture session, asking for permission if it has not been asked.
  ///
  /// Throws [MediaFailure] rather than returning a flag, because every caller has
  /// to handle the permission case explicitly and a bool invites forgetting.
  Future<void> startCapture({bool audio = true, bool video = true});

  /// Releases the hardware. Safe to call when nothing is running.
  Future<void> stopCapture();

  /// Mutes without releasing the microphone, so unmuting is instant.
  Future<void> setAudioEnabled(bool enabled);

  /// Configures the platform audio session for a call and applies the initial
  /// output route. Idempotent, and safe to call while only listening — before
  /// any capture — because that is when the earpiece-default bug first bites.
  Future<void> prepareAudioSession();

  /// Forces the loudspeaker on (`true`) or releases the override (`false`),
  /// letting the system route to a headset if one is connected, otherwise the
  /// earpiece. The resulting route lands in [LocalMediaState.audioOutput].
  Future<void> setSpeakerOn(bool on);

  /// Hands the audio session back at the end of a call. Separate from
  /// [stopCapture] on purpose: capture is torn down and rebuilt mid-call to add
  /// the camera, and the routing must survive that — it belongs to the call, not
  /// the capture session.
  Future<void> releaseAudioSession();

  /// Stops sending video without releasing the camera.
  Future<void> setVideoEnabled(bool enabled);

  /// Opens the screen-share capture — the system picker on iOS (ReplayKit), the
  /// consent dialog on Android (MediaProjection) — as a *second*, independent
  /// capture that leaves the camera/mic session untouched.
  ///
  /// Throws [MediaFailure] when the person declines the picker or the platform
  /// refuses, the same contract as [startCapture]. Idempotent: a second call
  /// while already sharing does nothing.
  Future<void> startScreenCapture();

  /// Stops the screen-share capture and releases its track, leaving the
  /// camera/mic capture alone. Safe to call when nothing is sharing.
  Future<void> stopScreenCapture();

  /// Front to back and back again.
  Future<void> switchCamera();

  Future<void> dispose();
}
