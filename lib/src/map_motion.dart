/// Where bodies actually are, between the tiles the wire reports.
///
/// **Gather's positions are whole tiles.** Measured against a live dump of the
/// office: all 98 `SpaceUser` rows carry `position: {x, y}` as integers, and there is
/// no sub-tile field on the model at all. The desktop client walks people between
/// those tiles itself, and a client that does not gets an office where everybody
/// teleports one tile at a time, four times a second.
///
/// So this is that walk, transcribed rather than invented. From `PlayerEntityV2`:
///
/// ```js
/// preUpdate = (time, delta) => {
///   if (this.isMoving) {
///     this.elapsedMovementTime += delta;
///     const t = Math.min(this.elapsedMovementTime / MOVEMENT_DURATION, 1);
///     x = Phaser.Math.Linear(this.initialMovementX, this.targetX, t);
///     y = Phaser.Math.Linear(this.initialMovementY, this.targetY, t);
///   }
///   this.updatePosition(x, y);
/// }
/// ```
///
/// with `MOVEMENT_DURATION = 1e3/7` and a `distance <= TILE_SIZE * 8` guard past
/// which it calls `teleport()` and snaps instead. Linear, not eased — a walking
/// person does not accelerate.
library;

import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'map_person.dart';

/// One tile, at Gather's walking speed: `1e3/7` ms.
///
/// The same seven the walk cycle runs at, which is not a coincidence — the body
/// advances exactly one frame of the animation per tile it crosses.
const walkStep = Duration(microseconds: 142857);

/// Past eight tiles the client stops sliding and teleports: `distance <= TILE_SIZE
/// * 8` in `setTargetPosition`. It is what keeps a party-mode hop across the office
/// reading as a hop rather than as a body skating over the furniture.
const snapBeyond = 8.0;

/// `SpaceUser.doneMoving` — a body counts as moving for 250ms after its last
/// position change. Used here to tell a step that continues a walk from one that
/// starts a fresh one.
const stillAfter = Duration(milliseconds: 250);

/// The longest a single leg may take. The roster is coalesced at 250ms, so this is
/// that plus slack; beyond it the gap was a pause, not a network hiccup.
const _slowestLeg = Duration(milliseconds: 400);

/// The walk, per body, plus the ticker that drives it.
///
/// A [Listenable] rather than something the screen calls into: the painter already
/// repaints off a merge of the art cache and the viewer transform, so this joins that
/// list and the widget tree never rebuilds for a footstep.
class MapMotion extends ChangeNotifier {
  MapMotion({TickerProvider? vsync, Duration Function()? clock})
      : _clock = clock ?? _wallClock() {
    _ticker = vsync?.createTicker(_frame);
  }

  static Duration Function() _wallClock() {
    final since = Stopwatch()..start();
    return () => since.elapsed;
  }

  final Duration Function() _clock;
  Ticker? _ticker;
  final _walks = <String, _Walk>{};
  bool _talking = false;

  /// Whether to animate at all.
  ///
  /// Off, bodies stand on the tile the wire puts them on. The client does the same
  /// thing for the same reason — its animate-or-teleport test is `… && !prefersReduced
  /// Motion() && …` — so this is honouring `MediaQuery.disableAnimationsOf`, not
  /// degrading for it.
  bool enabled = true;

  /// The clock this frame is being drawn at. Read once per paint, so that a body's
  /// position, its animation frame and its name plate all agree about the moment.
  Duration get now => _clock();

  /// Take the wire's word for where everybody is, and start walking anybody who moved.
  ///
  /// Called from `build`, which is why it does not notify: the frame it would ask for
  /// is the frame already being built.
  void update(Iterable<MapPerson> people) {
    final at = _clock();
    final seen = <String>{};
    _talking = false;

    for (final person in people) {
      seen.add(person.id);
      if (person.speaking) _talking = true;
      final target = Offset(person.x, person.y);
      final walk = _walks[person.id];

      // Somebody we have not drawn before stands where they are. Walking them in
      // from wherever the last person with this slot stood would be a lie.
      if (walk == null) {
        _walks[person.id] = _Walk.still(target, at);
        continue;
      }
      if (walk.to == target) continue;

      final from = walk.at(at);
      final distance = (target - from).distance;
      if (!enabled || distance > snapBeyond) {
        _walks[person.id] = _Walk.still(target, at);
        continue;
      }
      _walks[person.id] = _Walk(
        from: from,
        to: target,
        startedAt: at,
        duration: _leg(distance, gap: at - walk.movedAt, continuing: walk.moving(at)),
      );
    }

    _walks.removeWhere((id, _) => !seen.contains(id));
    _wake();
  }

  /// How long to spend crossing [distance] tiles.
  ///
  /// Gather walks at seven tiles a second and a leg that *starts* a walk is paced at
  /// exactly that. A leg that continues one is paced over the gap that produced it
  /// instead, because the roster is coalesced at 250ms: a body walking without
  /// stopping arrives as bursts of one or two tiles rather than as a step every
  /// 143ms, and animating each burst at the nominal speed leaves it standing still
  /// between the bursts — a limp rather than a walk. The gap is what actually
  /// elapsed, so pacing over it is what joins the bursts back up.
  Duration _leg(double distance, {required Duration gap, required bool continuing}) {
    final pace = walkStep * distance;
    if (!continuing && gap > stillAfter) return pace;
    // Never quicker than Gather walks, and never slower than [_slowestLeg] — except
    // where a burst of three tiles or more already takes longer than that at walking
    // pace, in which case walking pace is the slower of the two and wins.
    final longest = pace > _slowestLeg ? pace : _slowestLeg;
    return Duration(
      microseconds: gap.inMicroseconds.clamp(pace.inMicroseconds, longest.inMicroseconds),
    );
  }

  /// Where to draw somebody at [now]: between the tile they left and the one they
  /// are walking to, in tiles, fractionally.
  Offset positionOf(MapPerson person, Duration now) {
    if (!enabled) return Offset(person.x, person.y);
    return _walks[person.id]?.at(now) ?? Offset(person.x, person.y);
  }

  /// Whether that body is mid-step, and so should be drawn on the walk cycle.
  bool walking(MapPerson person, Duration now) =>
      enabled && (_walks[person.id]?.moving(now) ?? false);

  /// The clock a looping animation runs off, offset per person.
  ///
  /// One shared clock would have a room full of people stepping and talking in
  /// perfect unison, which reads as a chorus line rather than as an office. The
  /// offset is derived from the id, so it is stable across frames and across
  /// reconnects rather than re-rolled every time somebody is redrawn.
  Duration phaseOf(MapPerson person, Duration now) =>
      now + Duration(milliseconds: person.id.hashCode.abs() % 971);

  void _frame(Duration _) {
    notifyListeners();
    // Stops itself the moment the last body lands: an office where nobody is moving
    // or talking costs no frames at all.
    _wake();
  }

  void _wake() {
    final ticker = _ticker;
    if (ticker == null) return;
    final at = _clock();
    final want = enabled && (_talking || _walks.values.any((w) => w.moving(at)));
    if (want && !ticker.isActive) {
      ticker.start();
    } else if (!want && ticker.isActive) {
      ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _ticker = null;
    super.dispose();
  }
}

/// One leg of a walk: where it started, where it is going, and when.
class _Walk {
  _Walk({
    required this.from,
    required this.to,
    required this.startedAt,
    required this.duration,
  });

  _Walk.still(Offset at, Duration when)
      : from = at,
        to = at,
        startedAt = when,
        duration = Duration.zero;

  final Offset from;
  final Offset to;
  final Duration startedAt;
  final Duration duration;

  /// When this body last changed tile, which is what [MapMotion._leg] measures the
  /// gap against.
  Duration get movedAt => startedAt;

  double _progress(Duration now) {
    if (duration <= Duration.zero) return 1;
    return ((now - startedAt).inMicroseconds / duration.inMicroseconds).clamp(0.0, 1.0);
  }

  /// `Phaser.Math.Linear` — a walking person does not ease in.
  Offset at(Duration now) {
    final t = _progress(now);
    return Offset(from.dx + (to.dx - from.dx) * t, from.dy + (to.dy - from.dy) * t);
  }

  bool moving(Duration now) => _progress(now) < 1;
}
