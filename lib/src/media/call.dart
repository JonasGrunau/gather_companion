/// Being audible and visible in the room, as the rest of the app sees it.
///
/// [MediaEngine] is the hardware and [SfuSession] is the wire; this is the pair
/// of them, driven by the two buttons a person actually presses. Splitting it out
/// is what keeps `AppState` free of `flutter_webrtc` — the same discipline that
/// put the capture behind [MediaEngine] in the first place, one level up.
///
/// ## Why mute is two things at once
///
/// Turning the microphone off does both a device mute and a `produce-pause`, and
/// neither is redundant. The device mute is what makes iOS drop its recording
/// indicator, so the phone stops claiming to listen. The pause is what makes a
/// colleague's client draw the crossed-out microphone beside your name. Doing
/// only the first leaves everyone else believing you are live; doing only the
/// second leaves the orange dot lit while you are muted, which is the worse of
/// the two lies.
///
/// ## Why the producers are kept while muted
///
/// A producer is an ICE and DTLS negotiation. Closing it on every mute would make
/// unmuting take a second or more, in the one moment where a person has decided
/// to speak — so muting pauses and unmuting resumes, and the transport is built
/// once.
library;

import 'media_engine.dart';

/// What the call is doing, on top of what the hardware is doing.
///
/// [LocalMediaState] answers "is the camera on"; this adds "does anybody else
/// receive it", which are different questions and fail separately — a phone can
/// be capturing perfectly while the SFU has refused us.
class CallState {
  const CallState({
    this.media = const LocalMediaState(),
    this.publishingAudio = false,
    this.publishingVideo = false,
    this.detail,
  });

  final LocalMediaState media;

  /// Whether the room is actually receiving each track, as opposed to us merely
  /// having it open.
  final bool publishingAudio;
  final bool publishingVideo;

  /// What went wrong, if the last thing asked for did not happen. A sentence, for
  /// putting in front of a person.
  final String? detail;

  bool get micOn => media.capturing && media.audioEnabled;
  bool get cameraOn => media.hasVideo;

  /// Whether the hardware is open at all — false before the first tap, which is
  /// what makes the bar honest about not holding the camera until asked.
  bool get live => media.capturing;

  CallState copyWith({
    LocalMediaState? media,
    bool? publishingAudio,
    bool? publishingVideo,
    String? detail,
    bool clearDetail = false,
  }) =>
      CallState(
        media: media ?? this.media,
        publishingAudio: publishingAudio ?? this.publishingAudio,
        publishingVideo: publishingVideo ?? this.publishingVideo,
        detail: clearDetail ? null : (detail ?? this.detail),
      );

  @override
  String toString() => 'CallState(mic: $micOn, camera: $cameraOn, '
      'publishing: ${[
        if (publishingAudio) 'audio',
        if (publishingVideo) 'video',
      ].join('+')})';
}

/// The two buttons, and what it takes to honour them.
///
/// Every method is safe to call in any order and at any time: the first one that
/// needs hardware opens it, and the first one that needs the SFU connects to it.
/// Nothing is opened before it is asked for, which is the whole reason a phone
/// can sit on the map screen without its camera light on.
abstract class Call {
  Stream<CallState> get states;
  CallState get state;

  /// Turns the microphone on or off, opening the hardware the first time.
  ///
  /// Returns null when it took, or a sentence explaining why it did not — the
  /// same contract as `AppState.setPartyMode`, because it ends up in the same
  /// snack bar.
  Future<String?> setMicOn(bool on);

  Future<String?> setCameraOn(bool on);

  /// Front to back and back again. A no-op with no camera running.
  Future<void> switchCamera();

  /// Puts the hardware down and stops publishing. The call can be restarted.
  Future<void> hangUp();

  Future<void> dispose();
}
