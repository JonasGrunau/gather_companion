/// [SpotlightDirector] — who the big view follows in automatic mode.
///
/// Pure, like [VoiceActivity] beside it, so the dwell and the stickiness can be
/// tested here rather than on a device with three people and a stopwatch.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/media/spotlight_director.dart';

void main() {
  final t0 = DateTime.utc(2026, 10, 5, 12);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  late SpotlightDirector director;

  setUp(() {
    director = SpotlightDirector(dwell: const Duration(milliseconds: 1500));
  });

  test('nobody talking is the overview, not somebody enlarged', () {
    final r = director.update(const {}, at(0));
    expect(r.target, isNull);
    expect(r.promoted, isFalse);
    expect(director.target, isNull);
  });

  test('a speaker is not promoted until they have held the floor the whole dwell', () {
    // Talking from 0, but the view stays on the overview until 1500ms have passed.
    expect(director.update({'ada'}, at(0)).target, isNull);
    expect(director.update({'ada'}, at(900)).target, isNull, reason: '900 is not 1500');
    expect(director.update({'ada'}, at(1499)).target, isNull, reason: 'one ms short');

    final r = director.update({'ada'}, at(1500));
    expect(r.target, 'ada');
    expect(r.promoted, isTrue);
  });

  test('a brief interjection never earns the big view', () {
    // A one-word "yeah" at 0, gone by the next sample. The clock to promotion
    // never completes, so the view never moves.
    expect(director.update({'ada'}, at(0)).target, isNull);
    expect(director.update(const {}, at(400)).target, isNull);
    expect(director.target, isNull);
  });

  test('the target keeps the floor while they keep talking', () {
    director.update({'ada'}, at(0));
    final promoted = director.update({'ada'}, at(1500));
    expect(promoted.target, 'ada');

    // Grace starts talking over Ada. Ada still has the floor, so the view does
    // not move — this is the anti-jump the whole class exists for.
    final overlap = director.update({'ada', 'grace'}, at(2000));
    expect(overlap.target, 'ada');
    expect(overlap.promoted, isFalse);
  });

  test('the floor passes once the target stops and the next holds the dwell', () {
    director.update({'ada'}, at(0));
    director.update({'ada'}, at(1500));

    // Ada stops; Grace is talking. Ada loses the big view at once (overview),
    // and Grace has to hold the floor the full dwell before she takes it.
    expect(director.update({'grace'}, at(2000)).target, isNull,
        reason: 'the finished turn drops to the overview immediately');
    expect(director.update({'grace'}, at(3000)).target, isNull, reason: 'still inside Grace\'s dwell');

    final r = director.update({'grace'}, at(3500));
    expect(r.target, 'grace');
    expect(r.promoted, isTrue);
  });

  test('a second voice does not reset the clock on the one about to be promoted', () {
    // Ada has been counting towards the floor since 0. Grace pipes up at 1000;
    // Ada should still be promoted at 1500, not have her clock stolen.
    director.update({'ada'}, at(0));
    director.update({'ada', 'grace'}, at(1000));
    final r = director.update({'ada', 'grace'}, at(1500));
    expect(r.target, 'ada');
  });

  test('timeToPromote counts down the pending candidate and clears on promotion', () {
    expect(director.timeToPromote(at(0)), isNull, reason: 'nobody counting yet');

    director.update({'ada'}, at(0));
    expect(director.timeToPromote(at(500)), const Duration(milliseconds: 1000));
    expect(director.timeToPromote(at(1500)), Duration.zero);

    director.update({'ada'}, at(1500)); // promotes
    expect(director.timeToPromote(at(1600)), isNull, reason: 'promoted — nothing pending');
  });

  test('reset drops the target back to the overview', () {
    director.update({'ada'}, at(0));
    director.update({'ada'}, at(1500));
    expect(director.target, 'ada');

    director.reset();
    expect(director.target, isNull);
    expect(director.timeToPromote(at(2000)), isNull);
  });
}
