/// Does the microphone work, does the camera work, and do you look right?
///
/// The first thing the media stack needed was somewhere to prove it runs at all
/// on a real device — permissions granted, a capture session opened, frames
/// arriving. That is worth keeping rather than throwing away once calls work: a
/// device check before you join something is a normal thing for a call app to
/// have, and it answers "is it me or is it them" without dragging a colleague
/// into the experiment.
///
/// Nothing here talks to Gather. It opens the hardware, draws it, and lets go.
///
/// ## The renderer's lifetime is the widget's
///
/// `RTCVideoRenderer` holds a native texture. It must be `initialize()`d before
/// use and `dispose()`d after, and its lifetime has to be tied to the widget
/// rather than to the engine — which is why this is a `StatefulWidget` and why
/// `srcObject` is cleared before disposing. Getting that wrong leaks a texture
/// per visit, and the symptom is a slow crawl rather than a crash.
library;

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../src/media/media_engine.dart';
import '../src/media/webrtc_media_engine.dart';
import '../theme/gather_theme.dart';

class MediaCheckScreen extends StatefulWidget {
  const MediaCheckScreen({super.key});

  @override
  State<MediaCheckScreen> createState() => _MediaCheckScreenState();
}

class _MediaCheckScreenState extends State<MediaCheckScreen> {
  final _renderer = RTCVideoRenderer();
  late final WebrtcMediaEngine _engine = WebrtcMediaEngine(log: debugPrint);

  LocalMediaState _state = const LocalMediaState();
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
    try {
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
    // Order matters: drop the texture's reference to the stream before the
    // engine stops the tracks underneath it.
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
        title: const Text('Mic & camera'),
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
              if (_state.capturing) _Controls(engine: _engine, state: _state),
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

class _Controls extends StatelessWidget {
  const _Controls({required this.engine, required this.state});

  final MediaEngine engine;
  final LocalMediaState state;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Row(
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
