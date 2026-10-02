/// Does the microphone work, does the camera work, does sound come out, and do
/// you look right?
///
/// The first thing the media stack needed was somewhere to prove it runs at all
/// on a real device — permissions granted, a capture session opened, frames
/// arriving. That is worth keeping rather than throwing away once calls work: a
/// device check before you join something is a normal thing for a call app to
/// have, and it answers "is it me or is it them" without dragging a colleague
/// into the experiment.
///
/// It now checks the whole audio path a meeting uses, not just the camera: a
/// live level meter off the microphone, the speaker/earpiece route, and a sound
/// to send out of it. All three lean on the **same** code a real call runs —
/// `WebrtcMediaEngine.startCapture`, the `media-source audioLevel` stat behind
/// the speaking ring, and `prepareAudioSession`/`setSpeakerOn` — so a setup that
/// passes here is the setup a meeting will use.
///
/// Nothing here talks to Gather. It opens the hardware, draws it, and lets go.
///
/// ## Where the level comes from with no meeting running
///
/// In a call the microphone level is read from the SFU producer's `getStats`.
/// There is no SFU here, so this stands up a loopback of two
/// `RTCPeerConnection`s wired to each other — the live audio track on the
/// sender, the receiver answering it, ICE and DTLS completing between them — and
/// reads `audioLevel` off the sender's `media-source` stats row, the identical
/// number `VoiceActivity` thresholds in a call. The connection goes nowhere off
/// the device, but it must genuinely *connect*: iOS libwebrtc only runs the
/// audio send pipeline that fills in that stat once the transport is writable, so
/// a local offer that is never answered reads as a dead microphone.
///
/// ## The renderer's lifetime is the widget's
///
/// `RTCVideoRenderer` holds a native texture. It must be `initialize()`d before
/// use and `dispose()`d after, and its lifetime has to be tied to the widget
/// rather than to the engine — which is why this is a `StatefulWidget` and why
/// `srcObject` is cleared before disposing. Getting that wrong leaks a texture
/// per visit, and the symptom is a slow crawl rather than a crash. The loopback
/// connection and the audio player are torn down in the same order and for the
/// same reason.
library;

import 'dart:async';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../src/media/media_engine.dart';
import '../src/media/mic_level.dart';
import '../src/media/test_tone.dart';
import '../src/media/voice_activity.dart';
import '../src/media/webrtc_media_engine.dart';
import '../theme/gather_theme.dart';

/// The playback session for the test sound, pinned to the call's own route.
///
/// `playAndRecord` with `mixWithOthers` on iOS so the chime rides the voice
/// session [WebrtcMediaEngine.prepareAudioSession] set up rather than tearing it
/// down and routing itself to the media speaker; `voiceCommunication` on Android
/// for the same reason. The point of the test is that the sound comes out where
/// a *call* would, so it must not open a session of its own.
///
/// Set **once**, globally, in `_start` — not per play. `audioplayers`
/// reconfigures and then deactivates the shared `AVAudioSession` around each
/// `play`, and doing that to the session flutter_webrtc is holding live restarts
/// its voice processing IO unit and freezes the app. Mirroring the call's session
/// here and never touching it again makes a `play` harmless.
final _toneContext = AudioContext(
  iOS: AudioContextIOS(
    category: AVAudioSessionCategory.playAndRecord,
    options: const {
      AVAudioSessionOptions.mixWithOthers,
      AVAudioSessionOptions.allowBluetooth,
    },
  ),
  android: const AudioContextAndroid(
    contentType: AndroidContentType.sonification,
    usageType: AndroidUsageType.voiceCommunication,
    audioFocus: AndroidAudioFocus.gainTransientMayDuck,
  ),
);

class MediaCheckScreen extends StatefulWidget {
  const MediaCheckScreen({super.key});

  @override
  State<MediaCheckScreen> createState() => _MediaCheckScreenState();
}

class _MediaCheckScreenState extends State<MediaCheckScreen> {
  final _renderer = RTCVideoRenderer();
  late final WebrtcMediaEngine _engine = WebrtcMediaEngine(log: debugPrint);

  /// The loopback that makes the microphone level readable without a meeting —
  /// see the header. A *connected* pair: [_meterPc] sends the live audio track to
  /// [_meterRecvPc], and the level is read off the sender. Both null until
  /// capture gives us an audio track.
  RTCPeerConnection? _meterPc;
  RTCPeerConnection? _meterRecvPc;
  Timer? _meterTimer;

  /// The same speaking decision the call draws its ring from, run here against
  /// the loopback level so the meter's "we can hear you" settles with the same
  /// hold the ring does.
  final _voice = VoiceActivity();

  /// The test sound's player, and the dice for which chime it plays.
  final _player = AudioPlayer();
  final _rng = Random();

  LocalMediaState _state = const LocalMediaState();

  /// The latest loopback level, 0–1, for the meter bar.
  double _level = 0;
  bool _starting = true;

  @override
  void initState() {
    super.initState();
    _engine.states.listen((s) {
      if (mounted) setState(() => _state = s);
    });
    _start();
  }

  Future<void> _start() async {
    await _renderer.initialize();
    // Configure the player's audio session once, globally, and never again. The
    // reconfigure `audioplayers` does on every `play` otherwise — and the
    // deactivate it does when playback ends — reach into the *same*
    // `AVAudioSession` flutter_webrtc is holding live, and restarting the voice
    // processing IO unit mid-call froze the whole app. Setting it here, to a
    // session that mirrors the call's (`playAndRecord` + `mixWithOthers`), means
    // a `play` is just a play: no category change, nothing torn down.
    try {
      await AudioPlayer.global.setAudioContext(_toneContext);
      await _player.setReleaseMode(ReleaseMode.stop);
    } on Object catch (error) {
      debugPrint('media-check: could not configure the test-sound player: $error');
    }
    try {
      await _engine.startCapture();
      _renderer.srcObject = _engine.localStream;
      // The route the call would use, applied for a listen-and-speak test the
      // same way it is applied for a call: idempotent, so a retry is free.
      await _engine.prepareAudioSession();
      await _startMeter();
    } on MediaFailure {
      // Already on `_state` through the stream; the screen renders it below.
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  /// Stands up the loopback connection and starts polling the level.
  ///
  /// A *connected* local loopback: the sender holds the live audio track, the
  /// receiver answers it, ICE candidates are traded both ways, and DTLS comes up
  /// — all on the device, going nowhere. The connection has to actually complete,
  /// because on iOS libwebrtc only runs the audio send pipeline (and computes the
  /// `media-source` `audioLevel` the bar reads) once the transport is writable. A
  /// local offer that is never answered — what this used to do — never connects,
  /// so the stat stayed empty and the bar never moved.
  Future<void> _startMeter() async {
    final stream = _engine.localStream;
    final track = stream?.getAudioTracks().firstOrNull;
    if (track == null) return;

    try {
      final send = await createPeerConnection(const <String, dynamic>{});
      final recv = await createPeerConnection(const <String, dynamic>{});

      // Trickle the candidates across to each other; localhost has few and they
      // arrive fast, so there is no need to wait and bundle them.
      send.onIceCandidate = (c) => recv.addCandidate(c);
      recv.onIceCandidate = (c) => send.addCandidate(c);

      // The receiver would otherwise play the mic straight back out the
      // loudspeaker, inches from that same live mic — a feedback howl. Muting the
      // received track kills the playout; the *send* side still runs, so the
      // level we read off it is unaffected.
      recv.onTrack = (e) => e.track.enabled = false;

      await send.addTrack(track, stream!);

      final offer = await send.createOffer();
      await send.setLocalDescription(offer);
      await recv.setRemoteDescription(offer);
      final answer = await recv.createAnswer();
      await recv.setLocalDescription(answer);
      await send.setRemoteDescription(answer);

      _meterPc = send;
      _meterRecvPc = recv;
    } on Object catch (error) {
      debugPrint('media-check: could not open the level meter: $error');
      return;
    }

    _meterTimer =
        Timer.periodic(const Duration(milliseconds: 200), (_) => _pollLevel());
  }

  /// One read of the loopback level, fed to [_voice] and the bar.
  Future<void> _pollLevel() async {
    final pc = _meterPc;
    if (pc == null) return;

    // Muted is known rather than measured: do not wait out the hold watching a
    // bar twitch on room noise the microphone is no longer sending.
    if (!_state.audioEnabled) {
      _voice.silence();
      if (mounted && _level != 0) setState(() => _level = 0);
      return;
    }

    final List<StatsReport> reports;
    try {
      reports = await pc.getStats();
    } on Object {
      return; // Polled four times a second; a dropped read fixes itself.
    }

    // The same row the SFU path reads: `media-source`, `kind == audio`, a linear
    // `audioLevel`. See `sfu_session.dart`'s `microphoneLevel`.
    double? level;
    for (final report in reports) {
      if (report.type != 'media-source') continue;
      final values = report.values;
      if (values['kind'] != 'audio') continue;
      final value = values['audioLevel'];
      if (value is num) level = value.toDouble();
    }

    _voice.note(level, DateTime.now());
    if (mounted) setState(() => _level = level ?? 0);
  }

  Future<void> _playTone() async {
    // No `setAudioContext` here on purpose — the session is set once in `_start`.
    // Touching it per play is what hung the app; see there.
    try {
      await _player.play(
        BytesSource(chimeWav(variant: _rng.nextInt(variantCount)),
            mimeType: 'audio/wav'),
      );
    } on Object catch (error) {
      debugPrint('media-check: could not play the test sound: $error');
    }
  }

  @override
  void dispose() {
    // Order matters: stop the poll, let go of the loopback connection and the
    // player, then drop the texture's reference to the stream before the engine
    // stops the tracks underneath it.
    _meterTimer?.cancel();
    unawaited(_meterPc?.dispose());
    unawaited(_meterRecvPc?.dispose());
    unawaited(_player.dispose());
    _renderer.srcObject = null;
    _renderer.dispose();
    _engine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.background,
        title: const Text('Check your setup'),
        titleTextStyle: Theme.of(context).textTheme.titleLarge,
      ),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: kGutter),
          child: Column(
            children: [
              Expanded(
                child: _Preview(
                  renderer: _renderer,
                  state: _state,
                  starting: _starting,
                  onRetry: () {
                    setState(() => _starting = true);
                    _start();
                  },
                ),
              ),
              if (_state.capturing)
                _AudioMeter(
                  fraction: meterFraction(_level),
                  heard: _voice.speaking,
                  live: _state.audioEnabled,
                ),
              if (_state.capturing)
                _Controls(engine: _engine, state: _state, onPlayTone: _playTone),
              const SizedBox(height: kGutter),
            ],
          ),
        ),
      ),
    );
  }
}

/// The three states this screen can honestly be in, kept distinct.
///
/// `lib/ui/AGENTS.md`: a denied permission is not a network problem and must not
/// render as a spinner. Nor is "no camera on this device" the same as "you said
/// no" — one is fixed in Settings and the other cannot be.
class _Preview extends StatelessWidget {
  const _Preview({
    required this.renderer,
    required this.state,
    required this.starting,
    required this.onRetry,
  });

  final RTCVideoRenderer renderer;
  final LocalMediaState state;
  final bool starting;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final failure = state.failure;

    Widget frame(Widget child) => Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: kGutter),
          decoration: BoxDecoration(
            color: t.card,
            border: Border.all(color: t.border),
            borderRadius: BorderRadius.circular(t.radius),
          ),
          clipBehavior: Clip.antiAlias,
          child: child,
        );

    if (failure != null) {
      return frame(_Message(
        icon: failure.needsSettings ? Icons.lock_outline_rounded : Icons.videocam_off_outlined,
        title: failure.needsSettings ? 'Permission needed' : 'No camera or microphone',
        body: failure.needsSettings
            ? 'Gather Companion needs the microphone and camera. '
                'Turn them on in Settings, then come back.'
            : failure.message,
        action: failure.needsSettings ? null : ('Try again', onRetry),
      ));
    }

    if (starting) {
      return frame(const _Message(
        icon: Icons.hourglass_empty_rounded,
        title: 'Starting',
        body: 'Opening the microphone and camera.',
      ));
    }

    if (!state.hasVideo) {
      // Capturing, but nothing to draw: the camera is off, or this device has
      // none. Both are fine and neither is an error.
      return frame(_Message(
        icon: Icons.videocam_off_outlined,
        title: state.capturing ? 'Camera off' : 'Not capturing',
        body: state.audioEnabled
            ? 'Your microphone is live.'
            : 'Your microphone is muted.',
      ));
    }

    return frame(
      RTCVideoView(
        renderer,
        // A front camera that is not mirrored looks wrong to the person in it,
        // and only to them — everyone else sees it unmirrored either way.
        mirror: state.frontCamera,
        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final act = action;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(kTextGutter),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 34, color: t.faint),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: t.mutedForeground),
            ),
            if (act != null) ...[
              const SizedBox(height: 14),
              TextButton(onPressed: act.$2, child: Text(act.$1)),
            ],
          ],
        ),
      ),
    );
  }
}

/// The live microphone level, as a bar that fills while you talk.
///
/// The same decision the call's speaking ring makes drives the colour: quiet is
/// [GatherTokens.brand] like every other live control, and [GatherTokens.ok] —
/// the connected green — once [VoiceActivity] is satisfied it is really hearing
/// speech and not just a held phone's room noise. Muted draws the bar empty and
/// says so, because a flat meter with no explanation reads as a broken one.
class _AudioMeter extends StatelessWidget {
  const _AudioMeter({
    required this.fraction,
    required this.heard,
    required this.live,
  });

  final double fraction;
  final bool heard;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final fill = heard ? t.ok : t.brand;
    final (label, labelColour) = !live
        ? ('Microphone muted', t.faint)
        : heard
            ? ('We can hear you', t.ok)
            : ('Say something — the bar moves when it hears you', t.mutedForeground);

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(
            live ? Icons.mic_rounded : Icons.mic_off_rounded,
            size: 20,
            color: !live ? t.faint : (heard ? t.ok : t.mutedForeground),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: SizedBox(
                    height: 8,
                    width: double.infinity,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ColoredBox(color: t.secondary),
                        FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: live ? fraction.clamp(0.0, 1.0) : 0.0,
                          child: ColoredBox(color: fill),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(label, style: TextStyle(fontSize: 12.5, color: labelColour)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.engine,
    required this.state,
    required this.onPlayTone,
  });

  final MediaEngine engine;
  final LocalMediaState state;
  final VoidCallback onPlayTone;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final onSpeaker = state.audioOutput == AudioOutput.speaker;

    // The same glyph the control bar's route button uses — where you are now —
    // so the switch here reads as the same control you will meet in a call. The
    // label names where a tap sends you, not where you are: the button is a
    // switch, and the brand tint already says when the speaker is the live one.
    final routeIcon = switch (state.audioOutput) {
      AudioOutput.speaker => Icons.volume_up_rounded,
      AudioOutput.earpiece => Icons.phone_in_talk_rounded,
      AudioOutput.bluetooth => Icons.bluetooth_audio_rounded,
      AudioOutput.wired => Icons.headset_rounded,
    };
    final routeLabel = onSpeaker ? 'Earpiece' : 'Speaker';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _Toggle(
              on: state.audioEnabled,
              onIcon: Icons.mic_rounded,
              offIcon: Icons.mic_off_rounded,
              label: state.audioEnabled ? 'Mic on' : 'Muted',
              onTap: () => engine.setAudioEnabled(!state.audioEnabled),
            ),
            _Toggle(
              on: state.videoEnabled,
              onIcon: Icons.videocam_rounded,
              offIcon: Icons.videocam_off_rounded,
              label: state.videoEnabled ? 'Camera on' : 'Camera off',
              onTap: () => engine.setVideoEnabled(!state.videoEnabled),
            ),
            _Toggle(
              on: true,
              onIcon: Icons.cameraswitch_rounded,
              offIcon: Icons.cameraswitch_rounded,
              label: state.frontCamera ? 'Front' : 'Back',
              onTap: state.hasVideo ? engine.switchCamera : null,
              tint: t.mutedForeground,
            ),
            // The call's own route control, driven straight off the engine: the
            // loudspeaker wears the brand like a live control, every other route
            // the resting grey. A tap forces the speaker on, or hands the route
            // back to the system (headset-if-present, else earpiece).
            _Toggle(
              on: onSpeaker,
              onIcon: routeIcon,
              offIcon: routeIcon,
              label: routeLabel,
              tint: onSpeaker ? t.brand : t.mutedForeground,
              onTap: () => engine.setSpeakerOn(!onSpeaker),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Hear it for yourself: a short chime out of whatever the route above
        // says, so the speaker test needs no second person on the line.
        TextButton.icon(
          onPressed: onPlayTone,
          icon: const Icon(Icons.graphic_eq_rounded, size: 18),
          label: const Text('Play a test sound'),
        ),
      ],
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.on,
    required this.onIcon,
    required this.offIcon,
    required this.label,
    required this.onTap,
    this.tint,
  });

  final bool on;
  final IconData onIcon;
  final IconData offIcon;
  final String label;
  final VoidCallback? onTap;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final enabled = onTap != null;
    final colour = !enabled ? t.faint : (tint ?? (on ? t.brand : t.danger));

    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(t.radius),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(on ? onIcon : offIcon, color: colour, size: 26),
              const SizedBox(height: 6),
              Text(label, style: TextStyle(fontSize: 12, color: t.mutedForeground)),
            ],
          ),
        ),
      ),
    );
  }
}
