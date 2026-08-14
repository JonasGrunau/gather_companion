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
    this.participants = const [],
    this.detail,
  });

  final LocalMediaState media;

  /// Everybody else we are receiving, in no particular order.
  ///
  /// Deliberately free of `MediaStream`: a native handle here would drag the
  /// WebRTC plugin into every file that reads call state, and the fake engine
  /// could no longer stand in. The screen that draws video reaches for
  /// `LiveCall.streamFor` instead, which is the same split `localStream` uses.
  final List<CallParticipant> participants;

  /// Whether the room is actually receiving each track, as opposed to us merely
  /// having it open.
  final bool publishingAudio;
  final bool publishingVideo;

  /// What went wrong, if the last thing asked for did not happen. A sentence, for
  /// putting in front of a person.
  final String? detail;

  bool get micOn => media.capturing && media.audioEnabled;
  bool get cameraOn => media.hasVideo;

  /// Whether anybody else is on the other end. A call of one is a rehearsal.
  bool get hasCompany => participants.isNotEmpty;

  /// Whether the hardware is open at all — false before the first tap, which is
  /// what makes the bar honest about not holding the camera until asked.
  bool get live => media.capturing;

  CallState copyWith({
    LocalMediaState? media,
    bool? publishingAudio,
    bool? publishingVideo,
    List<CallParticipant>? participants,
    String? detail,
    bool clearDetail = false,
  }) =>
      CallState(
        media: media ?? this.media,
        publishingAudio: publishingAudio ?? this.publishingAudio,
        publishingVideo: publishingVideo ?? this.publishingVideo,
        participants: participants ?? this.participants,
        detail: clearDetail ? null : (detail ?? this.detail),
      );

  @override
  String toString() => 'CallState(mic: $micOn, camera: $cameraOn, '
      'publishing: ${[
        if (publishingAudio) 'audio',
        if (publishingVideo) 'video',
      ].join('+')})';
}

/// Somebody else in the call, as the UI needs to know them.
///
/// Identified by `srcId` — their `UserAccount.id`, which is what the media plane
/// speaks — and **not** by `SpaceUser.id`, which is what the roster speaks. Any
/// screen that wants to put a name to a tile has to bridge the two through
/// `RosterRow.userAccountId`; the two planes genuinely disagree about what a
/// person is called.
class CallParticipant {
  const CallParticipant({
    required this.srcId,
    this.hasAudio = false,
    this.hasVideo = false,
    this.audioPaused = false,
    this.videoPaused = false,
    this.sharingScreen = false,
  });

  final String srcId;
  final bool hasAudio;
  final bool hasVideo;

  /// *Their* mute, not ours. The track is still subscribed and will start again
  /// without renegotiating, so a paused person is present, not gone.
  final bool audioPaused;
  final bool videoPaused;
  final bool sharingScreen;

  bool get videoLive => hasVideo && !videoPaused;
  bool get muted => !hasAudio || audioPaused;

  @override
  String toString() => 'CallParticipant($srcId, '
      '${[if (hasAudio) 'audio', if (videoLive) 'video'].join('+')})';
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

  /// Who is allowed to see and hear **us**, by `UserAccount.id`.
  ///
  /// A separate, wider set than [setListeningTo], and separate for the reason the
  /// desktop client keeps them separate: this one is everybody *in range*, and it
  /// is what makes your camera appear in a circle over your avatar for anyone
  /// standing near you. Without it, publishing video reaches nobody — the SFU
  /// answers their `consume` with `consume-not-allowed`.
  Future<void> setVisibleTo(Set<String> srcIds);

  /// Who we should be receiving, by `UserAccount.id`.
  ///
  /// The whole desired set every time rather than joins and leaves, because that
  /// is the shape the cluster arrives in and diffing in one place is the only way
  /// to be sure somebody who vanished between two rosters is actually let go.
  Future<void> setListeningTo(Set<String> srcIds);

  /// Puts the hardware down and stops publishing. The call can be restarted.
  Future<void> hangUp();

  Future<void> dispose();
}
