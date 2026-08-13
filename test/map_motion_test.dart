/// The walk between the tiles.
///
/// This exists because Gather's positions are whole tiles — measured against a live
/// dump of the office, all 98 `SpaceUser` rows carry integer `position.x`/`y`, and
/// the model has no sub-tile field at all — while the roster this app reads is
/// coalesced at 250ms. Drawn literally, that is an office where everybody teleports
/// one or two tiles at a time, four times a second. Every rule here is transcribed
/// from `PlayerEntityV2`, which is the code that stops the desktop client doing the
/// same thing.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/map_motion.dart';
import 'package:gather_companion/src/map_person.dart';

MapPerson _at(double x, double y, {String id = 'a', bool speaking = false}) => MapPerson(
      id: id,
      label: 'Ada',
      x: x,
      y: y,
      isFollowingMe: false,
      speaking: speaking,
    );

void main() {
  late Duration now;
  late MapMotion motion;

  setUp(() {
    now = Duration.zero;
    motion = MapMotion(clock: () => now);
  });

  tearDown(() => motion.dispose());

  test('somebody seen for the first time stands where they are', () {
    // Walking them in from wherever the previous person in this slot stood would be
    // an invention, and on a reconnect it would be every person on the map at once.
    motion.update([_at(4, 2)]);
    expect(motion.positionOf(_at(4, 2), now), const Offset(4, 2));
    expect(motion.walking(_at(4, 2), now), isFalse);
  });

  test('a step is walked across, linearly, at seven tiles a second', () {
    motion.update([_at(4, 2)]);
    now = const Duration(seconds: 1);
    motion.update([_at(5, 2)]);

    // `MOVEMENT_DURATION = 1e3/7` — half of one tile's worth in.
    now += const Duration(microseconds: 71428);
    expect(motion.positionOf(_at(5, 2), now).dx, closeTo(4.5, 0.01));
    expect(motion.walking(_at(5, 2), now), isTrue);

    // `Phaser.Math.Linear`, so three-quarters of the way through is three-quarters of
    // the way there rather than eased past it.
    now += const Duration(microseconds: 35714);
    expect(motion.positionOf(_at(5, 2), now).dx, closeTo(4.75, 0.01));

    now += const Duration(milliseconds: 100);
    expect(motion.positionOf(_at(5, 2), now).dx, 5);
    expect(motion.walking(_at(5, 2), now), isFalse, reason: 'arrived, and standing');
  });

  test('a jump of more than eight tiles is a teleport, not a sprint', () {
    // `distance <= TILE_SIZE * 8` in `setTargetPosition`; past it the client calls
    // `teleport()`. It is what keeps a party-mode hop across the office reading as a
    // hop rather than as a body skating over the furniture.
    motion.update([_at(4, 2)]);
    now = const Duration(seconds: 1);
    motion.update([_at(4, 20)]);

    expect(motion.positionOf(_at(4, 20), now), const Offset(4, 20));
    expect(motion.walking(_at(4, 20), now), isFalse);
  });

  test('a walk that carries on is paced over the gap that reported it', () {
    // The roster is coalesced at 250ms, so somebody walking without stopping arrives
    // as bursts of one or two tiles rather than as a step every 143ms. Paced at the
    // nominal speed each burst would finish early and the body would stand still
    // between them — a limp. Paced over the gap, the bursts join up.
    motion.update([_at(0, 2)]);
    now = const Duration(seconds: 1);
    motion.update([_at(1, 2)]);

    // Still going when the next roster lands a quarter of a second later.
    now += const Duration(milliseconds: 250);
    motion.update([_at(2, 2)]);
    expect(motion.walking(_at(2, 2), now), isTrue);

    // A single tile at walking pace would be done in 143ms. This one is not.
    now += const Duration(milliseconds: 200);
    expect(motion.walking(_at(2, 2), now), isTrue, reason: 'still mid-stride');
    now += const Duration(milliseconds: 100);
    expect(motion.walking(_at(2, 2), now), isFalse);
  });

  test('a step that starts a walk is paced at Gather\'s own speed instead', () {
    // The other half of the rule: somebody who has been sitting still for a minute
    // and takes one step should take 143ms over it, not stretch it to fill however
    // long they had been idle.
    motion.update([_at(0, 2)]);
    now = const Duration(minutes: 1);
    motion.update([_at(1, 2)]);

    now += const Duration(milliseconds: 100);
    expect(motion.walking(_at(1, 2), now), isTrue);
    now += const Duration(milliseconds: 50);
    expect(motion.walking(_at(1, 2), now), isFalse, reason: '1e3/7 ms, and no longer');
  });

  test('with animations turned off bodies stand on the tiles the wire names', () {
    // `… && !prefersReducedMotion() && …` guards the client's own animate-or-teleport
    // test, so this is honouring the setting the way Gather does rather than
    // degrading for it.
    motion.update([_at(4, 2)]);
    now = const Duration(seconds: 1);
    motion.enabled = false;
    motion.update([_at(5, 2)]);

    expect(motion.positionOf(_at(5, 2), now), const Offset(5, 2));
    expect(motion.walking(_at(5, 2), now), isFalse);
  });

  test('people who have gone are forgotten', () {
    motion.update([_at(4, 2), _at(6, 6, id: 'b')]);
    motion.update([_at(4, 2)]);
    // Nothing observable to assert but the absence of a leak, so this asserts the
    // shape instead: somebody who comes back is new again rather than walking in
    // from where they logged off.
    now = const Duration(seconds: 1);
    motion.update([_at(4, 2), _at(9, 9, id: 'b')]);
    expect(motion.positionOf(_at(9, 9, id: 'b'), now), const Offset(9, 9));
  });

  test('the phase is per person, so nobody walks in lockstep', () {
    final ada = _at(0, 0, id: 'ada');
    final bram = _at(0, 0, id: 'bram');
    expect(motion.phaseOf(ada, now), isNot(motion.phaseOf(bram, now)));
    // Stable across frames: a phase re-rolled every paint is a body flickering
    // between animation frames rather than walking.
    expect(motion.phaseOf(ada, now), motion.phaseOf(ada, now));
  });
}
