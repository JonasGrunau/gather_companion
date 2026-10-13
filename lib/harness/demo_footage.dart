/// Stand-in "video" for the simulator, where there is no camera and so no real
/// WebRTC stream to render.
///
/// The iOS simulator has no capture device, so `getUserMedia` fails and every
/// harness tile would otherwise fall through to the avatar placeholder — leaving
/// nothing to judge how the call layout *cuts* a frame (cover vs contain) or how
/// it zooms. This paints a moving test card into each tile instead: a wide 16:9
/// card with a grid, edge labels and a bouncing dot, so the crop is obvious (the
/// edges a cover-fit eats are the labelled ones) and the pinch-zoom has something
/// to bite on.
///
/// It is wired in only by `main_harness.dart` via [CallScreen.buildTile]; the real
/// app never builds this, and the production tile path is untouched.
library;

import 'package:flutter/material.dart';

import '../ui/call_screen.dart';

/// A [CallTileBuilder] that renders [DemoFootage] for every tile that would carry
/// video — everyone but a self tile with its camera off, which stays an avatar so
/// "you, camera off" still reads honestly.
Widget demoFootageTile(BuildContext context, CallTile tile) {
  final showVideo = !tile.isSelf || tile.videoLive;
  return TileFrame(
    tile: tile,
    video: showVideo
        ? DemoFootage(seed: tile.id, mirror: tile.isSelf, label: tile.label)
        : null,
  );
}

/// A moving test card, fit to cover its tile and wrapped for pinch-zoom — the
/// same cover-and-zoom treatment a real spotlight tile gives an `RTCVideoView`, so
/// what you see cut and scaled here is what the layout does to a face.
class DemoFootage extends StatefulWidget {
  const DemoFootage({
    super.key,
    required this.seed,
    this.mirror = false,
    this.label = '',
  });

  /// Drives the card's colour, so each person's tile is a different hue and the
  /// grid of them reads as distinct feeds rather than one repeated pattern.
  final String seed;

  /// Mirrors the card, matching the self-view's mirrored camera.
  final bool mirror;

  /// Drawn large across the card, so a tile is identifiable even cropped hard.
  final String label;

  @override
  State<DemoFootage> createState() => _DemoFootageState();
}

class _DemoFootageState extends State<DemoFootage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  )..repeat();

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  /// The camera shapes a real room mixes — a widescreen laptop, a phone held
  /// upright, an old 4:3 webcam, a square crop. Picked by [seed] so each person
  /// keeps one, and the layout is seen cutting every aspect, not just 16:9.
  static const _aspects = <Size>[
    Size(1600, 900), // 16:9 widescreen
    Size(900, 1600), // 9:16 phone upright
    Size(1200, 900), // 4:3 webcam
    Size(900, 1200), // 3:4 phone-ish
    Size(1080, 1080), // 1:1 square
  ];

  /// Cover (crop the long edge) vs contain (letterbox, bars on the short edge).
  /// The app's own Fit/Fill button only shows over a real video stream, which the
  /// simulator cannot make — so the toggle lives here, on a double-tap, to make
  /// the letterbox behaviour reachable on a bare sim.
  bool _contain = false;

  @override
  Widget build(BuildContext context) {
    // A source card in this person's camera shape, scaled to cover or letterbox
    // the tile and made zoomable — the behaviours the user wants to eyeball,
    // across a mix of aspects.
    final shape = _aspects[widget.seed.hashCode.abs() % _aspects.length];
    final card = SizedBox(
      width: shape.width,
      height: shape.height,
      child: AnimatedBuilder(
        animation: _t,
        builder: (context, _) => CustomPaint(
          painter: _TestCardPainter(
            phase: _t.value,
            hue: (widget.seed.hashCode % 360).toDouble().abs(),
            label: widget.label,
          ),
        ),
      ),
    );
    final fitted = ColoredBox(
      // The letterbox bars: black shows through wherever a contained frame does
      // not reach, top-and-bottom or side, exactly as a real video would bar.
      color: Colors.black,
      child: ClipRect(
        child: SizedBox.expand(
          child: FittedBox(
            fit: _contain ? BoxFit.contain : BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: card,
          ),
        ),
      ),
    );
    final zoomable =
        InteractiveViewer(minScale: 1, maxScale: 5, child: fitted);
    final mirrored = widget.mirror
        ? Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()..scaleByDouble(-1.0, 1.0, 1.0, 1.0),
            child: zoomable,
          )
        : zoomable;
    // Double-tap toggles cover/letterbox. Behaviour.opaque so the whole tile is
    // the target; InteractiveViewer keeps the drag/pinch, which it does not use
    // double-tap for.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: () => setState(() => _contain = !_contain),
      child: mirrored,
    );
  }
}

class _TestCardPainter extends CustomPainter {
  _TestCardPainter({
    required this.phase,
    required this.hue,
    required this.label,
  });

  /// 0..1 loop, drives the bouncing dot.
  final double phase;
  final double hue;
  final String label;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = HSVColor.fromAHSV(1, hue, 0.55, 0.30).toColor();
    final line = HSVColor.fromAHSV(1, hue, 0.35, 0.75).toColor();
    canvas.drawRect(Offset.zero & size, Paint()..color = bg);

    // A grid, so a crop or a zoom is measurable by eye.
    final grid = Paint()
      ..color = line.withValues(alpha: 0.4)
      ..strokeWidth = 2;
    for (var i = 1; i < 8; i++) {
      final x = size.width * i / 8;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var i = 1; i < 5; i++) {
      final y = size.height * i / 5;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    // Edge labels: a cover-fit eats the top and bottom of a tall tile and the
    // sides of a wide one, so naming the edges makes the crop legible.
    _edge(canvas, 'TOP', Offset(size.width / 2, 36), line);
    _edge(canvas, 'BOTTOM', Offset(size.width / 2, size.height - 36), line);
    _edge(canvas, 'LEFT', Offset(70, size.height / 2), line);
    _edge(canvas, 'RIGHT', Offset(size.width - 70, size.height / 2), line);

    // A bright band sweeping left→right, so the motion reads at a glance even on
    // a thumbnail — bigger and faster than the dot alone.
    final sweepX = size.width * ((phase * 1.0) % 1);
    canvas.drawRect(
      Rect.fromLTWH(sweepX - size.width * 0.04, 0, size.width * 0.08, size.height),
      Paint()..color = Colors.white.withValues(alpha: 0.12),
    );

    // A bouncing dot, so the feed is unmistakably moving rather than a still.
    final dx = size.width * (0.1 + 0.8 * _tri(phase));
    final dy = size.height * (0.15 + 0.7 * _tri((phase + 0.33) % 1));
    canvas.drawCircle(
      Offset(dx, dy),
      28,
      Paint()..color = HSVColor.fromAHSV(1, (hue + 180) % 360, 0.7, 0.95).toColor(),
    );

    // The name, big, dead centre.
    _text(canvas, label, size.center(Offset.zero), line.withValues(alpha: 0.9),
        64, FontWeight.w700);

    // A running frame counter, bottom-left, so "live" is unambiguous — a still
    // would freeze it.
    final frame = (phase * 120).floor().toString().padLeft(3, '0');
    _text(canvas, '#$frame', Offset(70, size.height - 80),
        line.withValues(alpha: 0.9), 28, FontWeight.w700);
  }

  /// Triangle wave 0..1..0, for a bounce that turns around rather than jumping.
  double _tri(double t) => t < 0.5 ? t * 2 : 2 - t * 2;

  void _edge(Canvas canvas, String s, Offset at, Color c) =>
      _text(canvas, s, at, c, 30, FontWeight.w600);

  void _text(Canvas canvas, String s, Offset at, Color c, double size,
      FontWeight weight) {
    if (s.isEmpty) return;
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(color: c, fontSize: size, fontWeight: weight),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_TestCardPainter old) =>
      old.phase != phase || old.hue != hue || old.label != label;
}
