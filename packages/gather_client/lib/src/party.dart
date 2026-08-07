/// Party mode: teleport around the map, without walking into anyone.
///
/// A port of `bridge/lib/party.js`. It moves to the phone for the same reason the
/// rest of this package did: the app now holds the Gather socket, so routing a
/// teleport through the computer would send a tap across the LAN to reach a socket
/// the app already has open.
///
/// Four hops a second for as long as it is switched on. Two things make that harder
/// than picking random coordinates.
///
/// ## Where you *can* stand
///
/// Gather's game server does not validate walkability — every tile on the grid is
/// accepted, walls and void included. Collision is enforced client-side only, so a
/// random tile lands you inside scenery about as often as not.
///
/// Rather than reconstruct the collision map out of `MapObject` and
/// `CatalogItemVariant.collision`, this takes the empirical route: **a tile somebody
/// has stood on is a tile you can stand on.** The full state dump carries every
/// member of the space with their last position — 111 of them in the space this was
/// built against, most parked at a desk — which is a large, free, and definitionally
/// valid set to draw from. It grows as the session runs.
///
/// ## Where you *should not* stand
///
/// Landing next to a colleague opens the video bubble on their screen. Doing that
/// four times a second, to a different person each time, would be a genuinely
/// antisocial thing to inflict on an office. So every candidate is held at least
/// [safeTilesDefault] away from everyone currently connected.
///
/// When nowhere is safe, the hop is **skipped** rather than approximated. A party
/// that pauses is a smaller problem than a party that walks into someone.
///
/// ## Where you *want* to go
///
/// Picking uniformly from the safe set is random but does not look it. The set is
/// small — 35 of 107 known tiles in the measured space — so hops land in the same
/// corner over and over, and consecutive picks are often two tiles apart, which
/// reads as a twitch rather than a teleport. So every hop must clear a minimum
/// distance measured against the size of the floor itself ([_jumpFractions]), and
/// among the tiles that qualify the stalest win — the floor gets covered before
/// anywhere is repeated.
library;

import 'dart:async';
import 'dart:math';

import 'package:gather_events/gather_events.dart';

import 'direct_collector.dart';
import 'game_protocol.dart';

/// How often to hop.
const hopInterval = Duration(milliseconds: 250);

/// Tiles of clearance from every connected person.
///
/// Gather connects media at around 3 tiles. This is deliberately more than double
/// that: positions arrive coalesced over a 250ms window, so the roster is always
/// slightly behind, and somebody walking towards a tile we picked a moment ago
/// should still not end up next to us.
const safeTilesDefault = 8;

/// How long party mode runs before switching itself off.
///
/// The toggle lives on a phone, and between a dead battery, a backgrounded app and
/// a phone left in a drawer, "on until someone says otherwise" eventually means "on
/// for a week", writing to a real workspace at 4Hz the whole time. Ending on its own
/// is the difference between a feature and a hazard.
const maxPartyDuration = Duration(minutes: 15);

/// Faced at random, because always looking Down is a tell.
const _directions = ['Up', 'Down', 'Left', 'Right'];

/// How often a running party says how it is going.
///
/// Separate from `changes`, and much cheaper. A change means the answer to "is this
/// on, and if not why not" moved; the hop counter moving is not that, but a counter
/// frozen at 4 on a screen the user is watching reads as a crash.
const _progressInterval = Duration(seconds: 1);

/// How far a hop has to carry you, as a fraction of how big the floor is.
///
/// Tried in order, first one that has anywhere to go wins. Measuring against the
/// floor's own size rather than a fixed tile count is what makes this work in a
/// broom cupboard and in a 50×50 office: 0.55 of the diagonal is always "most of the
/// way across the map". The ladder down exists because the constraint must never be
/// able to stall the party — when everyone crowds one end and the only safe tiles are
/// close together, a short hop beats a skipped one.
const _jumpFractions = [0.55, 0.35, 0.2, 0.08, 0.0];

/// How many tiles a hop wants to choose between.
///
/// Distance and variety pull against each other, and the safe pool is small — 22
/// tiles of 78 known in the measured space, because holding [safeTilesDefault] clear
/// of 21 people eats most of a 52x49 floor. Demanding the longest jump available
/// then leaves two or three places to go, and the dance degenerates into bouncing
/// between opposite corners: 120 hops used 23 tiles and landed on one of them 42
/// times.
///
/// So the rule is not "jump as far as possible", it is **"jump as far as possible
/// while still having somewhere to choose from"**.
const _minChoices = 6;

/// The shortest thing that counts as a teleport at all.
///
/// [_jumpFractions] is relative to the floor, which is what makes it portable — but
/// relative alone is not enough. The measured space has a dense knot of safe tiles in
/// one corner, and "as far as possible while having six choices" was happy to shuffle
/// five tiles inside that knot. Five tiles is not a teleport, it is a walk.
///
/// Ten is past every radius that means anything here — Gather opens a video bubble
/// around three, [safeTilesDefault] is eight — so a hop that clears it has
/// unambiguously gone somewhere else.
const minJumpTiles = 10;

class PartyTile {
  const PartyTile(this.x, this.y);

  final num x;
  final num y;

  String get key => '$x,$y';
}

class PartyMode {
  PartyMode({
    required DirectCollector? Function() collector,
    void Function(String)? log,
    this.interval = hopInterval,
    this.safeTiles = safeTilesDefault,
    this.maxDuration = maxPartyDuration,
    // Test seams. Production uses neither.
    double Function()? random,
    DateTime Function()? now,
        // Assigned the long way round because a named parameter cannot be a private
        // initializing formal.
        // ignore: prefer_initializing_formals
  })  : _collector = collector,
        _log = log ?? _noop,
        _random = random ?? Random().nextDouble,
        _now = now ?? DateTime.now;

  static void _noop(String _) {}

  /// Looked up per hop rather than held: the collector is replaced whenever the app
  /// reconnects to Gather, and a stale reference would teleport into a dead socket.
  final DirectCollector? Function() _collector;
  final void Function(String) _log;
  final Duration interval;
  final int safeTiles;
  final Duration maxDuration;
  final double Function() _random;
  final DateTime Function() _now;

  /// floorId -> tile key -> tile.
  final Map<String, Map<String, PartyTile>> _tiles = {};

  /// The most recent roster, which is what "where is everyone" is answered from.
  Roster? _roster;

  /// Tile key -> the hop that last used it.
  ///
  /// A blocklist of the last dozen tiles kept the very next hop from repeating but
  /// did nothing about the pool as a whole: with 35 safe tiles, hop 13 was free to
  /// land back where hop 1 did. Recording *when* each tile was used turns avoidance
  /// into coverage — the whole floor gets visited before anywhere is repeated.
  final Map<String, int> _visits = {};

  Timer? _timer;
  DateTime? _stopAt;
  DateTime? _progressAt;
  bool _active = false;
  int _hops = 0;
  int _safeCount = 0;
  String? _detail;

  final _changes = StreamController<PartyState>.broadcast();
  final _progress = StreamController<PartyState>.broadcast();

  /// The answer to "is this on, and if not why not" changed. Worth a full repaint.
  Stream<PartyState> get changes => _changes.stream;

  /// The hop counter moved. Cheap, once a second, and not worth a repaint of
  /// anything but the counter.
  Stream<PartyState> get progress => _progress.stream;

  bool get active => _active;

  /// What the UI renders.
  PartyState state() => PartyState(
        active: _active,
        hops: _hops,
        safeTiles: _safeCount,
        detail: _detail,
      );

  /// How many tiles we know about, across all floors. Diagnostics only.
  int get knownTiles =>
      _tiles.values.fold(0, (total, pool) => total + pool.length);

  /// Learn from a roster: every position in it is somewhere a body fits.
  ///
  /// Offline rows count. Their coordinates are wherever that person logged off,
  /// which is a real tile they really stood on — and, being offline, one nobody is
  /// standing on now. That makes the parked half of a large space the single best
  /// source of safe tiles rather than dead weight.
  void noteRoster(Roster roster) {
    _roster = roster;
    for (final row in roster.rows) {
      final x = row.x, y = row.y;
      if (x == null || y == null || !x.isFinite || !y.isFinite) continue;
      final pool = _tiles.putIfAbsent(row.floorId ?? '', () => {});
      final tile = PartyTile(x, y);
      pool[tile.key] = tile;
    }
  }

  /// Starts hopping, or refuses and says why.
  ///
  /// A button that lights up and does nothing is worse than one that explains
  /// itself, so this returns `ok: false` rather than starting something that cannot
  /// work.
  ({bool ok, PartyState state}) start() {
    if (_active) return (ok: true, state: state());

    final blocked = _blocker();
    if (blocked != null) {
      _setDetail(blocked);
      return (ok: false, state: state());
    }

    _active = true;
    _hops = 0;
    _visits.clear();
    final now = _now();
    _stopAt = now.add(maxDuration);
    // Not null: `start` already publishes the state, so the first counter update is
    // due a second from now rather than immediately after it.
    _progressAt = now;
    _setDetail(null, silent: true);
    _log('party mode: on — hopping every ${interval.inMilliseconds}ms');

    _timer = Timer.periodic(interval, (_) => tick());
    _emitChange();
    // The first hop happens immediately: a quarter of a second of nothing reads as
    // the button having failed.
    tick();
    return (ok: true, state: state());
  }

  PartyState stop([String? reason]) {
    if (!_active) return state();
    _timer?.cancel();
    _timer = null;
    _active = false;
    _log('party mode: off after $_hops hops${reason == null ? '' : ' — $reason'}');
    _setDetail(reason, silent: true);
    _emitChange();
    return state();
  }

  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    await _changes.close();
    await _progress.close();
  }

  /// Why party mode cannot run right now, or null if it can.
  String? _blocker() {
    final collector = _collector();
    if (collector == null) return 'not connected to Gather';
    if (collector.selfId == null) return 'still working out which avatar is yours';
    if (_roster == null) return 'waiting for the first roster from Gather';
    return null;
  }

  /// One hop.
  ///
  /// Public because it is the unit of work and the timer does nothing but call it,
  /// which lets tests drive a party across a hundred hops without a hundred real
  /// quarter-seconds — and without the flakiness that waiting on wall-clock timers
  /// would bring.
  void tick() {
    if (!_active) return;

    final stopAt = _stopAt;
    if (stopAt != null && !_now().isBefore(stopAt)) {
      stop('ended on its own after ${maxDuration.inMinutes} minutes');
      return;
    }

    final collector = _collector();
    if (collector == null) {
      _setDetail('not connected to Gather');
      return;
    }

    final safe = safeTilesNow();
    _safeCount = safe.tiles.length;
    if (safe.tiles.isEmpty) {
      _setDetail(safe.detail ?? 'nowhere far enough from everyone to jump to');
      return;
    }

    final tile = _pick(safe.tiles, safe.me!);
    final direction = _directions[(_random() * _directions.length).floor() % _directions.length];
    final sent = collector.teleport(x: tile.x, y: tile.y, direction: direction);
    if (!sent.ok) {
      _setDetail(sent.detail ?? 'could not reach Gather');
      return;
    }

    _hops++;
    _visits[tile.key] = _hops;
    _setDetail(null);

    final now = _now();
    final last = _progressAt;
    if (last == null || now.difference(last) >= _progressInterval) {
      _progressAt = now;
      if (!_progress.isClosed) _progress.add(state());
    }
  }

  /// Every known tile on my floor that is at least [safeTiles] from everyone
  /// connected.
  ///
  /// Exposed rather than private because it is the whole interesting part, and the
  /// only thing worth testing directly.
  ({List<PartyTile> tiles, String? detail, RosterRow? me}) safeTilesNow() {
    final roster = _roster;
    if (roster == null) {
      return (tiles: const [], detail: 'waiting for the first roster from Gather', me: null);
    }

    RosterRow? me;
    for (final row in roster.rows) {
      if (row.id == roster.selfId) {
        me = row;
        break;
      }
    }
    if (me == null || me.x == null || me.y == null) {
      return (tiles: const [], detail: 'still working out which avatar is yours', me: null);
    }

    final floorId = me.floorId ?? '';
    final pool = _tiles[floorId];
    if (pool == null || pool.isEmpty) {
      return (tiles: const [], detail: 'no tiles known on this floor yet', me: me);
    }

    // Only people who are actually here can be walked into. An offline row is an
    // avatar parked at a desk — the same reasoning `PresenceTracker` uses to avoid
    // reporting empty desks as colleagues standing next to you.
    final others = <RosterRow>[];
    for (final row in roster.rows) {
      if (row.id == roster.selfId) continue;
      if (row.connected == false) continue;
      final x = row.x, y = row.y;
      if (x == null || y == null || !x.isFinite || !y.isFinite) continue;
      // An unknown floor is not an objection, and here that errs towards being
      // *more* careful rather than less.
      if (row.floorId != null && floorId != '' && row.floorId != floorId) continue;
      others.add(row);
    }

    final tiles = <PartyTile>[];
    for (final tile in pool.values) {
      // Standing still is not a hop.
      if (tile.x == me.x && tile.y == me.y) continue;
      var clear = true;
      for (final other in others) {
        if (_distance(tile.x, tile.y, other.x!, other.y!) < safeTiles) {
          clear = false;
          break;
        }
      }
      if (clear) tiles.add(tile);
    }

    if (tiles.isEmpty) {
      return (
        tiles: tiles,
        detail: others.isNotEmpty
            ? 'everywhere known is within $safeTiles tiles of someone'
            : 'no tiles known on this floor yet',
        me: me,
      );
    }
    return (tiles: tiles, detail: null, me: me);
  }

  /// The next tile: as far from where I am as the floor allows, favouring the parts
  /// of it I have not been to yet.
  ///
  /// Two constraints, in that order, because they answer different complaints.
  /// Distance is what makes a single hop *look* like a teleport instead of a step.
  /// Coverage is what stops a hundred hops from being the same six tiles.
  PartyTile _pick(List<PartyTile> tiles, RosterRow me) {
    double away(PartyTile t) => _distance(t.x, t.y, me.x!, me.y!);

    // The hard floor first, and everything after works inside the result — so
    // relaxing for choice or for a cramped floor can never talk us back into a short
    // hop.
    final eligible = tiles.where((t) => away(t) >= minJumpTiles).toList();
    final pool = eligible.isNotEmpty ? eligible : tiles;

    // Then the longest rung that still offers a real choice. Each rung down is a
    // superset of the one above, so the search is monotonic.
    final reach = _spread(pool);
    var candidates = pool;
    for (final fraction in _jumpFractions) {
      final min = reach * fraction;
      if (min <= 0) break; // The last rung admits everything, which `candidates` is.
      final far = pool.where((t) => away(t) >= min).toList();
      if (far.isEmpty) continue;
      candidates = far;
      if (far.length >= _minChoices) break;
    }
    return _leastVisited(candidates);
  }

  /// How far apart the two most distant candidates could be: the diagonal of their
  /// bounding box. A cheap stand-in for the diameter of the walkable area.
  double _spread(List<PartyTile> tiles) {
    if (tiles.isEmpty) return 0;
    var minX = tiles.first.x, maxX = tiles.first.x;
    var minY = tiles.first.y, maxY = tiles.first.y;
    for (final t in tiles) {
      if (t.x < minX) minX = t.x;
      if (t.x > maxX) maxX = t.x;
      if (t.y < minY) minY = t.y;
      if (t.y > maxY) maxY = t.y;
    }
    return _distance(maxX, maxY, minX, minY);
  }

  /// One of the candidates used least recently, chosen at random among them.
  ///
  /// Never-visited tiles win outright, so a fresh party sweeps the whole floor before
  /// repeating anything. Once everywhere has been used the field narrows to the
  /// stalest half and picks randomly inside it — deterministic enough to keep moving
  /// across the map, random enough that a human cannot see the pattern.
  PartyTile _leastVisited(List<PartyTile> candidates) {
    var from = candidates.where((t) => !_visits.containsKey(t.key)).toList();
    if (from.isEmpty) {
      final stalest = [...candidates]
        ..sort((a, b) => (_visits[a.key] ?? 0).compareTo(_visits[b.key] ?? 0));
      from = stalest.take(max(1, (stalest.length / 2).ceil())).toList();
    }
    return from[(_random() * from.length).floor() % from.length];
  }

  /// Records why the party is or is not going, and tells the UI **only when the
  /// answer changes**.
  ///
  /// Load-bearing: this runs four times a second, and every change rebuilds the
  /// card. An unconditional emit would be four repaints a second for as long as
  /// party mode is on.
  void _setDetail(String? detail, {bool silent = false}) {
    if (detail == _detail) return;
    _detail = detail;
    if (detail != null) _log('party mode: $detail');
    if (!silent) _emitChange();
  }

  void _emitChange() {
    if (!_changes.isClosed) _changes.add(state());
  }
}

double _distance(num ax, num ay, num bx, num by) {
  final dx = (ax - bx).toDouble();
  final dy = (ay - by).toDouble();
  return sqrt(dx * dx + dy * dy);
}
