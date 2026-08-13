/// A thumb-sized pad for walking your own avatar around the office.
///
/// The map was a thing to look at; this is what makes it a thing to be in. Gather's
/// movement API is one tile per call (`walk.dart` has the rest of that story), so the
/// only question left for the interface is how a thumb says "keep going that way" and
/// how it changes its mind.
///
/// ## Why it is one gesture and not four buttons
///
/// Four buttons would be four separate presses, and going round a corner would mean
/// lifting a thumb, finding the next button and pressing again — a stutter at exactly
/// the moment you are trying to steer. So the whole pad is one pointer: [Listener]
/// takes the press and every move that follows, and the direction is recomputed from
/// wherever the thumb has slid to. Corners are a roll of the thumb, and the walk never
/// stops for one.
///
/// It still has to *look* like four buttons, because that is what says it can be
/// pressed. So each direction owns a full quarter of the disc, drawn to the same
/// diagonals the hit test splits on — what you aim at is exactly what you get, and
/// there is no gap between the quarters where a press could land on nothing.
///
/// The hub in the middle is what makes stopping possible without lifting: slide back
/// to it and the walk ends. It is drawn rather than merely reserved, because a dead
/// zone you cannot see is a dead zone you find by accident.
///
/// ## Why it is translucent
///
/// It sits over the office, and the office is the thing being looked at — the pad
/// covers the bottom of the floor plan whether or not it is being used, so it is drawn
/// as glass with a rim rather than as a control panel.
///
/// ## Why no arrow is ever greyed out
///
/// An earlier version dimmed the directions that led into a wall. It read as a fault:
/// the arrows flickered between live and dead as you walked past doorways, and a
/// control that keeps changing which parts of it work is one you stop trusting. A wall
/// is not the pad's news to break — you find it the way you find one in any game,
/// by walking into it and stopping. `Walk` declines the step and the avatar simply
/// does not move.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/gather_theme.dart';

/// How wide the pad is.
///
/// Each quarter is therefore about 100 points across at its widest — a target you can
/// hit without looking at it, which is the point of a control you use while watching
/// something else on the same screen.
const _size = 200.0;

/// The still middle, as a fraction of the radius.
const _hub = 0.28;

/// Where an arrow sits along its quarter, as a fraction of the radius.
const _glyph = 0.63;

/// How solid a quarter is, resting and pressed.
///
/// The same colour both times — pressed is a step of opacity, not a different paint.
/// The brand blue was tried first and made the pad look like it was reporting
/// something rather than being pushed; a heavier dark was tried after that and read as
/// a hole cut in the disc. The gap between these two is deliberately small: the whole
/// signal needed is "this one, not the other three", and the arrow coming up to full
/// strength at the same moment carries most of it.
const _rest = 0.44;
const _pressed = 0.54;

/// The four quarters, each named by the direction it walks and the angle it centres
/// on. Zero is due east and angles run clockwise, as they do everywhere on a canvas
/// whose y grows downwards.
const _quarters = <({String direction, double angle, IconData icon})>[
  (direction: 'Right', angle: 0, icon: Icons.keyboard_arrow_right_rounded),
  (direction: 'Down', angle: math.pi / 2, icon: Icons.keyboard_arrow_down_rounded),
  (direction: 'Left', angle: math.pi, icon: Icons.keyboard_arrow_left_rounded),
  (direction: 'Up', angle: -math.pi / 2, icon: Icons.keyboard_arrow_up_rounded),
];

class DPad extends StatefulWidget {
  const DPad({
    super.key,
    required this.onPress,
    required this.onRelease,
    this.size = _size,
  });

  /// A thumb is pushing this way. Called again when it changes to another direction,
  /// and not again while it stays on the same one.
  final void Function(String direction) onPress;

  /// The thumb has lifted, or slid back to the hub.
  final VoidCallback onRelease;

  final double size;

  @override
  State<DPad> createState() => _DPadState();
}

class _DPadState extends State<DPad> {
  String? _held;

  /// Which quarter a touch at [local] is asking for, or null for the hub.
  String? _directionAt(Offset local) {
    final centre = widget.size / 2;
    final dx = local.dx - centre;
    final dy = local.dy - centre;
    if (dx * dx + dy * dy < (centre * _hub) * (centre * _hub)) return null;
    // The diagonals split evenly between the two quarters they lie between, which is
    // both what the painter draws and what makes a thumb rolling from one to the next
    // hand over exactly where it looks like it should.
    if (dx.abs() > dy.abs()) return dx > 0 ? 'Right' : 'Left';
    return dy > 0 ? 'Down' : 'Up';
  }

  void _to(String? direction) {
    if (direction == _held) return;
    setState(() => _held = direction);
    if (direction == null) {
      widget.onRelease();
      return;
    }
    HapticFeedback.selectionClick();
    widget.onPress(direction);
  }

  void _lift() {
    if (_held == null) return;
    setState(() => _held = null);
    widget.onRelease();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) => _to(_directionAt(event.localPosition)),
      onPointerMove: (event) => _to(_directionAt(event.localPosition)),
      onPointerUp: (_) => _lift(),
      onPointerCancel: (_) => _lift(),
      child: CustomPaint(
        painter: _PadPainter(held: _held, tokens: t),
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: Stack(
            children: [
              for (final quarter in _quarters)
                Align(
                  alignment: Alignment(
                    math.cos(quarter.angle) * _glyph,
                    math.sin(quarter.angle) * _glyph,
                  ),
                  child: _Arrow(
                    direction: quarter.direction,
                    icon: quarter.icon,
                    held: _held == quarter.direction,
                    // The pad is one pointer, so this is here for a screen reader
                    // rather than for a finger: a semantic tap cannot be held, and one
                    // step is the honest thing for it to mean.
                    onTap: () {
                      widget.onPress(quarter.direction);
                      widget.onRelease();
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow({
    required this.direction,
    required this.icon,
    required this.held,
    required this.onTap,
  });

  final String direction;
  final IconData icon;
  final bool held;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Semantics(
      button: true,
      label: 'Walk ${direction.toLowerCase()}',
      onTap: onTap,
      child: Icon(
        icon,
        size: 34,
        // The plate goes dark under a press, so the arrow on it comes up to full
        // strength — the contrast moves in both directions at once and the quarter
        // reads as pressed without being painted a different colour.
        color: held ? t.foreground : t.foreground.withValues(alpha: 0.85),
      ),
    );
  }
}

/// The disc: four quarters and a hub, with the held quarter filled.
class _PadPainter extends CustomPainter {
  const _PadPainter({required this.held, required this.tokens});

  final String? held;
  final GatherTokens tokens;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    final hub = radius * _hub;
    final rim = Rect.fromCircle(center: centre, radius: radius);
    final inner = Rect.fromCircle(center: centre, radius: hub);

    final quiet = tokens.card.withValues(alpha: _rest);
    final lit = tokens.card.withValues(alpha: _pressed);
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = tokens.border.withValues(alpha: 0.7);

    // Edge to edge: each quarter's diagonal *is* its neighbour's, so the four meet
    // along a shared line and the disc has no gaps in it. The seam is the stroke drawn
    // over that line by both of them, which is a divider rather than a hole.
    for (final quarter in _quarters) {
      final start = quarter.angle - math.pi / 4;
      const sweep = math.pi / 2;
      final path = Path()
        ..moveTo(centre.dx + hub * math.cos(start), centre.dy + hub * math.sin(start))
        ..lineTo(
          centre.dx + radius * math.cos(start),
          centre.dy + radius * math.sin(start),
        )
        ..arcTo(rim, start, sweep, false)
        ..arcTo(inner, start + sweep, -sweep, false)
        ..close();
      canvas.drawPath(
        path,
        Paint()..color = held == quarter.direction ? lit : quiet,
      );
      canvas.drawPath(path, edge);
    }

    // Drawn last and solid: the hub is where a thumb goes to stop, so it has to read
    // as a thing rather than as the hole in the middle of the quarters.
    canvas.drawCircle(centre, hub, Paint()..color = tokens.background.withValues(alpha: 0.5));
    canvas.drawCircle(centre, hub, edge);
  }

  @override
  bool shouldRepaint(_PadPainter old) => old.held != held || old.tokens != tokens;
}
