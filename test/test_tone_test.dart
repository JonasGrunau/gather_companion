/// [chimeWav] — the speaker test's sound, made in code.
///
/// Pure bytes, so the one thing that can be checked without a speaker — that it
/// is a well-formed WAV of the right size — is checked here rather than by ear.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/media/test_tone.dart';

String _tag(Uint8List b, int o) => String.fromCharCodes(b.sublist(o, o + 4));
int _u32(Uint8List b, int o) =>
    ByteData.sublistView(b, o, o + 4).getUint32(0, Endian.little);
int _u16(Uint8List b, int o) =>
    ByteData.sublistView(b, o, o + 2).getUint16(0, Endian.little);

void main() {
  test('every variant is a canonical mono 16-bit 44.1k WAV', () {
    for (var v = 0; v < variantCount; v++) {
      final wav = chimeWav(variant: v);

      expect(_tag(wav, 0), 'RIFF', reason: 'variant $v');
      expect(_tag(wav, 8), 'WAVE');
      expect(_tag(wav, 12), 'fmt ');
      expect(_u16(wav, 20), 1, reason: 'PCM');
      expect(_u16(wav, 22), 1, reason: 'mono');
      expect(_u32(wav, 24), 44100, reason: 'sample rate');
      expect(_u16(wav, 34), 16, reason: 'bits per sample');
      expect(_tag(wav, 36), 'data');

      // The two length fields agree with the buffer: data chunk, then the whole
      // RIFF size, which is 36 bytes of header past the data.
      final dataLen = _u32(wav, 40);
      expect(wav.length, 44 + dataLen);
      expect(_u32(wav, 4), 36 + dataLen);
    }
  });

  test('an out-of-range variant wraps rather than throwing', () {
    expect(() => chimeWav(variant: variantCount + 3), returnsNormally);
    // Same sound as its wrapped index, byte for byte.
    expect(chimeWav(variant: variantCount), chimeWav(variant: 0));
  });

  test('the sound is not silence', () {
    final wav = chimeWav(variant: 0);
    final data = ByteData.sublistView(wav, 44);
    var loud = false;
    for (var o = 0; o + 1 < data.lengthInBytes; o += 2) {
      if (data.getInt16(o, Endian.little).abs() > 1000) {
        loud = true;
        break;
      }
    }
    expect(loud, isTrue);
  });
}
