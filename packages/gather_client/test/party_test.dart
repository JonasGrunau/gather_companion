/// [PartyMode]'s two hard rules and its one aesthetic one.
///
/// The counterpart of `bridge/test/party.test.js`. The rules, in order of how much
/// they matter:
///
///  1. **Never land near anyone.** Getting this wrong opens a video bubble on a
///     colleague's screen, four times a second. It is the only thing here that can
///     actually harm someone's day.
///  2. **Never land somewhere a body does not fit.** Gather accepts any tile,
///     including walls, so the only defence is drawing from tiles people have stood
///     on.
///  3. **Look like a teleport.** A five-tile shuffle is a walk.
library;

import 'package:gather_client/gather_client.dart';
import 'package:test/test.dart';

/// An open floor with nothing on it, which is the fixture most tests want.
///
/// Party mode reads walkability from the map now, so the map is what has to exist
/// for it to do anything at all.
SpaceMap _open({int width = 40, int height = 40, String floorId = 'f1'}) => SpaceMap(
      floorId: floorId,
      width: width,
      height: height,
      blocked: const {},
      rooms: const [],
    );

/// A collector that records teleports instead of sending them.
class _FakeCollector implements DirectCollector {
  _FakeCollector();

  String? self = 'me-1';
  final List<({num x, num y, String direction})> hops = [];
  bool refuse = false;
  SpaceMap? map = _open();

  @override
  String? get selfId => self;

  @override
  SpaceMap? mapFor(String? floorId) => map;

  @override
  ({bool ok, String? detail}) teleport({
    required num x,
    required num y,
    String direction = 'Down',
  }) {
    if (refuse) return (ok: false, detail: 'not connected to Gather');
    hops.add((x: x, y: y, direction: direction));
    return (ok: true, detail: null);
  }

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RosterRow _row(String id, num x, num y, {bool connected = true, String floor = 'f1'}) =>
    RosterRow(id: id, x: x, y: y, floorId: floor, connected: connected);

/// Just the people. Where anyone *can* stand is [_open]'s business now.
Roster _floor({required List<RosterRow> present}) =>
    Roster(selfId: 'me-1', rows: present);

void main() {
  late _FakeCollector collector;
  PartyMode? party;

  setUp(() => collector = _FakeCollector());
  tearDown(() async {
    await party?.dispose();
    party = null;
  });

  /// Deterministic: always takes the first candidate, so assertions are about the
  /// *candidate set* rather than about which coin came up.
  PartyMode build({int safeTiles = safeTilesDefault, double roll = 0.0}) => party = PartyMode(
        collector: () => collector,
        safeTiles: safeTiles,
        random: () => roll,
      );

  group('refusing to start', () {
    test('without a Gather connection', () {
      final p = PartyMode(collector: () => null);
      addTearDown(p.dispose);
      final result = p.start();

      expect(result.ok, isFalse);
      expect(result.state.active, isFalse);
      expect(result.state.detail, 'not connected to Gather');
    });

    test('before it knows which avatar is ours', () {
      collector.self = null;
      final result = build().start();

      expect(result.ok, isFalse);
      expect(result.state.detail, contains('which avatar is yours'));
    });

    test('before the first roster', () {
      final result = build().start();

      expect(result.ok, isFalse);
      expect(result.state.detail, contains('waiting for the first roster'));
    });
  });

  group('never landing near anyone', () {
    test('every hop clears the safe radius from everyone connected', () {
      final p = build();
      final colleagues = [
        _row('me-1', 20, 20),
        _row('them-1', 10, 10),
        _row('them-2', 30, 30),
        _row('them-3', 10, 30),
      ];
      p.noteRoster(_floor(present: colleagues));

      expect(p.start().ok, isTrue);
      for (var i = 0; i < 40; i++) {
        p.tick();
      }

      expect(collector.hops, isNotEmpty);
      for (final hop in collector.hops) {
        for (final other in colleagues.where((c) => c.id != 'me-1')) {
          final dx = hop.x - other.x!;
          final dy = hop.y - other.y!;
          final distance = (dx * dx + dy * dy);
          expect(
            distance,
            greaterThanOrEqualTo(safeTilesDefault * safeTilesDefault),
            reason: 'hop to (${hop.x},${hop.y}) came within reach of ${other.id}',
          );
        }
      }
    });

    test('a crowded floor skips the hop rather than approximating one', () {
      // A party that pauses is a smaller problem than a party that walks into
      // someone.
      final p = build(safeTiles: 100);
      p.noteRoster(_floor(present: [_row('me-1', 20, 20), _row('them-1', 21, 20)]));

      final result = p.start();
      expect(result.ok, isTrue, reason: 'it starts; it just has nowhere to go');
      expect(collector.hops, isEmpty);
      expect(p.state().detail, contains('within 100 tiles of someone'));
    });

    test('an offline avatar is not somebody to avoid', () {
      // Somebody logged off at a desk is not standing there, so their tile costs
      // nobody any clearance. The radius here is set past the whole floor, so if
      // they counted there would be nowhere to go at all — which is exactly what a
      // connected person in the same spot produces.
      final crowded = build(safeTiles: 100)
        ..noteRoster(_floor(present: [_row('me-1', 0, 0), _row('them', 20, 20)]));
      expect(crowded.start().ok, isTrue);
      expect(collector.hops, isEmpty, reason: 'a connected colleague blocks the floor');

      collector.hops.clear();
      final p = party = PartyMode(collector: () => collector, safeTiles: 100, random: () => 0)
        ..noteRoster(_floor(present: [
          _row('me-1', 0, 0),
          _row('parked', 20, 20, connected: false),
        ]));

      expect(p.start().ok, isTrue);
      expect(collector.hops, isNotEmpty, reason: 'an offline avatar blocks nothing');
    });

    test('someone on another floor cannot be walked into', () {
      final p = build(safeTiles: 100);
      p.noteRoster(Roster(selfId: 'me-1', rows: [
        _row('me-1', 0, 0, floor: 'f1'),
        _row('upstairs', 20, 20, floor: 'f2'),
      ]));

      expect(p.start().ok, isTrue);
      expect(collector.hops, isNotEmpty, reason: 'the other floor is irrelevant');
    });
  });

  group('looking like a teleport', () {
    test('a hop clears the minimum jump distance', () {
      final p = build();
      p.noteRoster(_floor(present: [_row('me-1', 0, 0)]));

      p.start();
      final hop = collector.hops.single;
      final distance = (hop.x * hop.x + hop.y * hop.y);
      expect(
        distance,
        greaterThanOrEqualTo(minJumpTiles * minJumpTiles),
        reason: 'a five-tile shuffle is a walk, not a teleport',
      );
    });

    test('the floor is covered before anywhere is repeated', () {
      // The failure this replaced: 120 hops using 23 tiles and landing on one of
      // them 42 times.
      var roll = 0.0;
      final p = party = PartyMode(
        collector: () => collector,
        // Varying the roll stops "always the first candidate" from doing the
        // covering for us — the coverage has to come from `_leastVisited`.
        random: () => (roll = (roll + 0.37) % 1.0),
      );
      p.noteRoster(_floor(present: [_row('me-1', 20, 20)]));

      p.start();
      for (var i = 0; i < 30; i++) {
        p.tick();
      }

      final visited = collector.hops.map((h) => '${h.x},${h.y}').toList();
      final unique = visited.toSet();
      expect(
        unique.length,
        greaterThan(visited.length ~/ 2),
        reason: 'most hops should be somewhere new: $visited',
      );
    });

    test('direction varies, because always facing Down is a tell', () {
      var roll = 0.0;
      final p = party = PartyMode(
        collector: () => collector,
        random: () => (roll = (roll + 0.3) % 1.0),
      );
      p.noteRoster(_floor(present: [_row('me-1', 20, 20)]));
      p.start();
      for (var i = 0; i < 12; i++) {
        p.tick();
      }

      expect(collector.hops.map((h) => h.direction).toSet().length, greaterThan(1));
    });
  });

  group('stopping', () {
    test('it ends on its own, because a phone cannot be relied on to say stop', () {
      // On until someone says otherwise eventually means on for a week, writing to a
      // real workspace at 4Hz the whole time.
      var clock = DateTime(2026, 8, 7, 12);
      final p = party = PartyMode(
        collector: () => collector,
        random: () => 0,
        now: () => clock,
        maxDuration: const Duration(minutes: 15),
      );
      p.noteRoster(_floor(present: [_row('me-1', 20, 20)]));
      p.start();
      expect(p.active, isTrue);

      clock = clock.add(const Duration(minutes: 16));
      p.tick();
      // The timer would fire this in production; driving it directly keeps the test
      // off a real clock.
      p.stop('ended on its own after 15 minutes');

      expect(p.active, isFalse);
      expect(p.state().detail, contains('ended on its own'));
    });

    test('losing Gather mid-party is reported rather than hidden', () {
      final p = build();
      p.noteRoster(_floor(present: [_row('me-1', 20, 20)]));
      p.start();
      expect(collector.hops, isNotEmpty);

      collector.refuse = true;
      final before = collector.hops.length;

      // One more tick's worth of work, with the socket refusing.
      p.tick();

      expect(collector.hops, hasLength(before), reason: 'nothing more was sent');
    });

    test('stopping twice is not an error', () {
      final p = build();
      p.noteRoster(_floor(present: [_row('me-1', 20, 20)]));
      p.start();
      p.stop('switched off');
      expect(p.stop('again').active, isFalse);
    });
  });

  group('the floor plan is where tiles come from', () {
    test('there is nowhere to go until the map arrives', () {
      collector.map = null;
      final p = build()..noteRoster(_floor(present: [_row('me-1', 5, 5)]));

      expect(p.start().ok, isTrue, reason: 'it starts; it just has no floor yet');
      expect(collector.hops, isEmpty);
      expect(p.state().detail, contains('floor plan'));
    });

    test('walls and furniture are never landed on', () {
      // A corridor: one open column through a floor that is otherwise solid. The
      // server would happily accept a wall tile, so this is the only thing standing
      // between party mode and teleporting into the scenery.
      const width = 30, height = 30, open = 7;
      collector.map = SpaceMap(
        floorId: 'f1',
        width: width,
        height: height,
        blocked: {
          for (var y = 0; y < height; y++)
            for (var x = 0; x < width; x++)
              if (x != open) y * width + x,
        },
        rooms: const [],
      );
      var roll = 0.0;
      final p = party = PartyMode(
        collector: () => collector,
        random: () => (roll = (roll + 0.37) % 1.0),
      )..noteRoster(_floor(present: [_row('me-1', open, 0)]));

      p.start();
      for (var i = 0; i < 40; i++) {
        p.tick();
      }

      expect(collector.hops, isNotEmpty);
      for (final hop in collector.hops) {
        expect(hop.x, open, reason: 'hopped into a wall at (${hop.x},${hop.y})');
      }
    });

    test('the whole floor is available, not just where people have been', () {
      // The bug this fixes: the pool used to be tiles somebody had been seen on,
      // which on a real map is under one percent of it.
      final p = build()..noteRoster(_floor(present: [_row('me-1', 0, 0)]));
      expect(p.knownTiles, 40 * 40);
    });
  });
}
