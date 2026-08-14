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
  StreamSubscription<List<RemoteMedia>>? _remoteSub;
  StreamSubscription<SfuNotification>? _noticeSub;
  SfuSession? _sfu;

  /// Who we want to hear, held here rather than only in the session.
  ///
  /// The cluster can change while the SFU is not connected — a colleague walks
  /// over before anyone has tapped anything — and the desired set has to survive
  /// that so the session can be brought up to date once it exists.
  Set<String> _listeningTo = const {};

  /// Who may consume us — everybody in range, not just the conversation.
  Set<String> _visibleTo = const {};

  /// The streams behind [CallState.participants], by `srcId`.
  final Map<String, Map<SfuTag, MediaStream>> _remoteStreams = {};

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
      // Disposed rather than stopped: it is being thrown away, and `stop` leaves
      // its stream controllers open with nothing left to feed them.
      await _remoteSub?.cancel();
      _remoteSub = null;
      await _noticeSub?.cancel();
      _noticeSub = null;
      await existing.dispose();
    }
    final sfu = _sfu = _buildSfu();
    _remoteSub = sfu.remoteChanges.listen(_onRemotes);
    _noticeSub = sfu.notifications.listen(_onNotice);
    // Before `start()`, so the node replays it the moment it connects rather
    // than after the first track has already gone out unwatchable.
    sfu.setAllowed(_visibleTo);
    await sfu.start();

    // Whatever the room looked like while we were not connected is what it
    // should look like now. Without this, everybody who was already standing
    // there when the mic was first tapped would be silent.
    if (_listeningTo.isNotEmpty) await sfu.setSubscriptions(_listeningTo);
    return sfu;
  }

  @override
  Future<void> setVisibleTo(Set<String> srcIds) async {
    if (_visibleTo.length == srcIds.length && _visibleTo.containsAll(srcIds)) {
      return;
    }
    _visibleTo = Set.unmodifiable(srcIds);
    // Held whether or not a session exists, and replayed by `start()`. Somebody
    // can walk up to you long before you tap anything, and the allow list has to
    // be right at the moment the first track goes out — not one roster later.
    _sfu?.setAllowed(_visibleTo);
  }

  @override
  Future<void> setListeningTo(Set<String> srcIds) async {
    if (_listeningTo.length == srcIds.length &&
        _listeningTo.containsAll(srcIds)) {
      return;
    }
    _listeningTo = Set.unmodifiable(srcIds);

    // Only reconciled against a session that already exists. Somebody walking
    // past must not be what opens a socket — the person here has not asked for
    // anything yet, and a call nobody started should cost nothing.
    final sfu = _sfu;
    if (sfu == null || !sfu.ready) return;
    await sfu.setSubscriptions(_listeningTo);
  }

  /// The streams for one participant, for the widget that draws them.
  ///
  /// Concrete rather than on [Call], for the same reason [localStream] is: a
  /// `MediaStream` on the interface would drag the plugin into everything that
  /// reads call state.
  Map<SfuTag, MediaStream> streamFor(String srcId) =>
      _remoteStreams[srcId] ?? const {};

  /// The one server-pushed message a person needs to be told about.
  ///
  /// The phone and the desktop client are one `UserAccount`, so they are one
  /// `srcId` to the SFU. The phone keeps the call — you picked it up, so it is
  /// where you are — but the desktop letting go is the *server's* doing, not
  /// something this app can ask for: nothing in the protocol drops another
  /// client. So the honest thing is to name what is happening and what to do
  /// about it, rather than either going quiet or promising a handover we cannot
  /// perform.
  void _onNotice(SfuNotification n) {
    if (n.name != 'double-connected') return;
    final sfu = _sfu;

    if (sfu?.displaced ?? false) {
      _emit(_state.copyWith(
        publishingAudio: false,
        publishingVideo: false,
        detail: 'Your Mac keeps taking this call back. Quit Gather there, then '
            'turn your microphone on again here. You can still see and hear '
            'everyone in the meantime.',
      ));
      return;
    }

    _emit(_state.copyWith(
      detail: 'Gather is open on your Mac too. Quit it there if the sound '
          'starts jumping between them.',
    ));
  }

  void _onRemotes(List<RemoteMedia> remotes) {
    _remoteStreams
      ..clear()
      ..addEntries(remotes.map((r) => MapEntry(r.srcId, r.streams)));

    _emit(_state.copyWith(
      participants: [
        for (final r in remotes)
          CallParticipant(
            srcId: r.srcId,
            hasAudio: r.streams.containsKey(SfuTag.audio),
            hasVideo: r.streams.containsKey(SfuTag.video),
            audioPaused: r.paused.contains(SfuTag.audio),
            videoPaused: r.paused.contains(SfuTag.video),
            sharingScreen: r.streams.containsKey(SfuTag.screen),
          ),
      ],
    ));
  }

  String _fail(SfuTag tag, String sentence) {
    _emit(_state.copyWith(detail: sentence));
    return sentence;
  }

  @override
  Future<void> hangUp() async {
    _wantMic = false;
    _wantCamera = false;
    await _remoteSub?.cancel();
    _remoteSub = null;
    await _noticeSub?.cancel();
    _noticeSub = null;
    await _sfu?.dispose();
    _sfu = null;
    _remoteStreams.clear();
    await _engine.stopCapture();
    // The desired set survives a hang-up: the cluster has not changed just
    // because we stopped listening to it, and the next tap should pick up the
    // same room rather than an empty one.
    _emit(const CallState());
  }

  @override
  Future<void> dispose() async {
    await _engineSub?.cancel();
    _engineSub = null;
    await _remoteSub?.cancel();
    _remoteSub = null;
    await _noticeSub?.cancel();
    _noticeSub = null;
    await _sfu?.dispose();
    _sfu = null;
    _remoteStreams.clear();
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
