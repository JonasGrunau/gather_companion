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

  test('somebody moving quicker than a walk is not left gliding behind the wire', () {
    // The slow flight. Measured off a real space: movement arrives one tile per
    // patch at a median of 144ms — `MOVEMENT_DURATION` exactly — but in bursts that
    // run to 18.8 tiles a second, nearly three times that. A leg held to walking
    // pace then outlasts the roster behind it: three tiles takes 429ms while the
    // next roster lands in 250ms, so the body finished 1.75 tiles short and set off
    // again from there. Four rosters in, the wire said 12 and the map drew 5.25 —
    // a body gliding slowly towards somewhere it had already arrived.
    motion.update([_at(0, 2)]);
    for (var i = 1; i <= 4; i++) {
      now += const Duration(milliseconds: 250);
      motion.update([_at(i * 3.0, 2)]);
    }

    // One burst behind, which is what interpolating between reported tiles *is*.
    expect(motion.positionOf(_at(12, 2), now).dx, 9);
    now += const Duration(milliseconds: 250);
    expect(motion.positionOf(_at(12, 2), now).dx, 12, reason: 'caught up, not creeping');
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

  group('teleporting', () {
    test('a hop we fired ourselves never travels, however short it is', () {
      // The whole bug, in one case. Three tiles is well inside `snapBeyond`, so the
      // distance test would have walked it — 429ms of a body gliding over the desks
      // between here and there. We know it was a teleport because we sent it.
      motion.update([_at(4, 2)]);
      now = const Duration(seconds: 1);
      motion.teleported('a', const Offset(7, 2));

      expect(motion.positionOf(_at(7, 2), now), const Offset(7, 2));
      expect(motion.walking(_at(7, 2), now), isFalse, reason: 'a teleport is not a walk');
    });

    test('the tiles that follow a hop cannot drag the body back', () {
      // Why the pin exists. The roster is coalesced over 250ms and positions arrive
      // component-wise, so the rosters landing just after a hop can still be naming
      // the tile it left — or half of the one it went to.
      motion.update([_at(4, 2)]);
      now = const Duration(seconds: 1);
      motion.teleported('a', const Offset(40, 30));

      now += const Duration(milliseconds: 100);
      motion.update([_at(4, 2)]);
      expect(motion.positionOf(_at(4, 2), now), const Offset(40, 30));

      // The half-applied one: x has landed, y has not.
      now += const Duration(milliseconds: 100);
      motion.update([_at(40, 2)]);
      expect(motion.positionOf(_at(40, 2), now), const Offset(40, 30));
      expect(motion.walking(_at(40, 2), now), isFalse);
    });

    test('a roster that agrees ends it, and a later step is walked normally', () {
      motion.update([_at(4, 2)]);
      now = const Duration(seconds: 1);
      motion.teleported('a', const Offset(40, 30));

      now += const Duration(milliseconds: 100);
      motion.update([_at(40, 30)]); // Gather confirms; the pin has nothing left to do.

      now += const Duration(seconds: 1);
      motion.update([_at(41, 30)]); // and walking away from there is just walking.
      now += const Duration(microseconds: 71428);
      expect(motion.positionOf(_at(41, 30), now).dx, closeTo(40.5, 0.01));
    });

    test('once the pin runs out Gather is right and we are wrong', () {
      // A destination Gather never confirms is a destination we are wrong about, and
      // holding it forever would leave a body standing somewhere it is not.
      motion.update([_at(4, 2)]);
      now = const Duration(seconds: 1);
      motion.teleported('a', const Offset(7, 2));

      now += const Duration(milliseconds: 500); // past `teleportPin`
      motion.update([_at(4, 2)]);
      expect(motion.walking(_at(4, 2), now), isTrue, reason: 'giving the tile back');
      now += const Duration(seconds: 1);
      expect(motion.positionOf(_at(4, 2), now), const Offset(4, 2));
    });

    test('a jump nobody told us about is still a teleport', () {
      // Somebody else running party mode from their own phone. We were not told, so
      // the client's own eight-tile test is what decides — and it now dissolves them
      // rather than silently moving them.
      motion.update([_at(4, 2)]);
      now = const Duration(seconds: 1);
      motion.update([_at(4, 20)]);

      expect(motion.positionOf(_at(4, 20), now), const Offset(4, 20));
      expect(motion.flashOf(_at(4, 20), now)?.ghostAt, const Offset(4, 2));
    });

    test('the body they left dissolves while the new one arrives', () {
      motion.update([_at(4, 2)]);
      now = const Duration(seconds: 1);
      motion.teleported('a', const Offset(40, 30));

      final start = motion.flashOf(_at(40, 30), now)!;
      expect(start.ghostAt, const Offset(4, 2));
      expect(start.ghostAlpha, closeTo(1, 0.01), reason: 'still solid where it was');
      expect(start.alpha, closeTo(0, 0.01));
      expect(start.scale, closeTo(0.7, 0.01), reason: 'not from nothing');

      // The arrival is the shorter of the two and finishes first.
      now += teleportIn;
      final landed = motion.flashOf(_at(40, 30), now)!;
      expect(landed.alpha, 1);
      expect(landed.scale, 1);
      expect(landed.ghostAlpha, lessThan(0.2), reason: 'nearly gone by now');

      // And the whole thing is over inside a hop, or a party stacks them.
      expect(teleportOut, lessThan(const Duration(milliseconds: 250)));
      now += teleportOut;
      expect(motion.flashOf(_at(40, 30), now), isNull);
    });

    test('somebody we have never drawn arrives without leaving anywhere', () {
      // There is no tile to dissolve on: walking a ghost in from wherever the last
      // person in this slot stood is the same invention `update` refuses to make.
      motion.teleported('a', const Offset(9, 9));
      expect(motion.positionOf(_at(9, 9), now), const Offset(9, 9));
      expect(motion.flashOf(_at(9, 9), now), isNull);
    });

    test('a hop is drawn once, however often the screen rebuilds', () {
      motion.noteTeleport(null); // the screen's first build, with nothing to say
      motion.update([_at(4, 2)]);
      now = const Duration(seconds: 1);
      const hop = (id: 'a', x: 40.0, y: 30.0, seq: 1);

      motion.noteTeleport(hop);
      expect(motion.flashOf(_at(40, 30), now), isNotNull);

      now += teleportOut;
      motion.noteTeleport(hop); // the same build, or the next one, or a pinch
      expect(motion.flashOf(_at(40, 30), now), isNull, reason: 'already drawn');
    });

    test('a hop that happened before the map opened is history, not news', () {
      // Otherwise a map opened after a party has run draws its last hop as though it
      // had just happened, and pins a body to a tile it left minutes ago.
      motion.update([_at(4, 2)]);
      now = const Duration(seconds: 1);
      motion.noteTeleport((id: 'a', x: 40.0, y: 30.0, seq: 57));

      expect(motion.positionOf(_at(4, 2), now), const Offset(4, 2));
      expect(motion.flashOf(_at(4, 2), now), isNull);

      // The next one is live, and is drawn.
      motion.noteTeleport((id: 'a', x: 41.0, y: 31.0, seq: 58));
      expect(motion.positionOf(_at(4, 2), now), const Offset(41, 31));
    });

    test('with animations turned off a teleport is just the new tile', () {
      motion.update([_at(4, 2)]);
      now = const Duration(seconds: 1);
      motion.enabled = false;
      motion.teleported('a', const Offset(40, 30));

      expect(motion.positionOf(_at(40, 30), now), const Offset(40, 30));
      expect(motion.flashOf(_at(40, 30), now), isNull);
    });
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
