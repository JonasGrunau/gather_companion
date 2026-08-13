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
    this.videoTrackId,
    this.audioTrackId,
    this.failure,
  });

  final bool capturing;
  final bool audioEnabled;
  final bool videoEnabled;
  final bool frontCamera;

  /// Track identities, so a caller can tell one capture session from the next
  /// without holding a native object.
  final String? videoTrackId;
  final String? audioTrackId;

  final MediaFailure? failure;

  /// Whether there is a live video track worth drawing.
  bool get hasVideo => capturing && videoEnabled && videoTrackId != null;

  LocalMediaState copyWith({
    bool? capturing,
    bool? audioEnabled,
    bool? videoEnabled,
    bool? frontCamera,
    String? videoTrackId,
    String? audioTrackId,
    MediaFailure? failure,
    bool clearFailure = false,
    bool clearTracks = false,
  }) =>
      LocalMediaState(
        capturing: capturing ?? this.capturing,
        audioEnabled: audioEnabled ?? this.audioEnabled,
        videoEnabled: videoEnabled ?? this.videoEnabled,
        frontCamera: frontCamera ?? this.frontCamera,
        videoTrackId: clearTracks ? null : (videoTrackId ?? this.videoTrackId),
        audioTrackId: clearTracks ? null : (audioTrackId ?? this.audioTrackId),
        failure: clearFailure ? null : (failure ?? this.failure),
      );

  @override
  String toString() => 'LocalMediaState(capturing: $capturing, '
      'audio: $audioEnabled, video: $videoEnabled${failure == null ? '' : ', $failure'})';
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

  /// Stops sending video without releasing the camera.
  Future<void> setVideoEnabled(bool enabled);

  /// Front to back and back again.
  Future<void> switchCamera();

  Future<void> dispose();
}
