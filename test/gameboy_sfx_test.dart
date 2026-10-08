/// [gbSoundWav] — the handheld's blips, made in code like the speaker chime.
///
/// Pure bytes, so the one thing checkable without a speaker — that each sound is
/// a well-formed WAV with something audible in it — is checked here rather than
/// by ear. The player ([GameboySfx]) is the impure half and is not exercised: it
/// needs a platform audio plugin a unit test does not have.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/media/gameboy_sfx.dart';

String _tag(Uint8List b, int o) => String.fromCharCodes(b.sublist(o, o + 4));
int _u32(Uint8List b, int o) =>
    ByteData.sublistView(b, o, o + 4).getUint32(0, Endian.little);
int _u16(Uint8List b, int o) =>
    ByteData.sublistView(b, o, o + 2).getUint16(0, Endian.little);

bool _hasSound(Uint8List wav) {
  final data = ByteData.sublistView(wav, 44);
  for (var o = 0; o + 1 < data.lengthInBytes; o += 2) {
    if (data.getInt16(o, Endian.little).abs() > 1000) return true;
  }
  return false;
}

void main() {
  test('every sound is a canonical mono 16-bit 44.1k WAV', () {
    for (final sound in GbSound.values) {
      final wav = gbSoundWav(sound);

      expect(_tag(wav, 0), 'RIFF', reason: '$sound');
      expect(_tag(wav, 8), 'WAVE', reason: '$sound');
      expect(_tag(wav, 12), 'fmt ', reason: '$sound');
      expect(_u16(wav, 20), 1, reason: '$sound: PCM');
      expect(_u16(wav, 22), 1, reason: '$sound: mono');
      expect(_u32(wav, 24), 44100, reason: '$sound: sample rate');
      expect(_u16(wav, 34), 16, reason: '$sound: bits per sample');
      expect(_tag(wav, 36), 'data', reason: '$sound');

      // The two length fields agree with the buffer: data chunk, then the whole
      // RIFF size, which is 36 bytes of header past the data.
      final dataLen = _u32(wav, 40);
      expect(wav.length, 44 + dataLen, reason: '$sound');
      expect(_u32(wav, 4), 36 + dataLen, reason: '$sound');
    }
  });

  test('every sound carries audible signal, none is silence', () {
    for (final sound in GbSound.values) {
      expect(_hasSound(gbSoundWav(sound)), isTrue, reason: '$sound');
    }
  });

  test('a sound is deterministic — same bytes every time', () {
    expect(gbSoundWav(GbSound.confirm), gbSoundWav(GbSound.confirm));
  });
}
