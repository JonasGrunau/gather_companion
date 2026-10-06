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

    // Ada stops; Grace is talking. Ada keeps the big view while Grace counts —
    // the handoff is one face replacing another, not a bounce through the grid —
    // and Grace has to hold the floor the full dwell before she takes it over.
    expect(director.update({'grace'}, at(2000)).target, 'ada',
        reason: 'the last speaker lingers big while the next one counts');
    expect(director.update({'grace'}, at(3000)).target, 'ada',
        reason: 'still inside Grace\'s dwell — Ada holds the view');

    final r = director.update({'grace'}, at(3500));
    expect(r.target, 'grace');
    expect(r.promoted, isTrue);
  });

  test('a silent big view lingers, then falls back to the grid after the linger', () {
    final d = SpotlightDirector(
      dwell: const Duration(milliseconds: 1500),
      linger: const Duration(seconds: 5),
    );
    d.update({'ada'}, at(0));
    expect(d.update({'ada'}, at(1500)).target, 'ada');

    // Everyone stops. The silence clock starts at the first quiet sample (2000),
    // and Ada stays enlarged through the pause between turns...
    expect(d.update(const {}, at(2000)).target, 'ada', reason: 'just gone quiet');
    expect(d.update(const {}, at(4000)).target, 'ada', reason: '2s of silence, still up');
    expect(d.update(const {}, at(6999)).target, 'ada', reason: 'one ms short of the linger');

    // ...until the lull runs the full linger from when it began (2000 + 5000),
    // when the view finally falls back to the overview grid.
    final r = d.update(const {}, at(7000));
    expect(r.target, isNull, reason: 'linger elapsed — back to the grid');
    expect(r.promoted, isFalse);
  });

  test('a short lull does not reset the linger clock when it is the target talking', () {
    // Silence runs from 1500. Ada says one more word at 3000 and stops again:
    // because it is Ada — the target — she is sticky, which clears the silence
    // clock, so the linger restarts from her last word rather than carrying over.
    final d = SpotlightDirector(linger: const Duration(seconds: 5));
    d.update({'ada'}, at(0));
    d.update({'ada'}, at(1500));
    d.update(const {}, at(3000)); // 1.5s of silence
    expect(d.update({'ada'}, at(3000)).target, 'ada', reason: 'Ada talks again');
    // Silence clock restarts at 4000; still up at 8000 (4s in), gone at 9000.
    expect(d.update(const {}, at(4000)).target, 'ada');
    expect(d.update(const {}, at(8000)).target, 'ada', reason: '4s into the fresh lull');
    expect(d.update(const {}, at(9000)).target, isNull, reason: '5s — back to grid');
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

  test('timeToFallback counts down the silent big view and clears on handoff and reset', () {
    final d = SpotlightDirector(linger: const Duration(seconds: 5));
    expect(d.timeToFallback(at(0)), isNull, reason: 'no target, nothing lingering');

    d.update({'ada'}, at(0));
    d.update({'ada'}, at(1500));
    expect(d.timeToFallback(at(1500)), isNull, reason: 'Ada is talking, not silent');

    // Silence from 1500: five seconds on the clock, counting down.
    d.update(const {}, at(1500));
    expect(d.timeToFallback(at(2500)), const Duration(seconds: 4));
    expect(d.timeToFallback(at(6500)), Duration.zero);

    // A new speaker taking the floor clears it...
    d.update({'grace'}, at(2000));
    d.update({'grace'}, at(3500)); // promotes Grace
    expect(d.timeToFallback(at(3500)), isNull, reason: 'Grace is talking now');

    // ...and so does a reset.
    d.update(const {}, at(4000));
    expect(d.timeToFallback(at(4500)), isNotNull);
    d.reset();
    expect(d.timeToFallback(at(5000)), isNull, reason: 'reset cleared the linger');
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
