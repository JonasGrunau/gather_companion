/// Driving your own avatar from the phone, one tile at a time.
///
/// The `move` action is the whole of Gather's movement API — `{direction}`, one tile
/// per call — and its body on the model is three lines with no check in it:
///
/// ```js
/// const e = new Direction(A.direction).toPositionDelta();
/// const g = new Position({x: this.x + e.x, y: this.y + e.y});
/// this.direction = new Direction(A.direction);
/// this.setPosition(g, {map: ..., prevPosition: this.position})
/// ```
///
/// So everything that makes movement feel like movement lives on the client, and this
/// is that half of it. Two problems, and they are the whole file.
///
/// ## Knowing where you are
///
/// Whether a step is legal depends on the tile you are standing on, and this cannot
/// read that off the roster: positions arrive coalesced over 250ms while a walk runs
/// at seven tiles a second, so by the time Gather confirms the tile you are on, you
/// asked to leave it two steps ago. Checking collision against a stale tile means
/// walking into the first wall you meet.
///
/// So the tile is tracked here, and the roster corrects it rather than supplying it —
/// the same optimism the client applies (`optimistic: true` on the action itself).
/// [noteRoster] keeps every tile stepped onto and not yet seen confirmed, and treats
/// an arriving position three ways:
///
///  * **it is one we claimed** — the steps up to it have landed; drop them and keep
///    believing the rest, which are still in flight.
///  * **it is the one we are standing on** — the same case; the list empties.
///  * **it is somewhere we never claimed to be** — a step was dropped, or the desktop
///    client moved, or party mode hopped. Gather is right and this is wrong.
///
/// That last branch is what makes a phone D-pad safe to share an avatar with a laptop.
///
/// ## Not walking through the office
///
/// [SpaceMap.canStep] is the rule and it is transcribed rather than invented; see
/// `space_map.dart`. This applies it before every step and simply declines the ones
/// that fail. A refused step is not an error worth showing — it is a wall — so it
/// stops the avatar and nothing else.
///
/// **No map, no walking.** A step sent without one is a step nobody checked, and the
/// consequence is not a glitch: the office footprint is 96×52 of a 124×82 grid, and
/// the emptiness around it is walkable as far as the game server is concerned.
library;

import 'dart:async';

import 'direct_collector.dart';
import 'game_protocol.dart';
import 'space_map.dart';

/// How long one tile takes, and so how fast a held button repeats.
///
/// `MOVEMENT_DURATION = 1e3/7` — the walk the client animates between two tiles.
/// Stepping faster than this outruns the animation, and the avatar skates.
const walkStep = Duration(microseconds: 142857);

/// How long a single hold may last before it is dropped.
///
/// A finger cannot get lost, but an app can: backgrounded mid-press, or a pointer
/// cancelled by a system gesture that never sends the up event. Thirty seconds is 210
/// tiles, well past any real hold, and it is the difference between a control and a
/// key stuck down in somebody's workspace.
const maxHold = Duration(seconds: 30);

/// How many unconfirmed steps to remember.
///
/// Two seconds of walking. Past that the roster has had six chances to say something
/// and the oldest entries are no longer evidence of anything.
const _maxPending = 16;

/// One step's worth of state, held so the D-pad can be a dumb button.
class Walk {
  Walk({
    required DirectCollector? Function() collector,
    required SpaceMap? Function() map,
    void Function(String)? log,
    /// Called when a route stops running, for whatever reason. See [release].
    void Function()? onRouteEnded,
    this.interval = walkStep,
    this.holdLimit = maxHold,
    // Test seam. Production uses the wall clock.
    DateTime Function()? now,
        // Assigned the long way round because a named parameter cannot be a private
        // initializing formal.
        // ignore: prefer_initializing_formals
  })  : _collector = collector,
        // ignore: prefer_initializing_formals
        _map = map,
        _log = log ?? _noop,
        // ignore: prefer_initializing_formals
        _onRouteEnded = onRouteEnded,
        _now = now ?? DateTime.now;

  static void _noop(String _) {}

  /// Looked up per step rather than held: both are replaced whenever the app
  /// reconnects, and a stale collector is a step into a dead socket.
  final DirectCollector? Function() _collector;
  final SpaceMap? Function() _map;
  final void Function(String) _log;
  final void Function()? _onRouteEnded;
  final Duration interval;
  final Duration holdLimit;
  final DateTime Function() _now;

  Timer? _timer;
  String? _direction;
  DateTime? _startedAt;

  /// Where we believe we are standing.
  int? _x;
  int? _y;

  /// Tiles stepped onto and not yet confirmed by a roster, oldest first. The last is
  /// always where we believe we are.
  final _pending = <({int x, int y})>[];

  /// The tiles left to walk through, nearest first, or empty when nothing is routed.
  ///
  /// Held as tiles rather than as directions on purpose. The roster is allowed to
  /// correct us mid-route — that is the whole point of [noteRoster] — and a list of
  /// directions applied from a tile we turned out not to be standing on walks the
  /// rest of the route somewhere nobody asked for. Tiles re-derive the direction
  /// from wherever we actually are, and can tell when the answer is nonsense.
  final _route = <({int x, int y})>[];

  /// Which way the finger is pushing, or null when nothing is held.
  String? get direction => _direction;

  bool get walking => _timer != null;

  /// Whether a tapped destination is being walked to, as opposed to a held D-pad.
  ///
  /// Its own flag rather than `_route.isNotEmpty`: the last step of a route empties
  /// the list and *then* stops the walk, so the list is already empty by the time
  /// anything gets to ask why.
  bool get onRoute => _routing;
  bool _routing = false;

  /// The tile this believes the avatar is on, which during a walk is ahead of the
  /// roster. Null until a roster has said once.
  ({int x, int y})? get at => _x == null ? null : (x: _x!, y: _y!);

  /// Start walking, or turn a walk that is already running.
  ///
  /// The first step goes immediately: waiting out a tick before anything moves reads
  /// as the button having missed the press.
  void press(String direction) {
    if (!moveDirections.contains(direction)) return;
    // A held direction outranks a route, always. Somebody reaching for the pad while
    // their avatar is walking itself somewhere has changed their mind, and two things
    // stepping one avatar would fight — which is the same reason party mode lives on
    // the phone rather than on the bridge.
    if (_routing) {
      _routing = false;
      _route.clear();
      _onRouteEnded?.call();
    }
    if (_direction == direction && _timer != null) return;

    _direction = direction;
    _startedAt ??= _now();
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => step());
    step();
  }

  /// Walk a route to its end, the way a double-click on the floor does on the desktop.
  ///
  /// [route] is what [SpaceMap.routeTo] returns — every tile including the one being
  /// stood on now. Replaces whatever was being walked before, because tapping a second
  /// destination means the second one.
  ///
  /// The desktop client re-runs its pathfinder on every tick and takes `moveRoute[1]`,
  /// which is how it copes with the floor changing underneath a walk. This walks the
  /// route it was given and stops the moment that route stops making sense — see
  /// [step]. Cheaper, and the recovery is the same one either way: tap again.
  void follow(List<({int x, int y})> route) {
    _route
      ..clear()
      ..addAll(route);
    // The tile we are already on is not a step.
    if (_route.isNotEmpty && _route.first.x == _x && _route.first.y == _y) {
      _route.removeAt(0);
    }
    if (_route.isEmpty) return;

    _routing = true;
    _direction = null;
    _startedAt = _now();
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => step());
    step();
  }

  /// Stop. Idempotent, because a pointer can be cancelled twice.
  void release() {
    // A route ends by itself — on arrival, on a wall, on a roster that moved us — and
    // the screen has a control whose whole label depends on whether one is running.
    // Without this it would keep saying "Stop" until the next roster happened to wake
    // the tree, which is up to a quarter of a second of a button that lies.
    final wasOnRoute = _routing;
    _routing = false;
    _route.clear();
    if (_timer == null && _direction == null) {
      if (wasOnRoute) _onRouteEnded?.call();
      return;
    }
    _timer?.cancel();
    _timer = null;
    _direction = null;
    _startedAt = null;
    if (wasOnRoute) _onRouteEnded?.call();
  }

  Future<void> dispose() async => release();

  /// One step, or why there was not one.
  ///
  /// Public because it is the unit of work and the timer does nothing but call it,
  /// which is what lets a test walk somebody across a room without waiting out a
  /// real second per seven tiles.
  ({bool ok, String? detail}) step() {
    final held = _direction;
    if (held == null && _route.isEmpty) return (ok: false, detail: 'nothing is held');

    final startedAt = _startedAt;
    // Only a held direction can be held too long. A route is a finite list that ends
    // itself, and the longest one this floor can produce is within a tile or two of
    // the limit — dropping it at 30 seconds would abandon the walk almost home.
    if (held != null && startedAt != null && _now().difference(startedAt) >= holdLimit) {
      _log('walk: dropped a hold that lasted ${holdLimit.inSeconds}s');
      release();
      return (ok: false, detail: 'held too long');
    }

    final collector = _collector();
    if (collector == null) return (ok: false, detail: 'not connected to Gather');

    final x = _x, y = _y;
    if (x == null || y == null) {
      return (ok: false, detail: 'still working out where you are');
    }

    final map = _map();
    if (map == null) return (ok: false, detail: 'still reading the floor plan');

    final direction = held ?? _towards(x, y);
    // The route no longer starts where we are standing: a roster corrected us onto a
    // tile it does not pass through, or the desktop client moved this same avatar.
    // Everything after this point would be walked from the wrong place, so stop.
    if (direction == null) {
      release();
      return (ok: false, detail: 'lost the way there');
    }

    if (!map.canStep(x, y, direction)) {
      // A refused step is a wall, and for a held direction that is all it is. For a
      // route it is somebody having moved a chair into it, which invalidates the rest.
      if (held == null) release();
      return (ok: false, detail: 'blocked');
    }

    final sent = collector.move(direction: direction);
    if (!sent.ok) {
      if (held == null) release();
      return sent;
    }

    // Believed only once it is actually on the wire, so a socket that refused it does
    // not leave this walking on ahead of an avatar that never moved.
    final delta = stepOf(direction)!;
    _x = x + delta.dx;
    _y = y + delta.dy;
    _pending.add((x: _x!, y: _y!));
    if (_pending.length > _maxPending) _pending.removeAt(0);

    if (held == null) {
      _route.removeAt(0);
      if (_route.isEmpty) release();
    }
    return (ok: true, detail: null);
  }

  /// The way to the next tile on the route, or null when it is not next to us.
  String? _towards(int x, int y) {
    final next = _route.first;
    for (final direction in moveDirections) {
      final step = stepOf(direction)!;
      if (x + step.dx == next.x && y + step.dy == next.y) return direction;
    }
    return null;
  }

  /// What Gather says about where we are. See the library doc.
  void noteRoster(Roster roster) {
    RosterRow? me;
    for (final row in roster.rows) {
      if (row.id == roster.selfId) {
        me = row;
        break;
      }
    }
    final rx = me?.x, ry = me?.y;
    if (rx == null || ry == null || !rx.isFinite || !ry.isFinite) return;

    final x = rx.round();
    final y = ry.round();
    if (_x == null) {
      _adopt(x, y);
      return;
    }

    // The most recent time we claimed this tile, not the first: a walk that doubled
    // back is on its second visit, and believing the first would throw away steps that
    // have not landed yet.
    final seen = _pending.lastIndexWhere((p) => p.x == x && p.y == y);
    if (seen >= 0) {
      _pending.removeRange(0, seen + 1);
      return;
    }
    _adopt(x, y);
  }

  void _adopt(int x, int y) {
    _x = x;
    _y = y;
    _pending.clear();
  }
}
