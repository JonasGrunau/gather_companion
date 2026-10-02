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
/// It checks the whole path a meeting uses: the camera preview, a microphone
/// that lights up when it hears you, the speaker/earpiece route, and a sound to
/// send out of it. Nothing here talks to Gather. It opens the hardware, draws it,
/// and lets go.
///
/// ## Two modes, one framework at a time
///
/// There are two honest things a person might want to check, and on iOS they
/// cannot run at once — so a toggle picks one and the other is fully torn down.
///
///  - **Device** exercises the raw hardware the lightest way: the `camera` plugin
///    for the preview (opened **`enableAudio: false`**, so it never touches the
///    audio session) and `record` for a live "we can hear you" light read
///    straight off the microphone, the way a device-setup screen in Teams or Zoom
///    does. One owner of the camera, one of the audio session, nothing to fight.
///
///  - **Call pipeline** exercises the WebRTC capture path with the real
///    [WebrtcMediaEngine] — the pre-branch check, restored: a plain
///    `startCapture()` with mic/camera/switch and real mute (`setAudioEnabled`),
///    but **no** `prepareAudioSession`, route toggle or test sound. Forcing a
///    route on this standalone capture (no SFU transport connected) drives the
///    voice-processing reconfiguration loop that lagged the screen; a real call
///    tolerates it because its transport is live. The mic shows a plain
///    live/muted status rather than a level — WebRTC gives no local audio level
///    without a connection, and the loopback that used to fake one is exactly
///    what froze this screen.
///
/// Why the split at all: `flutter_webrtc` forces the shared `AVAudioSession` into
/// `videoChat` mode whenever it holds the camera, while `record` has to activate
/// that same session for the meter. Run together they flap the voice-processing
/// I/O unit hundreds of times a second and freeze the device. Kept apart — each
/// mode in its own child widget, so switching unmounts and disposes the other —
/// neither ever contends for the session.
///
/// ## Lifetimes are the widget's
///
/// Both a `CameraController` and an `RTCVideoRenderer` hold native resources that
/// must be opened before use and disposed after, tied to the widget rather than
/// to anything longer-lived. iOS also reclaims the camera in the background, so
/// the `camera` controller is dropped on `paused` and reopened on `resumed`. The
/// recorder, the renderer and the audio player are torn down in the same place
/// and for the same reason.
library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:record/record.dart';

import '../src/media/media_engine.dart';
import '../src/media/mic_level.dart';
import '../src/media/test_tone.dart';
import '../src/media/voice_activity.dart';
import '../src/media/webrtc_media_engine.dart';
import '../theme/gather_theme.dart';

/// Which of the two checks is on screen.
enum _CheckMode { device, callPipeline }

/// The test sound's session in **Device** mode, pinned to the recorder's stance.
///
/// `playAndRecord` with `mixWithOthers` so the chime rides alongside the live
/// microphone capture rather than interrupting it, and `defaultToSpeaker` when the
/// speaker route is chosen so it comes out where a desk companion wants it. Here
/// `record` owns the session and there is no WebRTC to reassert a competing
/// category, so the route the toggle picks is the route that takes.
AudioContext _deviceToneContext({required bool speaker}) => AudioContext(
      iOS: AudioContextIOS(
        category: AVAudioSessionCategory.playAndRecord,
        options: {
          AVAudioSessionOptions.mixWithOthers,
          AVAudioSessionOptions.allowBluetooth,
          if (speaker) AVAudioSessionOptions.defaultToSpeaker,
        },
      ),
      android: const AudioContextAndroid(
        contentType: AndroidContentType.sonification,
        usageType: AndroidUsageType.voiceCommunication,
        audioFocus: AndroidAudioFocus.gainTransientMayDuck,
      ),
    );

// Call pipeline mode has no test sound: a chime would need audioplayers to
// reconfigure the AVAudioSession the engine owns, which revives the category
// thrash that froze the screen. The speaker test lives in Device mode, where
// nothing else is holding the session.

/// How the microphone is captured for the meter: raw signed-16-bit PCM, mono, at
/// a rate that is plenty to tell speech from silence and cheap to carry. The
/// audio processing flags are off on purpose — the test should show the real
/// input, not a gated, gain-ridden version of it — and `mixWithOthers` lets the
/// test sound play without stealing the session out from under the capture.
const _recordConfig = RecordConfig(
  encoder: AudioEncoder.pcm16bits,
  sampleRate: 16000,
  numChannels: 1,
  autoGain: false,
  echoCancel: false,
  noiseSuppress: false,
  iosConfig: IosRecordConfig(
    categoryOptions: [
      IosAudioCategoryOption.mixWithOthers,
      IosAudioCategoryOption.allowBluetooth,
    ],
  ),
);

class MediaCheckScreen extends StatefulWidget {
  const MediaCheckScreen({super.key});

  @override
  State<MediaCheckScreen> createState() => _MediaCheckScreenState();
}

class _MediaCheckScreenState extends State<MediaCheckScreen> {
  _CheckMode _mode = _CheckMode.device;

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
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(kGutter, kGutter, kGutter, 4),
              child: SegmentedButton<_CheckMode>(
                segments: const [
                  ButtonSegment(
                    value: _CheckMode.device,
                    icon: Icon(Icons.devices_rounded, size: 18),
                    label: Text('Device'),
                  ),
                  ButtonSegment(
                    value: _CheckMode.callPipeline,
                    icon: Icon(Icons.hub_rounded, size: 18),
                    label: Text('Call pipeline'),
                  ),
                ],
                selected: {_mode},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(kGutter, 0, kGutter, 0),
              child: Text(
                _mode == _CheckMode.device
                    ? 'The raw hardware — lightest path, with a live mic light.'
                    : 'The WebRTC capture path — camera and mute.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: t.mutedForeground),
              ),
            ),
            Expanded(
              // A keyed swap: picking the other mode unmounts this child, whose
              // `dispose` tears its framework down before the other's comes up —
              // which is the whole reason the two never share the audio session.
              child: _mode == _CheckMode.device
                  ? const _DeviceCheck(key: ValueKey('device'))
                  : const _MeetingCheck(key: ValueKey('meeting')),
            ),
          ],
        ),
      ),
    );
  }
}

/// What can be wrong with the camera, kept distinct because the fixes differ.
///
/// A denied permission is fixed in Settings and nowhere else; "no camera on this
/// device" cannot be fixed at all; anything else is worth a retry. Rendering all
/// three as one spinner is the bug `lib/ui/AGENTS.md` warns about.
enum _Problem { permission, noCamera, other }

class _CheckFailure {
  const _CheckFailure(this.problem, this.message);

  /// From the engine's own failure, so the call-pipeline mode draws the same
  /// three-way split as the device mode off one shared type.
  factory _CheckFailure.fromMedia(MediaFailure failure) => _CheckFailure(
        failure.needsSettings ? _Problem.permission : _Problem.other,
        failure.message,
      );

  final _Problem problem;
  final String message;

  /// A refused permission is the one problem fixed in Settings rather than here.
  bool get needsSettings => problem == _Problem.permission;
}

// ---------------------------------------------------------------------------
// Device mode: camera plugin + record. No WebRTC, no audio-session fight.
// ---------------------------------------------------------------------------

class _DeviceCheck extends StatefulWidget {
  const _DeviceCheck({super.key});

  @override
  State<_DeviceCheck> createState() => _DeviceCheckState();
}

class _DeviceCheckState extends State<_DeviceCheck> with WidgetsBindingObserver {
  List<CameraDescription> _cameras = const [];
  CameraController? _camera;
  int _cameraIndex = 0;

  final _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _micSub;
  final _voice = VoiceActivity();

  final _player = AudioPlayer();
  final _rng = Random();

  bool _micLive = true;
  bool _speaker = true;
  bool _videoOn = true;
  bool _hearing = false;

  bool _starting = true;
  _CheckFailure? _failure;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  Future<void> _start() async {
    try {
      _cameras = await availableCameras();
    } on CameraException {
      _cameras = const [];
    }
    try {
      await _player.setReleaseMode(ReleaseMode.stop);
    } on Object catch (error) {
      debugPrint('media-check: could not configure the test-sound player: $error');
    }

    if (_cameras.isEmpty) {
      // No camera is not an error that should hold the mic test hostage.
      if (mounted) {
        setState(() {
          _starting = false;
          _failure =
              const _CheckFailure(_Problem.noCamera, 'No camera on this device.');
        });
      }
      unawaited(_startMeter());
      return;
    }

    _cameraIndex =
        _cameras.indexWhere((c) => c.lensDirection == CameraLensDirection.front);
    if (_cameraIndex < 0) _cameraIndex = 0;

    await _openCamera();
    if (mounted) setState(() => _starting = false);
    unawaited(_startMeter());
  }

  /// Opens the camera at [_cameraIndex] into a fresh controller.
  ///
  /// `enableAudio: false` is the whole point: it keeps the camera off the audio
  /// session so the microphone meter can own it without a fight (see the header).
  Future<void> _openCamera() async {
    if (_cameras.isEmpty) return;
    final controller = CameraController(
      _cameras[_cameraIndex],
      ResolutionPreset.medium,
      enableAudio: false,
    );
    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _camera = controller;
        _failure = null;
      });
    } on CameraException catch (error) {
      await controller.dispose();
      if (mounted) setState(() => _failure = _mapCameraError(error));
    }
  }

  _CheckFailure _mapCameraError(CameraException error) {
    const denied = {
      'CameraAccessDenied',
      'CameraAccessDeniedWithoutPrompt',
      'CameraAccessRestricted',
    };
    if (denied.contains(error.code)) {
      return const _CheckFailure(_Problem.permission, 'Camera permission denied.');
    }
    return _CheckFailure(
        _Problem.other, error.description ?? 'The camera could not start.');
  }

  /// Opens the microphone for the meter and starts feeding [_voice].
  ///
  /// Best-effort: a denied permission or a busy device leaves the light dark and
  /// the rest of the screen working, rather than throwing into the camera path.
  Future<void> _startMeter() async {
    // Idempotent: `_start` runs again on a camera retry, and a second stream on
    // the same recorder would leave the first dangling and the light double-fed.
    if (_micSub != null) return;
    try {
      if (!await _recorder.hasPermission()) return;
      final stream = await _recorder.startStream(_recordConfig);
      _micSub = stream.listen(_onSamples, onError: (Object e) {
        debugPrint('media-check: microphone stream error: $e');
      });
    } on Object catch (error) {
      debugPrint('media-check: could not open the microphone meter: $error');
    }
  }

  /// One chunk of PCM: reduce to a level, let [_voice] decide, redraw only when
  /// the "we can hear you" answer actually flips.
  void _onSamples(Uint8List samples) {
    if (!_micLive) return;
    final flipped = _voice.note(micLevel(samples), DateTime.now());
    if (flipped && mounted) setState(() => _hearing = _voice.speaking);
  }

  Future<void> _setMicLive(bool live) async {
    setState(() {
      _micLive = live;
      if (!live) {
        _voice.silence();
        _hearing = false;
      }
    });
    try {
      if (live) {
        await _recorder.resume();
      } else {
        await _recorder.pause();
      }
    } on Object catch (error) {
      debugPrint(
          'media-check: could not ${live ? 'resume' : 'pause'} the microphone: $error');
    }
  }

  Future<void> _setVideoOn(bool on) async {
    setState(() => _videoOn = on);
    final camera = _camera;
    if (camera == null) return;
    try {
      if (on) {
        await camera.resumePreview();
      } else {
        await camera.pausePreview();
      }
    } on Object catch (error) {
      debugPrint(
          'media-check: could not ${on ? 'resume' : 'pause'} the camera: $error');
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2) return;
    final old = _camera;
    setState(() => _camera = null);
    await old?.dispose();
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    await _openCamera();
    if (!_videoOn) await _camera?.pausePreview();
  }

  void _setSpeaker(bool speaker) => setState(() => _speaker = speaker);

  Future<void> _playTone() async {
    try {
      // Apply the route here so the Speaker/Earpiece choice always wins: the
      // recorder's session may have been the last to set the category, and there
      // is no WebRTC to flap it, so one deliberate set per tap is correct and
      // cheap.
      await AudioPlayer.global.setAudioContext(_deviceToneContext(speaker: _speaker));
      await _player.play(
        BytesSource(chimeWav(variant: _rng.nextInt(variantCount)),
            mimeType: 'audio/wav'),
      );
    } on Object catch (error) {
      debugPrint('media-check: could not play the test sound: $error');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final camera = _camera;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      // iOS takes the camera back when we leave the foreground; let go first so
      // it does not come back a black, throwing preview.
      if (camera != null) {
        _camera = null;
        if (mounted) setState(() {});
        camera.dispose();
      }
    } else if (state == AppLifecycleState.resumed) {
      if (_camera == null && _cameras.isNotEmpty && _failure == null) {
        _openCamera().then((_) async {
          if (!_videoOn) await _camera?.pausePreview();
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_micSub?.cancel());
    unawaited(_recorder.dispose());
    unawaited(_player.dispose());
    unawaited(_camera?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final showControls = !_starting && _failure?.problem != _Problem.permission;
    final frontCamera = _cameras.isNotEmpty &&
        _cameras[_cameraIndex].lensDirection == CameraLensDirection.front;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: kGutter),
      child: Column(
        children: [
          Expanded(
            child: _DevicePreview(
              camera: _camera,
              starting: _starting,
              videoOn: _videoOn,
              micLive: _micLive,
              failure: _failure,
              onRetry: () {
                setState(() {
                  _starting = true;
                  _failure = null;
                });
                _start();
              },
            ),
          ),
          if (showControls) _MicStatus(live: _micLive, hearing: _hearing),
          if (showControls)
            _Controls(
              micLive: _micLive,
              videoOn: _videoOn,
              speaker: _speaker,
              frontCamera: frontCamera,
              hasCamera: _camera != null,
              canSwitch: _cameras.length > 1,
              onToggleMic: () => _setMicLive(!_micLive),
              onToggleVideo: () => _setVideoOn(!_videoOn),
              onSwitchCamera: _switchCamera,
              onToggleSpeaker: () => _setSpeaker(!_speaker),
              onPlayTone: _playTone,
            ),
          const SizedBox(height: kGutter),
        ],
      ),
    );
  }
}

class _DevicePreview extends StatelessWidget {
  const _DevicePreview({
    required this.camera,
    required this.starting,
    required this.videoOn,
    required this.micLive,
    required this.failure,
    required this.onRetry,
  });

  final CameraController? camera;
  final bool starting;
  final bool videoOn;
  final bool micLive;
  final _CheckFailure? failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final controller = camera;
    final showOff =
        !videoOn || controller == null || !controller.value.isInitialized;

    return _previewCard(
      context,
      failure: failure,
      failTitle: 'No camera',
      settingsBody: 'Gather Companion needs the camera. Turn it on in Settings, '
          'then come back.',
      starting: starting,
      startingBody: 'Opening the camera.',
      showOff: showOff,
      offTitle: controller == null ? 'No camera' : 'Camera off',
      offBody: micLive ? 'Your microphone is live.' : 'Your microphone is muted.',
      onRetry: onRetry,
      live: () => _CameraCover(controller: controller!),
    );
  }
}

/// A camera preview scaled to fill its frame rather than letterbox inside it.
///
/// `CameraPreview` reports its size in the sensor's landscape orientation, so on
/// a portrait phone the width and height are swapped before the `BoxFit.cover`
/// does its work — otherwise the preview comes out sideways and squashed.
class _CameraCover extends StatelessWidget {
  const _CameraCover({required this.controller});

  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    final size = controller.value.previewSize;
    if (size == null) return CameraPreview(controller);

    return ClipRect(
      child: SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: size.height,
            height: size.width,
            child: CameraPreview(controller),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Call-pipeline mode: the pre-branch WebRTC check — plain capture, mic/camera/
// switch, no route forcing (that forcing is what lagged the screen).
// ---------------------------------------------------------------------------

class _MeetingCheck extends StatefulWidget {
  const _MeetingCheck({super.key});

  @override
  State<_MeetingCheck> createState() => _MeetingCheckState();
}

class _MeetingCheckState extends State<_MeetingCheck> {
  final _renderer = RTCVideoRenderer();
  late final WebrtcMediaEngine _engine = WebrtcMediaEngine(log: debugPrint);

  StreamSubscription<LocalMediaState>? _sub;
  LocalMediaState _state = const LocalMediaState();
  bool _starting = true;
  bool _rendererReady = false;

  @override
  void initState() {
    super.initState();
    _sub = _engine.states.listen((s) {
      if (mounted) setState(() => _state = s);
    });
    _start();
  }

  Future<void> _start() async {
    // Once only: `_start` runs again on retry, and re-initialising a live renderer
    // throws. The engine's own restart handles a second `startCapture`.
    if (!_rendererReady) {
      await _renderer.initialize();
      _rendererReady = true;
    }
    try {
      // Plain capture, like the pre-branch check: no `prepareAudioSession` and
      // no `setSpeakerOn`. Route forcing on a standalone capture with no SFU
      // transport connected drives the voice-processing reconfiguration loop
      // that lagged the screen. A real call tolerates those calls because its
      // transport is live; a test harness does not.
      await _engine.startCapture();
      _renderer.srcObject = _engine.localStream;
    } on MediaFailure {
      // Already on `_state` through the stream; the screen renders it below.
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    _renderer.srcObject = null;
    _renderer.dispose();
    _engine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final showControls = _state.capturing;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: kGutter),
      child: Column(
        children: [
          Expanded(
            child: _MeetingPreview(
              renderer: _renderer,
              state: _state,
              starting: _starting,
              onRetry: () {
                setState(() => _starting = true);
                _start();
              },
            ),
          ),
          if (showControls) _MicStatus(live: _state.audioEnabled),
          if (showControls)
            _Controls(
              micLive: _state.audioEnabled,
              videoOn: _state.videoEnabled,
              // No route toggle and no test sound: the pre-branch check forced
              // neither, and forcing a route here is what lagged the screen. The
              // speaker flag stays at its unused default.
              frontCamera: _state.frontCamera,
              hasCamera: true,
              canSwitch: _state.hasVideo,
              onToggleMic: () => _engine.setAudioEnabled(!_state.audioEnabled),
              onToggleVideo: () => _engine.setVideoEnabled(!_state.videoEnabled),
              onSwitchCamera: _engine.switchCamera,
              onToggleSpeaker: null,
              onPlayTone: null,
            ),
          const SizedBox(height: kGutter),
        ],
      ),
    );
  }
}

class _MeetingPreview extends StatelessWidget {
  const _MeetingPreview({
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
    final failure = state.failure;

    return _previewCard(
      context,
      failure: failure == null ? null : _CheckFailure.fromMedia(failure),
      failTitle: 'No camera or microphone',
      settingsBody: 'Gather Companion needs the microphone and camera. Turn them '
          'on in Settings, then come back.',
      starting: starting,
      startingBody: 'Opening the microphone and camera.',
      showOff: !state.hasVideo,
      offTitle: state.capturing ? 'Camera off' : 'Not capturing',
      offBody: state.audioEnabled
          ? 'Your microphone is live.'
          : 'Your microphone is muted.',
      onRetry: onRetry,
      live: () => RTCVideoView(
        renderer,
        mirror: state.frontCamera,
        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared bits.
// ---------------------------------------------------------------------------

/// The card the preview and its messages sit in, identical across both modes.
Widget _frame(BuildContext context, Widget child) {
  final t = context.tokens;
  return Container(
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
}

/// The failure → starting → off → live ladder both previews walk, in one place.
///
/// The two modes differ only in their copy and their live child — the shape is
/// identical, and keeping it identical is what stops one mode's permission screen
/// drifting from the other's. Each maps its own state onto one [_CheckFailure]
/// and a handful of strings; the branching lives here.
Widget _previewCard(
  BuildContext context, {
  required _CheckFailure? failure,
  required String failTitle,
  required String settingsBody,
  required bool starting,
  required String startingBody,
  required bool showOff,
  required String offTitle,
  required String offBody,
  required VoidCallback onRetry,
  required Widget Function() live,
}) {
  if (failure != null) {
    final settings = failure.needsSettings;
    return _frame(
      context,
      _Message(
        icon: settings ? Icons.lock_outline_rounded : Icons.videocam_off_outlined,
        title: settings ? 'Permission needed' : failTitle,
        body: settings ? settingsBody : failure.message,
        action: settings ? null : ('Try again', onRetry),
      ),
    );
  }

  if (starting) {
    return _frame(
      context,
      _Message(
        icon: Icons.hourglass_empty_rounded,
        title: 'Starting',
        body: startingBody,
      ),
    );
  }

  if (showOff) {
    return _frame(
      context,
      _Message(
        icon: Icons.videocam_off_outlined,
        title: offTitle,
        body: offBody,
      ),
    );
  }

  return _frame(context, live());
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

/// The microphone status, as a light beside a line of words.
///
/// Two shapes behind one widget, picked by whether a live level is available:
///
///  - **Device mode** passes [hearing] — there is a real meter — so this is a
///    light that comes on when it hears you: live and picking you up (green), live
///    and quiet (grey, "say something"), or muted. The same decision the call's
///    speaking ring makes drives the colour, so a mic that lights
///    [GatherTokens.ok] green here is a mic the room will see light up too.
///  - **Call-pipeline mode** passes `null` — WebRTC gives no local level without a
///    connection, and the loopback that faked one is what froze this screen — so
///    it is honest about what it knows: live (green) or muted, no quiet state.
///
/// Either way, muted says so in words, because a dark light with no explanation
/// reads as a broken one.
class _MicStatus extends StatelessWidget {
  const _MicStatus({required this.live, this.hearing});

  final bool live;

  /// The live meter's answer, or null when there is no meter (call-pipeline). A
  /// null reads as "working" for the colour, so a connected-but-level-less mic is
  /// green rather than stuck on the quiet grey.
  final bool? hearing;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final metered = hearing != null;
    final working = live && (hearing ?? true);
    final colour = !live
        ? (metered ? t.faint : t.mutedForeground)
        : (working ? t.ok : t.mutedForeground);
    final label = !live
        ? 'Microphone muted'
        : metered
            ? (hearing!
                ? 'We can hear you'
                : 'Say something — the light comes on when it hears you')
            : 'Microphone is live — capturing through the call engine';

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: working ? t.ok.withValues(alpha: 0.15) : t.secondary,
            ),
            child: Icon(
              live ? Icons.mic_rounded : Icons.mic_off_rounded,
              size: 22,
              color: colour,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label, style: TextStyle(fontSize: 13, color: colour)),
          ),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.micLive,
    required this.videoOn,
    required this.frontCamera,
    required this.hasCamera,
    required this.canSwitch,
    required this.onToggleMic,
    required this.onToggleVideo,
    required this.onSwitchCamera,
    required this.onToggleSpeaker,
    required this.onPlayTone,
    this.speaker = false,
  });

  final bool micLive;
  final bool videoOn;

  /// Which way the test sound goes. Only read when [onToggleSpeaker] is non-null;
  /// the call pipeline forces no route, hides the toggle, and leaves this at its
  /// unused default.
  final bool speaker;
  final bool frontCamera;
  final bool hasCamera;
  final bool canSwitch;
  final VoidCallback onToggleMic;
  final VoidCallback onToggleVideo;
  final VoidCallback onSwitchCamera;
  final VoidCallback? onToggleSpeaker;

  /// A tap plays a chime out the current route. Null hides the button — the
  /// call pipeline can't play a chime without reconfiguring the AVAudioSession
  /// the engine owns (the old category-thrash), so it leaves the speaker test
  /// to Device mode.
  final VoidCallback? onPlayTone;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    // The label names where a tap sends the sound, not where it is now: the
    // button is a switch, and the brand tint already says when the speaker is
    // the live one.
    final routeLabel = speaker ? 'Earpiece' : 'Speaker';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _Toggle(
              on: micLive,
              onIcon: Icons.mic_rounded,
              offIcon: Icons.mic_off_rounded,
              label: micLive ? 'Mic on' : 'Muted',
              onTap: onToggleMic,
            ),
            _Toggle(
              on: videoOn,
              onIcon: Icons.videocam_rounded,
              offIcon: Icons.videocam_off_rounded,
              label: videoOn ? 'Camera on' : 'Camera off',
              onTap: hasCamera ? onToggleVideo : null,
            ),
            _Toggle(
              on: true,
              onIcon: Icons.cameraswitch_rounded,
              offIcon: Icons.cameraswitch_rounded,
              label: frontCamera ? 'Front' : 'Back',
              onTap: canSwitch ? onSwitchCamera : null,
              tint: t.mutedForeground,
            ),
            // Where the test sound comes out: the loudspeaker wears the brand
            // like a live control, the earpiece the resting grey. Absent when
            // no route is forced (the call pipeline).
            if (onToggleSpeaker != null)
              _Toggle(
                on: speaker,
                onIcon: speaker ? Icons.volume_up_rounded : Icons.phone_in_talk_rounded,
                offIcon: speaker ? Icons.volume_up_rounded : Icons.phone_in_talk_rounded,
                label: routeLabel,
                tint: speaker ? t.brand : t.mutedForeground,
                onTap: onToggleSpeaker,
              ),
          ],
        ),
        if (onPlayTone != null) ...[
          const SizedBox(height: 8),
          // Hear it for yourself: a short chime out of whatever the route above
          // says, so the speaker test needs no second person on the line.
          TextButton.icon(
            onPressed: onPlayTone,
            icon: const Icon(Icons.graphic_eq_rounded, size: 18),
            label: const Text('Play a test sound'),
          ),
        ],
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
