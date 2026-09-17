/// [VoiceActivity] — the decision behind the speaking ring.
///
/// It is pure so that it can be tested here rather than on a device with a
/// stopwatch, which is the whole reason the level and the clock are arguments.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/media/voice_activity.dart';

void main() {
  final t0 = DateTime.utc(2026, 9, 17, 12);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  late VoiceActivity voice;

  setUp(() {
    voice = VoiceActivity(
      onLevel: 0.012,
      offLevel: 0.006,
      hold: const Duration(milliseconds: 900),
    );
  });

  test('a quiet room is not somebody talking', () {
    // The floor measured on the phone on 2026-09-17, two orders of magnitude
    // under the threshold. If this ever starts passing as speech, the ring is
    // lit for anybody holding a phone in a silent room.
    expect(voice.note(0.00104, at(0)), isFalse);
    expect(voice.speaking, isFalse);
  });

  test('speech starts the ring on the first loud sample', () {
    expect(voice.note(0.08, at(0)), isTrue);
    expect(voice.speaking, isTrue);
    // Already on: a second loud sample is not a change, and reporting it as one
    // would put a `startSpeaking` on the wire five times a second.
    expect(voice.note(0.09, at(200)), isFalse);
  });

  test('a pause between words does not put the ring out', () {
    voice.note(0.08, at(0));

    // 800ms of silence — longer than the gap in "that's right", shorter than the
    // hold. Without the hold this is where the ring would strobe.
    for (var ms = 200; ms <= 800; ms += 200) {
      expect(voice.note(0.0005, at(ms)), isFalse, reason: 'at $ms ms');
    }
    expect(voice.speaking, isTrue);
  });

  test('the ring goes out once the quiet has lasted the whole hold', () {
    voice.note(0.08, at(0));
    voice.note(0.0005, at(200));

    expect(voice.note(0.0005, at(1000)), isFalse, reason: '800 ms is not 900');
    expect(voice.note(0.0005, at(1100)), isTrue);
    expect(voice.speaking, isFalse);
  });

  test('a word inside the hold restarts it rather than shortening it', () {
    voice.note(0.08, at(0));
    voice.note(0.0005, at(200));
    voice.note(0.08, at(600));

    // The word at 600 threw the quiet clock away, so it restarts at the next
    // quiet sample — 800, not 200. The hold is therefore up at 1700 and the
    // original 1100 deadline means nothing any more.
    expect(voice.note(0.0005, at(800)), isFalse);
    expect(voice.note(0.0005, at(1100)), isFalse);
    expect(voice.note(0.0005, at(1650)), isFalse);
    expect(voice.note(0.0005, at(1700)), isTrue);
  });

  test('the dead zone between the thresholds holds whatever the answer was', () {
    // 0.009 is above `offLevel` and below `onLevel`: neither loud enough to
    // start nor quiet enough to count towards stopping. Room tone with somebody
    // moving in it lives here, and a single threshold would chatter across it.
    expect(voice.note(0.009, at(0)), isFalse);
    expect(voice.speaking, isFalse);

    voice.note(0.08, at(200));
    for (var ms = 400; ms <= 4000; ms += 200) {
      expect(voice.note(0.009, at(ms)), isFalse, reason: 'at $ms ms');
    }
    expect(voice.speaking, isTrue,
        reason: 'the hold never started, because it never got quiet');
  });

  test('a missing sample is quiet, not silence', () {
    voice.note(0.08, at(0));

    // One poll that could not answer — the platform channel was busy, or the
    // producer went away for a frame. It counts towards the hold like any other
    // quiet sample, and on its own changes nothing.
    expect(voice.note(null, at(200)), isFalse);
    expect(voice.speaking, isTrue);
    expect(voice.note(null, at(1200)), isTrue);
    expect(voice.speaking, isFalse);
  });

  test('a mute stops it at once, without waiting out the hold', () {
    voice.note(0.08, at(0));

    expect(voice.silence(), isTrue);
    expect(voice.speaking, isFalse);
    // Nothing to report the second time.
    expect(voice.silence(), isFalse);
  });

  test('the hold restarts cleanly after a silence', () {
    voice.note(0.08, at(0));
    voice.silence();

    voice.note(0.08, at(200));
    // If `silence` had left the quiet clock at 0, this would fire immediately.
    expect(voice.note(0.0005, at(400)), isFalse);
    expect(voice.note(0.0005, at(1400)), isTrue);
  });
}
