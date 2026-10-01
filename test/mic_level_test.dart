/// [meterFraction] — the microphone level bar's shape.
///
/// Pure arithmetic, tested here rather than against a device, exactly as
/// `VoiceActivity` is and for the same reason.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/media/mic_level.dart';

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
}
