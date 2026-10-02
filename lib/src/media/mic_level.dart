/// Turning raw microphone samples into a level, and that level into a bar.
///
/// The microphone check does not stand up a call to watch the meter — it reads
/// the input directly, the way a device-setup screen in Teams or Zoom does. That
/// gives raw PCM, and [micLevel] reduces a chunk of it to the same kind of number
/// the speaking ring runs on: a linear RMS, 0 to 1, where a quiet room reads near
/// the floor and speech two orders of magnitude above it. It is deliberately the
/// *same* currency the SFU path's `audioLevel` is in, so [VoiceActivity]'s
/// thresholds judge both without translation (see `voice_activity.dart`).
///
/// [meterFraction] is the log mapping for a drawn bar, kept for when a fuller
/// meter than the plain "we can hear you" light is wanted. Both are pure for the
/// same reason: the arithmetic is the thing worth testing, and a device is not
/// needed to test arithmetic.
library;

import 'dart:math';
import 'dart:typed_data';

/// The linear RMS level, 0 to 1, of one chunk of signed 16-bit little-endian PCM.
///
/// This is the raw-input counterpart to the SFU path's `media-source` audioLevel:
/// both are a linear root-mean-square of the signal, so [VoiceActivity]'s
/// thresholds — measured against that stat — apply here unchanged. An empty or
/// odd-length chunk reads as silence rather than throwing; a dropped buffer is
/// not a reason to flicker the light.
double micLevel(Uint8List pcm16le) {
  final count = pcm16le.length ~/ 2;
  if (count == 0) return 0;
  final data = ByteData.sublistView(pcm16le);
  var sumSquares = 0.0;
  for (var i = 0; i < count; i++) {
    final sample = data.getInt16(i * 2, Endian.little) / 32768.0;
    sumSquares += sample * sample;
  }
  return sqrt(sumSquares / count);
}

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
