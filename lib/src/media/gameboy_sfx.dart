/// The handheld's voice: short chiptune blips, made in code like the speaker
/// test's chime rather than shipped as assets.
///
/// Gameboy mode dresses the office as a handheld, and a handheld that is silent
/// under the thumb reads as broken. These are the clicks and dings it answers
/// with — a cursor blip, a confirm, a back, toggles — each a **pulse wave**
/// (the Game Boy's square channel) rather than the sine the test chime uses, so
/// they land in the right decade of cheap-and-square.
///
/// Same bargain as `test_tone.dart`: a bundled sound would have to be found,
/// licensed and carried on both platforms for something that is up for a tenth
/// of a second, so this synthesises each as a 16-bit PCM WAV the playback layer
/// hands straight to the OS. The synth is **pure** — a [GbSound] in, bytes out,
/// no plugins and no clock — so the shape of each file can be asserted in
/// `flutter test` without a device or a speaker. [GameboySfx] is the thin,
/// impure layer that actually plays them.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// 44.1 kHz, matching the test chime — no reason to make the platform resample a
/// sound this short.
const _sampleRate = 44100;

/// Kept well under full scale. A square wave is already louder and harsher than a
/// sine at the same amplitude, so this sits lower than the chime's 0.3 — a blip
/// that clips reads as a crackle, which is the opposite of the crisp click it is
/// meant to be.
const _amplitude = 0.22;

/// The blips the handheld can make. Each maps to one event in the shell; the
/// pure [gbSoundWav] turns it into playable bytes and [GameboySfx.play] sounds
/// it.
enum GbSound {
  /// Menu cursor stepping to the next row or value. The most frequent sound, so
  /// the shortest and plainest.
  cursor,

  /// A choice landing — the A button, or a menu row acted on.
  confirm,

  /// Backing out — Start leaving the menu, or the menu closing.
  back,

  /// The Select menu opening.
  open,

  /// A switch going on: boost latched, or the mic coming back un-muted.
  toggleOn,

  /// A switch going off: boost released, or the mic muted.
  toggleOff,

  /// An action that failed (the snackbar path in the shell's `_run`).
  denied,

  /// The power-on jingle, sounded once when Gameboy mode is switched on.
  boot,

  /// The speaker test's chime, in the handheld's voice — the square-wave stand-in
  /// for `test_tone.dart`'s sine `chimeWav` while Gameboy mode is on.
  chime,
}

/// One pulse-wave note: a frequency held for [ms], at a [duty] cycle (0..1; 0.5
/// is a plain square, the narrower values give the thinner, more nasal Game Boy
/// timbre).
class _Note {
  const _Note(this.freq, this.ms, {this.duty = 0.5});
  final double freq;
  final int ms;
  final double duty;
}

/// The score for each [GbSound], top to bottom in the order the ear reads them.
/// Rising sets read as "yes/open/on", falling as "no/back/off", a single blip as
/// a tick, and the low held pair as a buzz.
const _scores = <GbSound, List<_Note>>{
  // C6 — a single bright tick, barely there.
  GbSound.cursor: [_Note(1046.50, 38, duty: 0.25)],
  // G5 → C6, a quick rise that says the thing happened.
  GbSound.confirm: [_Note(783.99, 46), _Note(1046.50, 66)],
  // G5 → C5, the same gesture falling, for leaving.
  GbSound.back: [_Note(783.99, 46), _Note(523.25, 66)],
  // C5 · E5 · G5, a little three-step climb as the menu comes up.
  GbSound.open: [_Note(523.25, 34), _Note(659.25, 34), _Note(783.99, 46)],
  // C6 → E6, up and brighter: a switch latching on.
  GbSound.toggleOn: [_Note(1046.50, 40), _Note(1318.51, 56)],
  // E6 → C6, the mirror, latching off.
  GbSound.toggleOff: [_Note(1318.51, 40), _Note(1046.50, 56)],
  // A low, square, slightly detuned pair — a flat "nope" buzz.
  GbSound.denied: [_Note(146.83, 90, duty: 0.5), _Note(123.47, 120, duty: 0.5)],
  // The boot "da-DING": a short low note then a held bright one an octave up.
  GbSound.boot: [_Note(523.25, 90), _Note(1046.50, 260, duty: 0.35)],
  // The test chime as an ascending pulse arpeggio — C5·E5·G5·C6, the chime's
  // own shape in the square channel.
  GbSound.chime: [
    _Note(523.25, 120),
    _Note(659.25, 120),
    _Note(783.99, 120),
    _Note(1046.50, 160),
  ],
};

/// A mono 16-bit PCM WAV of [sound], synthesised as pulse-wave notes run through
/// an attack/decay envelope so each starts and ends on silence rather than on a
/// click — a discontinuity at either end is a pop, and a pop against the ear is
/// loud and unpleasant.
Uint8List gbSoundWav(GbSound sound) {
  final notes = _scores[sound]!;
  final total = notes.fold<int>(0, (n, note) => n + _samplesFor(note.ms));

  final samples = Int16List(total);
  var o = 0;
  for (final note in notes) {
    final count = _samplesFor(note.ms);
    for (var i = 0; i < count; i++) {
      final t = i / _sampleRate;
      // Pulse wave: high for the first `duty` of each cycle, low for the rest.
      final phase = (note.freq * t) % 1.0;
      final square = phase < note.duty ? 1.0 : -1.0;
      final value = square * _envelope(i, count) * _amplitude;
      samples[o + i] = (value * 32767).round().clamp(-32768, 32767);
    }
    o += count;
  }

  return _wrapWav(samples);
}

int _samplesFor(int ms) => (_sampleRate * ms) ~/ 1000;

/// A 4 ms linear attack and an exponential decay over the rest of the note. The
/// attack is short enough to keep the percussive click of a struck key and long
/// enough that the waveform leaves zero smoothly; the decay is inaudible well
/// before the note ends.
double _envelope(int i, int length) {
  final attack = _sampleRate ~/ 250; // 4 ms
  if (i < attack) return i / attack;
  final afterAttack = (i - attack) / (length - attack);
  return exp(-5 * afterAttack);
}

/// Wraps PCM samples in the 44-byte canonical WAV header. (Kept local rather than
/// shared with `test_tone.dart` so each synth stays a self-contained, testable
/// unit; the header is 44 bytes of arithmetic.)
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

/// Plays [GbSound]s out the device speaker, and nowhere else.
///
/// A singleton with one reusable [AudioPlayer]: the bytes for each sound are
/// synthesised once and cached, and the audio session is pinned once, so a blip
/// is a cheap replay rather than a fresh file + session dance each press.
///
/// **Local-only.** These ride on their own player with `mixWithOthers`; they are
/// never fed into the WebRTC mic track, so the Gather backend and anyone else on
/// a call never hear them — including the mute cue. They are a cue for *you*.
///
/// **Why `mixWithOthers` and no route or global context** (see `lib/ui/AGENTS.md`
/// and `media_check_screen.dart`'s `_deviceToneContext`): on iOS, reconfiguring
/// the shared `AVAudioSession` — which `AudioPlayer.global.setAudioContext` or a
/// forced `defaultToSpeaker` would do — thrashes the voice-processing unit a live
/// call owns and can freeze the screen. So the context is set **once on this
/// player only**, as `playAndRecord` + `mixWithOthers`, forcing no route: the
/// blip plays alongside a call instead of wrestling the session from it.
class GameboySfx {
  GameboySfx._();
  static final GameboySfx instance = GameboySfx._();

  AudioPlayer? _player;
  final _cache = <GbSound, Uint8List>{};

  /// Set on the player once, then left alone. No `defaultToSpeaker` — forcing a
  /// route is exactly the session reconfiguration a live call cannot take.
  static final AudioContext _context = AudioContext(
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.playAndRecord,
      options: {
        AVAudioSessionOptions.mixWithOthers,
        AVAudioSessionOptions.allowBluetooth,
      },
    ),
    android: const AudioContextAndroid(
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.assistanceSonification,
      audioFocus: AndroidAudioFocus.gainTransientMayDuck,
    ),
  );

  /// Sound [sound], unless [enabled] is false (the Sound effects setting is off),
  /// in which case this is a no-op. Best-effort: a failed blip is logged and
  /// swallowed so it can never break the interaction it accompanies.
  Future<void> play(GbSound sound, {required bool enabled}) async {
    if (!enabled) return;
    try {
      final player = await _ensurePlayer();
      final bytes = _cache[sound] ??= gbSoundWav(sound);
      // Stop any still-ringing blip first: presses come faster than a note's
      // tail, and restarting is snappier than letting them queue.
      await player.stop();
      await player.play(BytesSource(bytes, mimeType: 'audio/wav'));
    } on Object catch (error) {
      debugPrint('gameboy-sfx: could not play $sound: $error');
    }
  }

  Future<AudioPlayer> _ensurePlayer() async {
    final existing = _player;
    if (existing != null) return existing;
    final player = AudioPlayer();
    await player.setReleaseMode(ReleaseMode.stop);
    await player.setAudioContext(_context);
    return _player = player;
  }

  /// For tests and teardown; the app itself keeps the one player for its life.
  @visibleForTesting
  Future<void> dispose() async {
    await _player?.dispose();
    _player = null;
    _cache.clear();
  }
}
