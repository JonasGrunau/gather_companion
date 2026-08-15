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
/// The answer is to read the actual floor plan, which Gather sends us and this
/// client used to throw away. [SpaceMap] decodes it out of the state dump —
/// `MapArea` rectangles, `MapObject` furniture and the `collision` shapes behind
/// it — and hands back every tile on the floor with the furniture taken out. On the
/// space this was built against that is **9705 walkable tiles of 10168**.
///
/// Walkable is not the same as *somewhere to hold a party*, and the difference is
/// most of the grid. Walls block directions rather than tiles, so a walking avatar
/// is kept indoors by rules a teleport steps straight over: the emptiness outside
/// the building is unfurnished, nothing marks it blocked, and the jump ladder below
/// prefers exactly the far edges it lives on. [SpaceMap.open] is the pool this uses
/// — walkable, inside the office footprint, and out of the rooms people close
/// behind them. **1447 tiles of the 9705**, all of them somewhere a colleague might
/// plausibly be standing.
///
/// It is worth being clear about how much that changed, because the old approach
/// was the whole bug. Party mode used to infer walkability: *a tile somebody has
/// been seen on is a tile you can stand on*. That is true, and it is nowhere near
/// enough. A state dump is worth about one tile per member — most people are parked
/// at a desk — so it yielded **78 tiles of a 124×82 map**, under one percent of the
/// floor, and after holding everyone clear about eighteen were left. Eighteen tiles
/// at four hops a second is exhausted in five seconds; everything after that was a
/// repeat. The picker was never at fault, and no amount of cleverness in it could
/// have helped: it was already visiting everything it was offered.
///
/// The map also arrives complete and stays current — it is patched on the same
/// socket as everything else, so somebody rearranging the furniture updates it
/// without a reconnect.
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
/// Picking uniformly at random is random but does not look it: consecutive picks are
/// often two tiles apart, which reads as a twitch rather than a teleport. So every hop
/// must clear a minimum distance measured against the size of the floor itself
/// ([_jumpFractions]), and among the tiles that qualify the stalest win.
///
/// That last rule is what "less random, so it looks more random" means here. Uniform
/// sampling of a pool clumps and repeats; least-recently-used does not. With a pool
/// in the thousands it means a fifteen-minute party — 3600 hops — never lands on the
/// same tile twice.
library;

import 'dart:async';
import 'dart:math';

import 'package:gather_events/gather_events.dart';

import 'direct_collector.dart';
import 'game_protocol.dart';
import 'space_map.dart';

/// How often to hop.
const hopInterval = Duration(milliseconds: 250);

/// Tiles of clearance from every connected person.
///
/// Gather connects media at around 3 tiles. This keeps two tiles of margin on top,
/// because positions arrive coalesced over a 250ms window: the roster is always
/// slightly behind, and somebody walking towards a tile we picked a moment ago should
/// still not end up next to us.
///
/// It used to be 8, on the reasoning that more clearance is strictly kinder. It is
/// not free: clearance is subtracted from a pool that is already the scarce resource
/// here, and 8 was costing about a third of the usable floor to buy margin nobody can
/// perceive. The rule worth keeping is "never open a bubble", and 5 keeps it.
const safeTilesDefault = 5;


/// How long party mode runs before switching itself off.
///
/// The toggle lives on a phone, and between a dead battery, a backgrounded app and
/// a phone left in a drawer, "on until someone says otherwise" eventually means "on
/// for a week", writing to a real workspace at 4Hz the whole time. Ending on its own
/// is the difference between a feature and a hazard.
const maxPartyDuration = Duration(minutes: 15);

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
/// Distance and variety pull against each other. Demanding the longest jump
/// available leaves two or three places to go, and the dance degenerates into
/// bouncing between opposite corners — measured, back when the pool was small: 120
/// hops used 23 tiles and landed on one of them 42 times. The floor plan makes that
/// far less likely than it was, but a nearly-empty office at the far end of a long
/// map can still narrow the top rung to a handful of tiles.
///
/// So the rule is not "jump as far as possible", it is **"jump as far as possible
/// while still having somewhere to choose from"**.
const _minChoices = 6;

/// The shortest thing that counts as a teleport at all.
///
/// [_jumpFractions] is relative to the floor, which is what makes it portable — but
/// relative alone is not enough. A dense knot of safe tiles in one corner made "as
/// far as possible while having six choices" happy to shuffle five tiles inside that
/// knot. Five tiles is not a teleport, it is a walk.
///
/// Ten is past every radius that means anything here — Gather opens a video bubble
/// around three, [safeTilesDefault] is five — so a hop that clears it has
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
  final _hopped = StreamController<PartyTile>.broadcast();

  /// The answer to "is this on, and if not why not" changed. Worth a full repaint.
  Stream<PartyState> get changes => _changes.stream;

  /// The hop counter moved. Cheap, once a second, and not worth a repaint of
  /// anything but the counter.
  Stream<PartyState> get progress => _progress.stream;

  /// One event per hop actually sent, carrying where it went.
  ///
  /// The map draws a teleport differently from a walk, and telling the two apart by
  /// how far the body moved is a guess: the roster arrives coalesced over 250ms and
  /// component-wise (`/position/x` and `/position/y` are separate patches), so one
  /// hop can reach a screen as two short moves that look exactly like walking. This
  /// is the fact rather than the inference — we know it is a teleport because we are
  /// the thing that teleported.
  ///
  /// Emitted only when the action actually went out. A hop that could not reach
  /// Gather moved nobody and must not animate.
  Stream<PartyTile> get hops => _hopped.stream;

  bool get active => _active;

  /// What the UI renders.
  PartyState state() => PartyState(
        active: _active,
        hops: _hops,
        safeTiles: _safeCount,
        detail: _detail,
      );

  /// How many tiles we could stand on if nobody were in the way. Diagnostics only.
  int get knownTiles => _mapNow()?.walkable.length ?? 0;

  /// The floor plan for the floor we are on, or null before it has arrived.
  SpaceMap? _mapNow() {
    final me = _me();
    return _collector()?.mapFor(me?.floorId);
  }

  /// Our own roster row, which is both where we are and which floor we are on.
  RosterRow? _me() {
    final roster = _roster;
    if (roster == null) return null;
    for (final row in roster.rows) {
      if (row.id == roster.selfId) return row;
    }
    return null;
  }

  /// The roster is now only "where is everyone", not "where can I stand".
  ///
  /// It used to be both, and conflating them is what starved the tile pool. Where
  /// you can stand comes from [SpaceMap]; the roster answers the other question,
  /// which it is actually authoritative about.
  void noteRoster(Roster roster) => _roster = roster;

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
    await _hopped.close();
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

    final me = safe.me!;
    final tile = _pick(safe.tiles, me);
    // The way we travelled, which is what the client puts there:
    // `MoveController.teleport` derives it with `positionToDirectionIgnoringAxis`
    // rather than sending a constant. A random facing is what this used to send,
    // and it made every hop land looking somewhere the body had not come from.
    final sent = collector.teleport(
      x: tile.x,
      y: tile.y,
      direction: headingTo(
        fromX: (me.x ?? tile.x).round(),
        fromY: (me.y ?? tile.y).round(),
        toX: tile.x.round(),
        toY: tile.y.round(),
      ),
    );
    if (!sent.ok) {
      _setDetail(sent.detail ?? 'could not reach Gather');
      return;
    }

    _hops++;
    _visits[tile.key] = _hops;
    _setDetail(null);
    if (!_hopped.isClosed) _hopped.add(tile);

    final now = _now();
    final last = _progressAt;
    if (last == null || now.difference(last) >= _progressInterval) {
      _progressAt = now;
      if (!_progress.isClosed) _progress.add(state());
    }
  }

  /// Every walkable tile on my floor that is at least [safeTiles] from everyone
  /// connected.
  ///
  /// Exposed rather than private because it is the whole interesting part, and the
  /// only thing worth testing directly.
  ({List<PartyTile> tiles, String? detail, RosterRow? me}) safeTilesNow() {
    final roster = _roster;
    if (roster == null) {
      return (tiles: const [], detail: 'waiting for the first roster from Gather', me: null);
    }

    final me = _me();
    if (me == null || me.x == null || me.y == null) {
      return (tiles: const [], detail: 'still working out which avatar is yours', me: null);
    }

    final map = _collector()?.mapFor(me.floorId);
    if (map == null) {
      return (tiles: const [], detail: 'still reading the floor plan from Gather', me: me);
    }

    // Stamp a keep-out disc around each person rather than measuring every tile
    // against every person. The floor runs to ten thousand tiles now, so the old
    // way was tiles x crowd — a quarter of a million comparisons a second on a
    // phone. A disc is (2r+1)^2 per person and does not grow with the map at all.
    final excluded = <int>{};
    final floorId = me.floorId;
    var crowd = 0;
    for (final row in roster.rows) {
      if (row.id == roster.selfId) continue;
      if (row.connected == false) continue;
      final x = row.x, y = row.y;
      if (x == null || y == null || !x.isFinite || !y.isFinite) continue;
      // An unknown floor is not an objection, and here that errs towards being
      // *more* careful rather than less.
      if (row.floorId != null && floorId != null && row.floorId != floorId) continue;
      crowd++;
      final cx = x.round(), cy = y.round();
      for (var dy = -safeTiles; dy <= safeTiles; dy++) {
        final ty = cy + dy;
        if (ty < 0 || ty >= map.height) continue;
        for (var dx = -safeTiles; dx <= safeTiles; dx++) {
          final tx = cx + dx;
          if (tx < 0 || tx >= map.width) continue;
          // A disc, not a square: the rule is a distance, and the corners of a
          // square are 1.4x further out than the rule asks for.
          if (dx * dx + dy * dy >= safeTiles * safeTiles) continue;
          excluded.add(ty * map.width + tx);
        }
      }
    }

    final here = me.y!.round() * map.width + me.x!.round();
    final tiles = <PartyTile>[];
    for (final tile in map.open) {
      if (tile == here) continue; // standing still is not a hop
      if (excluded.contains(tile)) continue;
      tiles.add(PartyTile(map.xOf(tile), map.yOf(tile)));
    }

    if (tiles.isEmpty) {
      return (
        tiles: tiles,
        detail: crowd > 0
            ? 'everywhere on this floor is within $safeTiles tiles of someone'
            : 'the floor plan has nowhere to stand',
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
    // Measured once and carried, rather than recomputed inside each filter below.
    // There are five rungs plus the hard floor, and the candidate list is now the
    // whole walkable floor — recomputing would be six square roots per tile per
    // hop, four times a second.
    final mx = me.x!, my = me.y!;
    final away = List<double>.generate(
      tiles.length,
      (i) => _distance(tiles[i].x, tiles[i].y, mx, my),
      growable: false,
    );

    // The hard floor first, and everything after works inside the result — so
    // relaxing for choice or for a cramped floor can never talk us back into a short
    // hop.
    var pool = [
      for (var i = 0; i < tiles.length; i++)
        if (away[i] >= minJumpTiles) i,
    ];
    if (pool.isEmpty) pool = [for (var i = 0; i < tiles.length; i++) i];

    // Then the longest rung that still offers a real choice. Each rung down is a
    // superset of the one above, so the search is monotonic.
    final reach = _spread([for (final i in pool) tiles[i]]);
    var candidates = pool;
    for (final fraction in _jumpFractions) {
      final min = reach * fraction;
      if (min <= 0) break; // The last rung admits everything, which `candidates` is.
      final far = [
        for (final i in pool)
          if (away[i] >= min) i,
      ];
      if (far.isEmpty) continue;
      candidates = far;
      if (far.length >= _minChoices) break;
    }
    return _leastVisited([for (final i in candidates) tiles[i]]);
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

double _distance(num ax, num ay, num bx, num by) =>
    sqrt(_distanceSquared(ax, ay, bx, by));

double _distanceSquared(num ax, num ay, num bx, num by) {
  final dx = (ax - bx).toDouble();
  final dy = (ay - by).toDouble();
  return dx * dx + dy * dy;
}
