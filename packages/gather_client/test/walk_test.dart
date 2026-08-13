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
}
