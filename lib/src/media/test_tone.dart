/// A short sound to prove the speaker works, made in code rather than shipped.
///
/// The speaker test needs *something* to play, and the honest options were a
/// bundled audio file or a tone generated on the spot. A file would have to be
/// found, licensed, and carried in the bundle on both platforms for a sound
/// that is up for half a second — so this synthesises a little chime instead,
/// as a 16-bit PCM WAV the playback layer can hand straight to the OS.
///
/// It is deliberately pure — bytes in, bytes out, no plugins and no clock — so
/// the shape of the file (a valid RIFF header, the right number of samples) can
/// be asserted in `flutter test` without a device or a speaker.
///
/// ## Why a WAV and not raw PCM
///
/// `audioplayers` plays a byte source by writing it to a temp file and handing
/// the URL to the platform player, which sniffs the container. Raw PCM has no
/// container to sniff; a WAV is the smallest thing that does, and its header is
/// 44 bytes of arithmetic.
library;

import 'dart:math';
import 'dart:typed_data';

/// 44.1 kHz, the rate the iOS recorder writes too — no reason to make the
/// platform resample a test sound.
const _sampleRate = 44100;

/// Kept well under full scale. A chime that clips reads as the speaker
/// crackling, which is the opposite of the reassurance this is here to give.
const _amplitude = 0.3;

/// A handful of ascending note sets, so [chimeWav] can play a different one each
/// tap and the test does not sound like a stuck doorbell. Each rises, because a
/// chime that climbs reads as "working" where one that falls reads as an error.
const _palettes = <List<double>>[
  [523.25, 659.25, 783.99], // C5 · E5 · G5 — a C-major arpeggio
  [587.33, 880.00], // D5 · A5 — a bare fifth
  [659.25, 987.77], // E5 · B5
  [783.99, 1046.50], // G5 · C6 — up to the octave
];

/// How many distinct sounds [chimeWav] can make. The caller picks a [variant]
/// in `[0, variantCount)`; out-of-range values wrap.
int get variantCount => _palettes.length;

/// A mono 16-bit PCM WAV of a short rising chime.
///
/// Each note is a sine run through an attack/decay envelope so it starts and
/// ends on silence rather than on a click — a discontinuity at either end is a
/// pop, and a pop through the earpiece is loud and unpleasant right against the
/// ear.
Uint8List chimeWav({int variant = 0}) {
  final notes = _palettes[variant % _palettes.length];

  // Each note gets an equal slice; the whole chime lands around half a second.
  const noteMs = 200;
  final noteSamples = (_sampleRate * noteMs) ~/ 1000;
  final total = noteSamples * notes.length;

  final samples = Int16List(total);
  for (var n = 0; n < notes.length; n++) {
    final freq = notes[n];
    for (var i = 0; i < noteSamples; i++) {
      final t = i / _sampleRate;
      final env = _envelope(i, noteSamples);
      final value = sin(2 * pi * freq * t) * env * _amplitude;
      samples[n * noteSamples + i] = (value * 32767).round().clamp(-32768, 32767);
    }
  }

  return _wrapWav(samples);
}

/// A 10 ms linear attack and an exponential decay over the rest of the note.
///
/// The attack is short enough to still sound like a struck note and long enough
/// that the waveform leaves zero smoothly; the decay never quite reaches zero
/// but is inaudible long before the note ends.
double _envelope(int i, int length) {
  const attack = _sampleRate ~/ 100; // 10 ms
  if (i < attack) return i / attack;
  final afterAttack = (i - attack) / (length - attack);
  return exp(-4 * afterAttack);
}

/// Wraps PCM samples in the 44-byte canonical WAV header.
Uint8List _wrapWav(Int16List samples) {
  const channels = 1;
  const bitsPerSample = 16;
  const byteRate = _sampleRate * channels * bitsPerSample ~/ 8;
  const blockAlign = channels * bitsPerSample ~/ 8;
  final dataLength = samples.length * 2;

  final bytes = ByteData(44 + dataLength);
  var o = 0;
  void u32(int v) {
    bytes.setUint32(o, v, Endian.little);
    o += 4;
  }

  void u16(int v) {
    bytes.setUint16(o, v, Endian.little);
    o += 2;
  }

  void tag(String s) {
    for (final c in s.codeUnits) {
      bytes.setUint8(o++, c);
    }
  }

  tag('RIFF');
  u32(36 + dataLength);
  tag('WAVE');
  tag('fmt ');
  u32(16); // PCM fmt chunk size
  u16(1); // audioFormat = PCM
  u16(channels);
  u32(_sampleRate);
  u32(byteRate);
  u16(blockAlign);
  u16(bitsPerSample);
  tag('data');
  u32(dataLength);
  for (final sample in samples) {
    bytes.setInt16(o, sample, Endian.little);
    o += 2;
  }

  return bytes.buffer.asUint8List();
}
