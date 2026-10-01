/// Turning a raw microphone level into something a bar can draw.
///
/// The level that arrives from `getStats` is the same `audioLevel` the speaking
/// ring is built on: linear, 0 to 1, where a quiet room in a held hand reads
/// about 0.001 and ordinary speech two orders of magnitude above that (see
/// `voice_activity.dart` for where those numbers were measured). A bar drawn
/// straight off that linear value would sit dead against the floor and then leap
/// — all the interesting range lives in the bottom hundredth.
///
/// So the meter is logarithmic, like every level meter, and like the ear. This
/// is pure for the same reason [VoiceActivity] is: the mapping is the thing
/// worth testing, and a device is not needed to test arithmetic.
library;

import 'dart:math';

/// The quietest level the bar bothers to show, as a fraction of full scale.
/// Below this is the noise floor and draws as empty.
const _floor = 0.001; // ~−60 dBFS, the measured quiet-room reading.

/// [_floor] in decibels, the bottom of the bar's range. A negative number, so
/// the span from floor to full scale is `-_floorDb`.
final _floorDb = 20 * (log(_floor) / ln10);

/// A microphone level in `[0, 1]` mapped to a bar fill in `[0, 1]`.
///
/// Decibels between the [_floor] and full scale, rescaled to `[0, 1]`. A null
/// level — the stats said nothing — reads as silence, not as a held value: a
/// meter that freezes on its last reading when the numbers stop is a meter that
/// lies about a dead microphone.
double meterFraction(double? level) {
  final value = level ?? 0;
  if (value <= _floor) return 0;
  if (value >= 1) return 1;
  final db = 20 * (log(value) / ln10);
  return ((db - _floorDb) / -_floorDb).clamp(0.0, 1.0);
}
