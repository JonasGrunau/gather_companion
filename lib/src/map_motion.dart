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
///
/// ## And the not-walk
///
/// That guard is a *guess*, and for our own hops it is a guess we do not have to
/// make. Party mode teleports this avatar four times a second and tells us so
/// ([noteTeleport]), which matters because the wire cannot be relied on to make a
/// hop look like one: the roster is coalesced over 250ms and positions arrive
/// component-wise, so one teleport can reach here as a short move, or two, that are
/// indistinguishable from somebody walking. Drawn as a walk, a hop across the office
/// becomes a body gliding slowly over the furniture — which is the bug this half of
/// the file exists to fix.
///
/// So a known teleport pins the destination for [teleportPin] and draws the leaving
/// as an effect rather than as travel: the old body dissolves where it stood while
/// the new one fades and grows into place. Everybody else still gets the client's own
/// eight-tile test, which is the best available answer for a hop we were not told
/// about.
library;

import 'dart:math' as math;
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

/// How long the body that left lingers where it was, dissolving.
///
/// The whole effect has to fit inside party mode's `hopInterval` — 250ms, four hops
/// a second — or a running party stacks each teleport on top of the last one and the
/// office fills with half-faded copies of the same person. So the arrival runs
/// *alongside* the departure rather than after it, and 180ms is the longer of the
/// two: the moment the ghost is gone, the next hop is free to start.
const teleportOut = Duration(milliseconds: 180);

/// How long the arriving body takes to appear.
///
/// Shorter than the dissolve on purpose. A teleport should read as "already there,
/// still catching up with itself" rather than as a crossfade between two places.
const teleportIn = Duration(milliseconds: 140);

/// How long a destination we put somebody on outranks the roster.
///
/// A teleport is the one move this app knows about before Gather confirms it — party
/// mode sent it — and for a moment that knowledge is better than the wire's. The
/// roster is coalesced over 250ms and positions arrive component-wise (`/position/x`
/// and `/position/y` are separate patches), so the tiles that follow a hop can name
/// somewhere the body never really stood. Drawn literally that is a walk, which is
/// exactly the slow glide this replaces.
///
/// The same 400ms as [_slowestLeg], for the same reason: one coalescing window plus
/// slack. When it runs out Gather wins, unconditionally — the same deference
/// `Walk.noteRoster` pays with its optimistic tiles, and for the same reason. Being
/// briefly right is worth it; being permanently wrong about where somebody is
/// standing is not.
const teleportPin = Duration(milliseconds: 400);

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

  /// Teleports currently being drawn, by person. Pruned as they finish.
  final _flashes = <String, _Flash>{};

  /// Destinations that outrank the roster, and until when. See [teleportPin].
  final _pins = <String, ({Offset to, Duration until})>{};

  /// The last hop sequence handed to [noteTeleport], so a rebuild cannot replay it.
  int _played = 0;

  /// Whether [noteTeleport] has been called at all yet. See it for why.
  bool _synced = false;

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

      // A tile we put them on ourselves outranks the wire for a moment. See
      // [teleportPin]: the roster that follows a hop can name tiles the body never
      // stood on, and following those is what draws a teleport as a walk.
      final pin = _pins[person.id];
      if (pin != null) {
        if (target == pin.to) {
          _pins.remove(person.id); // Gather agrees; there is nothing left to defend.
        } else if (at < pin.until) {
          continue;
        } else {
          _pins.remove(person.id); // Out of time. Gather is right and we are wrong.
        }
      }

      if (walk.to == target) continue;

      final from = walk.at(at);
      final distance = (target - from).distance;
      if (!enabled || distance > snapBeyond) {
        // Past [snapBeyond] a body did not travel, it teleported — the same test the
        // client makes before calling `teleport()`. Our own hops arrive through
        // [teleported] and are known rather than inferred; this is how everybody
        // else's look right too, including a colleague running party mode from their
        // own phone.
        if (enabled) _flashes[person.id] = _Flash(from: from, startedAt: at);
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
    _flashes.removeWhere((id, _) => !seen.contains(id));
    _pins.removeWhere((id, _) => !seen.contains(id));
    _wake();
  }

  /// A hop this app fired, from `AppState.lastTeleport`. Called from `build`.
  ///
  /// Deduped on the sequence number rather than on the coordinates: a party can hop
  /// to the same tile twice and a rebuild can happen for reasons that have nothing to
  /// do with movement, and neither should replay an effect.
  ///
  /// Whatever is already there on the *first* call is history rather than news. A map
  /// opened after a party has run would otherwise draw its last hop as though it had
  /// just happened — pinning a body to a tile it left minutes ago, for as long as
  /// [teleportPin] lasts. The cost is that a map opened in the middle of a party sits
  /// out one hop, which is 250ms of nobody noticing.
  void noteTeleport(({String id, double x, double y, int seq})? hop) {
    final first = !_synced;
    _synced = true;
    if (hop == null || hop.seq == _played) return;
    _played = hop.seq;
    if (first) return;
    teleported(hop.id, Offset(hop.x, hop.y));
  }

  /// Put somebody on a tile *now*, and draw the leaving of the old one.
  ///
  /// The difference between this and letting [update] work it out from the roster is
  /// the whole point: this is a teleport because we know it is, not because the body
  /// happened to move more than [snapBeyond] tiles in one roster.
  void teleported(String id, Offset to) {
    final at = _clock();
    final from = _walks[id]?.at(at);
    _walks[id] = _Walk.still(to, at);
    _pins[id] = (to: to, until: at + teleportPin);

    // Somebody we have never drawn has nowhere to have left from, and a ghost on the
    // tile they are standing on is a body dissolving for no reason.
    if (enabled && from != null && from != to) {
      _flashes[id] = _Flash(from: from, startedAt: at);
    }
    _wake();
  }

  /// The teleport [person] is in the middle of, or null if they are simply standing.
  ///
  /// One lookup per body per frame, and the painter needs all four numbers at once:
  /// where to leave the ghost, how solid it still is, and how far along the arriving
  /// body is in fading and growing back to itself.
  ({Offset ghostAt, double ghostAlpha, double alpha, double scale})? flashOf(
    MapPerson person,
    Duration now,
  ) {
    if (!enabled) return null;
    final flash = _flashes[person.id];
    if (flash == null || !flash.playing(now)) return null;
    final arrived = flash.arrival(now);
    return (
      ghostAt: flash.from,
      ghostAlpha: flash.ghostAlpha(now),
      alpha: arrived,
      // Not from nothing: a body scaled from zero reads as a bubble popping rather
      // than as somebody arriving.
      scale: 0.7 + 0.3 * arrived,
    );
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
    if (!continuing && gap > stillAfter) return walkStep * distance;

    // The gap, and never longer than it. This used to insist a leg took at least
    // walking pace, and that is the bug it was: a burst of three tiles takes 429ms at
    // walking pace while the next roster lands in 250ms, so the drawn body finished
    // 1.75 tiles behind and started the next leg from there. Over a run of bursts the
    // lag compounds — measured on the arithmetic: four rosters into a body moving
    // three tiles at a time, the wire says 12 and the map draws 5.25 — and what that
    // looks like is a body gliding slowly towards somewhere it arrived seconds ago.
    // Movement measured over 110 seconds of a real space arrives one tile per patch,
    // so how far somebody got in a window is a *fact*, and drawing it slower than it
    // happened is not caution, it is a body that never catches up.
    //
    // [_slowestLeg] still caps it, for a gap that was a pause rather than a stride.
    return Duration(
      microseconds:
          gap.inMicroseconds.clamp(walkStep.inMicroseconds, _slowestLeg.inMicroseconds),
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
    final at = _clock();
    // Every frame, which is also the only place they are cleaned up: a flash is over
    // when nothing is asking to draw it.
    _flashes.removeWhere((_, f) => !f.playing(at));

    final ticker = _ticker;
    if (ticker == null) return;
    final want = enabled &&
        (_talking || _walks.values.any((w) => w.moving(at)) || _flashes.isNotEmpty);
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

/// One teleport being drawn: the tile somebody left, and when they left it.
///
/// Where they *went* is not here — that is their walk, which is already standing on
/// it. This is only the part of a teleport that has no position of its own.
class _Flash {
  _Flash({required this.from, required this.startedAt});

  final Offset from;
  final Duration startedAt;

  double _t(Duration now, Duration span) =>
      ((now - startedAt).inMicroseconds / span.inMicroseconds).clamp(0.0, 1.0);

  /// The body that left, going. Quicker than linear at the start, so that most of
  /// the ghost's life is spent faint — a copy of somebody at half opacity in the
  /// middle of the office reads as a second person, and only briefly as a memory.
  double ghostAlpha(Duration now) {
    final left = 1 - _t(now, teleportOut);
    return left * math.sqrt(left);
  }

  /// The body that arrived, coming. Eased out: it lands and settles rather than
  /// creeping up to full size.
  double arrival(Duration now) {
    final left = 1 - _t(now, teleportIn);
    return 1 - left * left * left;
  }

  /// [teleportOut] outlasts [teleportIn], so the ghost is what ends the effect.
  bool playing(Duration now) => now - startedAt < teleportOut;
}
