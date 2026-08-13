/// [Walk] is what stands between a thumb and the office wall.
///
/// The `move` action does not check anything — its whole body is
/// `position += direction.toPositionDelta()` — so every rule about where an avatar
/// may go is enforced here or nowhere. Two of them are load-bearing:
///
///  1. **Never step into somewhere a body does not fit**, which is the same rule the
///     desktop client applies before it sends the same action.
///  2. **Know which tile you are on**, which the roster cannot answer on its own: it
///     is coalesced at 250ms while a walk runs at seven tiles a second, so it is
///     always describing a tile you left two steps ago.
library;

import 'package:gather_client/gather_client.dart';
import 'package:test/test.dart';

/// An open floor with nothing on it.
SpaceMap _open({int width = 20, int height = 20}) => SpaceMap(
      floorId: 'f1',
      width: width,
      height: height,
      blocked: const {},
      rooms: const [],
    );

/// A floor with a desk at (5,5) and a wall between (8,y) and (9,y) for every y.
///
/// Both kinds of obstacle in one fixture, because the interesting thing about them is
/// that they are enforced by different rules: the desk is a blocked *tile* and the
/// wall is a blocked *line*.
SpaceMap _obstructed() => SpaceMap(
      floorId: 'f1',
      width: 20,
      height: 20,
      blocked: {5 * 20 + 5},
      // The line on the west side of column 9, which is `(tile * 2) + 1`.
      edges: {for (var y = 0; y < 20; y++) ((y * 20 + 9) * 2) + 1},
      rooms: const [],
    );

/// A collector that records steps instead of sending them.
class _FakeCollector implements DirectCollector {
  final List<String> steps = [];
  bool refuse = false;

  @override
  String? get selfId => 'me-1';

  @override
  ({bool ok, String? detail}) move({required String direction}) {
    if (refuse) return (ok: false, detail: 'not connected to Gather');
    steps.add(direction);
    return (ok: true, detail: null);
  }

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Roster _at(num x, num y) => Roster(
      selfId: 'me-1',
      rows: [RosterRow(id: 'me-1', x: x, y: y, floorId: 'f1', connected: true)],
    );

void main() {
  late _FakeCollector collector;
  late SpaceMap map;
  Walk? walk;

  setUp(() {
    collector = _FakeCollector();
    map = _open();
  });
  tearDown(() async {
    await walk?.dispose();
    walk = null;
  });

  /// Built with a very long interval so nothing repeats on its own: every test that
  /// wants a second step asks for one. Timers in a test are a source of flakes, and
  /// [Walk.step] is public precisely so they are not needed.
  Walk build() => walk = Walk(
        collector: () => collector,
        map: () => map,
        interval: const Duration(hours: 1),
      );

  group('before it knows anything', () {
    test('a press with no position sends nothing', () {
      // The first thing a step needs is the tile to judge it from. Guessing would be
      // guessing about somebody's real avatar in a real workspace.
      final w = build();
      w.press('Right');

      expect(collector.steps, isEmpty);
      expect(w.at, isNull);
    });

    test('a press with no floor plan sends nothing', () {
      // Without the map there is no collision rule to apply, and the office footprint
      // is 96x52 of a 124x82 grid — the emptiness around it is walkable as far as the
      // game server is concerned, so an unchecked step walks out of the building.
      final w = walk = Walk(
        collector: () => collector,
        map: () => null,
        interval: const Duration(hours: 1),
      )..noteRoster(_at(4, 4));
      w.press('Right');

      expect(w.step().detail, 'still reading the floor plan');
      expect(collector.steps, isEmpty);
      expect(w.at, (x: 4, y: 4), reason: 'where the roster left it');
    });
  });

  group('stepping', () {
    test('a press steps at once rather than waiting out a tick', () {
      // A quarter-second of nothing after a press reads as the button having missed
      // it, which on a control is worse than a slow walk.
      final w = build()..noteRoster(_at(4, 4));
      w.press('Right');

      expect(collector.steps, ['Right']);
      expect(w.at, (x: 5, y: 4));
      expect(w.direction, 'Right');
      expect(w.walking, isTrue);
    });

    test('each direction moves the way Gather means it', () {
      // `toPositionDelta`, and the one worth stating: y grows downwards, so Up is
      // towards the top of the map.
      for (final (direction, expected) in [
        ('Up', (x: 4, y: 3)),
        ('Down', (x: 4, y: 5)),
        ('Left', (x: 3, y: 4)),
        ('Right', (x: 5, y: 4)),
      ]) {
        final w = Walk(collector: () => collector, map: () => map)
          ..noteRoster(_at(4, 4));
        addTearDown(w.dispose);
        w.press(direction);
        expect(w.at, expected, reason: direction);
        w.release();
      }
    });

    test('holding walks tile after tile', () {
      final w = build()..noteRoster(_at(4, 4));
      w.press('Right');
      w.step();
      w.step();

      expect(collector.steps, ['Right', 'Right', 'Right']);
      expect(w.at, (x: 7, y: 4));
    });

    test('a release stops it, and stepping after one does nothing', () {
      final w = build()..noteRoster(_at(4, 4));
      w.press('Right');
      w.release();

      expect(w.walking, isFalse);
      expect(w.direction, isNull);
      expect(w.step().detail, 'nothing is held');
      expect(collector.steps, hasLength(1));
    });

    test('sliding a thumb to another arrow turns without stopping', () {
      // The reason the pad is one pointer rather than four buttons: going round a
      // corner should not need the thumb lifted.
      final w = build()..noteRoster(_at(4, 4));
      w.press('Right');
      w.press('Down');

      expect(collector.steps, ['Right', 'Down']);
      expect(w.at, (x: 5, y: 5));
    });

    test('pressing the arrow already held is not a second step', () {
      // The pad calls `press` on every pointer move, which is many times a frame.
      // Taking each one would walk at the rate the finger jitters.
      final w = build()..noteRoster(_at(4, 4));
      w.press('Right');
      w.press('Right');
      w.press('Right');

      expect(collector.steps, ['Right']);
    });

    test('a direction Gather has no word for is refused', () {
      final w = build()..noteRoster(_at(4, 4));
      w.press('North');

      expect(collector.steps, isEmpty);
      expect(w.walking, isFalse);
    });

    test('a step the socket refuses is not believed', () {
      // Otherwise this walks on ahead of an avatar that never moved, and every
      // collision check after it is measured from a tile nobody is standing on.
      final w = build()..noteRoster(_at(4, 4));
      collector.refuse = true;
      w.press('Right');

      expect(w.at, (x: 4, y: 4));
    });
  });

  group('not walking through the office', () {
    test('into furniture', () {
      map = _obstructed();
      final w = build()..noteRoster(_at(4, 5));
      w.press('Right');

      expect(collector.steps, isEmpty, reason: 'the desk at (5,5)');
      expect(w.at, (x: 4, y: 5));

      // Only that tile, and only in that direction: a desk beside you is not a reason
      // to be unable to walk past it.
      w.press('Down');
      expect(collector.steps, ['Down']);
    });

    test('through a wall', () {
      map = _obstructed();
      final w = build()..noteRoster(_at(8, 2));
      w.press('Right');

      expect(collector.steps, isEmpty);
      expect(w.at, (x: 8, y: 2));
    });

    test('off the edge of the grid', () {
      final w = build()..noteRoster(_at(0, 0));
      w.press('Left');

      expect(collector.steps, isEmpty);
      w.press('Right');
      expect(collector.steps, ['Right'], reason: 'and inwards is fine');
    });

    test('a blocked press still counts as held, so the walk resumes on the way out',
        () {
      // Holding Right against a wall and rolling the thumb to Down should walk. A
      // refused step that also cleared the held direction would need the thumb lifted
      // and pressed again.
      map = _obstructed();
      final w = build()..noteRoster(_at(8, 2));
      w.press('Right');
      expect(w.walking, isTrue);

      w.press('Down');
      expect(collector.steps, ['Down']);
    });
  });

  group('knowing where it is', () {
    test('the first roster is simply believed', () {
      final w = build()..noteRoster(_at(7, 3));
      expect(w.at, (x: 7, y: 3));
    });

    test('a roster describing a tile already left does not drag the walk back', () {
      // The whole reason this class holds a position. Three steps go out inside one
      // 250ms roster window, so the roster that lands next is two tiles stale — and
      // adopting it would rubber-band the avatar backwards and check collision
      // against the wrong tile.
      final w = build()..noteRoster(_at(4, 4));
      w.press('Right');
      w.step();
      w.step();
      expect(w.at, (x: 7, y: 4));

      w.noteRoster(_at(5, 4));
      expect(w.at, (x: 7, y: 4), reason: 'still two steps ahead of the wire');
    });

    test('a roster nobody claimed is the truth, and wins', () {
      // The desktop client drives the same avatar, party mode hops it across the
      // office, and a step can simply be lost. Any of those puts Gather somewhere this
      // never said it was going, and Gather is right.
      final w = build()..noteRoster(_at(4, 4));
      w.press('Right');
      expect(w.at, (x: 5, y: 4));

      w.noteRoster(_at(30, 12));
      expect(w.at, (x: 30, y: 12));
    });

    test('at rest every roster is adopted', () {
      final w = build()..noteRoster(_at(4, 4));
      w.noteRoster(_at(4, 5));
      w.noteRoster(_at(4, 6));

      expect(w.at, (x: 4, y: 6));
    });

    test('a roster with no position for us changes nothing', () {
      final w = build()..noteRoster(_at(4, 4));
      w.noteRoster(const Roster(selfId: 'me-1', rows: []));

      expect(w.at, (x: 4, y: 4));
    });
  });

  group('safety', () {
    test('a hold that outlasts the limit is dropped', () {
      // A finger cannot get lost but an app can: backgrounded mid-press, or a pointer
      // cancelled by a system gesture that never sends the up event. The failure this
      // prevents is a key stuck down in somebody's real workspace.
      var now = DateTime(2026, 8, 13, 9);
      final w = walk = Walk(
        collector: () => collector,
        map: () => map,
        interval: const Duration(hours: 1),
        holdLimit: const Duration(seconds: 30),
        now: () => now,
      )..noteRoster(_at(4, 4));

      w.press('Right');
      now = now.add(const Duration(seconds: 29));
      expect(w.step().ok, isTrue);

      now = now.add(const Duration(seconds: 2));
      expect(w.step().ok, isFalse);
      expect(w.walking, isFalse, reason: 'and it let go rather than just refusing');
    });

    test('the limit is measured from the press, not from the last turn', () {
      // Otherwise sliding a thumb around the pad renews the lease indefinitely, which
      // is exactly what a pocket does to a touchscreen.
      var now = DateTime(2026, 8, 13, 9);
      final w = walk = Walk(
        collector: () => collector,
        map: () => map,
        interval: const Duration(hours: 1),
        holdLimit: const Duration(seconds: 30),
        now: () => now,
      )..noteRoster(_at(4, 4));

      w.press('Right');
      now = now.add(const Duration(seconds: 20));
      w.press('Down');
      now = now.add(const Duration(seconds: 20));

      expect(w.step().ok, isFalse);
      expect(w.walking, isFalse);
    });
  });

  group('walking a route', () {
    /// The route [SpaceMap.routeTo] would hand back for a straight line east.
    List<({int x, int y})> east(int fromX, int y, int toX) =>
        [for (var x = fromX; x <= toX; x++) (x: x, y: y)];

    test('a route steps itself to the end and then stops', () {
      final w = build()..noteRoster(_at(4, 4));
      w.follow(east(4, 4, 7));

      // The first step goes immediately, like a press: the pill was already the
      // confirmation, so waiting out a tick reads as the tap having missed.
      expect(collector.steps, ['Right']);
      expect(w.onRoute, isTrue);

      w.step();
      w.step();
      expect(collector.steps, ['Right', 'Right', 'Right']);
      expect(w.at, (x: 7, y: 4));
      expect(w.onRoute, isFalse, reason: 'arrived');
      expect(w.walking, isFalse, reason: 'and stopped its own timer');

      // Nothing further, however often it is asked.
      expect(w.step().ok, isFalse);
      expect(collector.steps.length, 3);
    });

    test('the direction is derived from the tiles, not carried alongside them', () {
      final w = build()..noteRoster(_at(4, 4));
      w.follow([(x: 4, y: 4), (x: 4, y: 3), (x: 5, y: 3), (x: 5, y: 4)]);
      w.step();
      w.step();

      expect(collector.steps, ['Up', 'Right', 'Down']);
    });

    test('a tap while already walking replaces the old route', () {
      final w = build()..noteRoster(_at(4, 4));
      w.follow(east(4, 4, 9));
      w.follow([(x: 5, y: 4), (x: 5, y: 5)]);

      // One step east from the first route, then the second route takes over — and
      // it is walked from where that step left us rather than from the tile the tap
      // was made on.
      expect(collector.steps, ['Right', 'Down']);
      expect(w.at, (x: 5, y: 5));
      expect(w.onRoute, isFalse);
    });

    test('reaching for the D-pad cancels the route', () {
      // Manual input beats autopilot. Two things stepping one avatar would fight,
      // and the person holding the phone is the one who changed their mind.
      final w = build()..noteRoster(_at(4, 4));
      w.follow(east(4, 4, 9));
      expect(w.onRoute, isTrue);

      w.press('Up');
      expect(w.onRoute, isFalse);
      expect(collector.steps, ['Right', 'Up']);

      w.step();
      expect(collector.steps, ['Right', 'Up', 'Up'], reason: 'the pad has it now');
    });

    test('a chair moved into the route abandons the rest of it', () {
      // The desktop client re-runs its pathfinder every tick and would walk around.
      // This stops instead, because a route walked from a floor plan that has since
      // changed is a route to somewhere nobody asked for. Tapping again re-plans.
      final w = build()..noteRoster(_at(4, 4));
      w.follow(east(4, 4, 8));
      expect(collector.steps, ['Right']);

      map = _obstructed(); // a wall now stands on the west side of column 9
      w.noteRoster(_at(8, 4));

      expect(w.step().ok, isFalse);
      expect(w.onRoute, isFalse);
      expect(w.walking, isFalse);
      expect(collector.steps, ['Right'], reason: 'nothing more went out');
    });

    test('a roster that puts us off the route stops the walk', () {
      // The desktop client moved this same avatar, or a step was dropped. Either way
      // the remaining tiles are relative to a tile we are not standing on, and
      // walking them would take somebody somewhere they never asked to go.
      final w = build()..noteRoster(_at(4, 4));
      w.follow(east(4, 4, 9));

      w.noteRoster(_at(12, 17));
      expect(w.step(), (ok: false, detail: 'lost the way there'));
      expect(w.onRoute, isFalse);
      expect(collector.steps, ['Right']);
    });

    test('a roster that has merely not caught up does not stop the walk', () {
      // The ordinary case, and the one the previous test must not swallow: the
      // roster is coalesced at 250ms and a route runs at seven tiles a second, so it
      // is always describing a tile we left. `_pending` already knows that.
      final w = build()..noteRoster(_at(4, 4));
      w.follow(east(4, 4, 8));
      w.step();
      w.step();
      expect(w.at, (x: 7, y: 4));

      w.noteRoster(_at(5, 4)); // two steps behind
      expect(w.at, (x: 7, y: 4), reason: 'a tile we claimed is not a correction');
      expect(w.step().ok, isTrue);
      expect(collector.steps, ['Right', 'Right', 'Right', 'Right']);
      expect(w.onRoute, isFalse);
    });

    test('a route is not dropped for outlasting the hold limit', () {
      // A finite list ends itself. The limit is there for a pointer that never
      // lifted, and the longest route this floor can produce is within a tile or two
      // of thirty seconds' walking.
      var now = DateTime(2026, 8, 13, 9);
      final w = walk = Walk(
        collector: () => collector,
        map: () => map,
        interval: const Duration(hours: 1),
        holdLimit: const Duration(seconds: 30),
        now: () => now,
      )..noteRoster(_at(4, 4));

      w.follow(east(4, 4, 7));
      now = now.add(const Duration(minutes: 5));

      expect(w.step().ok, isTrue);
      expect(w.onRoute, isTrue);
    });

    test('the end of a route is announced, so a screen can stop saying "Stop"', () {
      // The roster that follows the last step is up to a quarter of a second behind
      // it, and the map's pill offers to cancel the walk for exactly as long as one
      // is running.
      var ended = 0;
      final w = walk = Walk(
        collector: () => collector,
        map: () => map,
        interval: const Duration(hours: 1),
        onRouteEnded: () => ended++,
      )..noteRoster(_at(4, 4));

      w.follow(east(4, 4, 6));
      expect(ended, 0, reason: 'still walking');

      w.step();
      expect(w.onRoute, isFalse);
      expect(ended, 1, reason: 'arrived');

      // Not on a held direction being let go — nothing was routed.
      w.press('Up');
      w.release();
      expect(ended, 1);
    });

    test('a route that only names the tile we are on is not a walk', () {
      final w = build()..noteRoster(_at(4, 4));
      w.follow([(x: 4, y: 4)]);

      expect(collector.steps, isEmpty);
      expect(w.onRoute, isFalse);
      expect(w.walking, isFalse);
    });

    test('a step the socket refuses ends the route rather than walking on', () {
      final w = build()..noteRoster(_at(4, 4));
      collector.refuse = true;
      w.follow(east(4, 4, 8));

      expect(collector.steps, isEmpty);
      expect(w.onRoute, isFalse);
      expect(w.at, (x: 4, y: 4), reason: 'and nothing was believed');
    });
  });
}
