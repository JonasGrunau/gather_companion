/// [meterFraction] — the bar's shape — and [micLevel] — the raw-input level the
/// microphone check's light runs on.
///
/// Pure arithmetic, tested here rather than against a device, exactly as
/// `VoiceActivity` is and for the same reason.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/media/mic_level.dart';

/// A chunk of signed-16-bit little-endian PCM whose every sample is [value],
/// so the RMS is a known `|value| / 32768`.
Uint8List _pcm(int value, {int count = 256}) {
  final bytes = Uint8List(count * 2);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < count; i++) {
    data.setInt16(i * 2, value, Endian.little);
  }
  return bytes;
}

void main() {
  test('nothing to report draws empty', () {
    expect(meterFraction(null), 0);
    expect(meterFraction(0), 0);
  });

  test('the measured quiet-room floor sits at the bottom', () {
    // 0.00104 on the phone on 2026-09-17 — just under the meter floor, so empty.
    expect(meterFraction(0.00104), lessThan(0.05));
  });

  test('full scale fills the bar', () {
    expect(meterFraction(1), 1);
    expect(meterFraction(2), 1, reason: 'clamped, not extrapolated');
  });

  test('ordinary speech lands well up the bar', () {
    // Two orders of magnitude over the floor is most of the way up a log meter.
    expect(meterFraction(0.1), greaterThan(0.6));
  });

  test('it rises monotonically with level', () {
    expect(meterFraction(0.01), lessThan(meterFraction(0.05)));
    expect(meterFraction(0.05), lessThan(meterFraction(0.2)));
  });

  group('micLevel', () {
    test('an empty or odd-length chunk reads as silence, not a throw', () {
      expect(micLevel(Uint8List(0)), 0);
      expect(micLevel(Uint8List(1)), 0);
    });

    test('digital silence is zero', () {
      expect(micLevel(_pcm(0)), 0);
    });

    test('a constant chunk reads its fraction of full scale', () {
      expect(micLevel(_pcm(16384)), closeTo(0.5, 1e-4));
      expect(micLevel(_pcm(-16384)), closeTo(0.5, 1e-4));
      expect(micLevel(_pcm(32767)), closeTo(1.0, 1e-3));
    });

    test('it lands either side of the VoiceActivity thresholds', () {
      // The numbers that matter: a quiet room must read below `offLevel` (0.006)
      // and ordinary speech above `onLevel` (0.012), or the light judges wrong.
      expect(micLevel(_pcm(100)), lessThan(0.006), reason: 'quiet');
      expect(micLevel(_pcm(500)), greaterThan(0.012), reason: 'speech');
    });
  });
}
