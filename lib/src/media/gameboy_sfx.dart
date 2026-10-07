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
/// **Route is chosen by call state, and never re-chosen mid-call** (see
/// `lib/ui/AGENTS.md` and `media_check_screen.dart`'s `_deviceToneContext`): on
/// iOS the `AVAudioSession` is process-global, so the one thing that must never
/// happen is a *category or route change* while a call owns it — that flaps the
/// voice-processing unit (the device-syslog freeze AGENTS.md documents came from
/// hundreds of such changes a second). So, **idle** (no call holding the
/// session), the context is set to `playAndRecord` + `mixWithOthers` +
/// `defaultToSpeaker`, which actually puts the blip out the loudspeaker rather
/// than the earpiece `playAndRecord` would otherwise pick. **In a call**, the
/// session is left exactly as the call set it: we play on whatever context is
/// already applied and do **not** reconfigure. All of it rides `mixWithOthers`,
/// on this player only, so the blip sounds alongside a call and is never fed into
/// the WebRTC mic track.
///
/// To keep even the *first* blip off the call's session, [prewarm] builds the
/// player and pins its context when Gameboy mode (or the sound-effects switch) is
/// turned on — an idle moment — so by the time a call is up there is nothing left
/// to configure.
class GameboySfx {
  GameboySfx._();
  static final GameboySfx instance = GameboySfx._();

  AudioPlayer? _player;
  final _cache = <GbSound, Uint8List>{};

  /// Serialises stop/play (and the one-time context set) so two fast presses
  /// cannot interleave — without this, concurrent calls can reorder a `stop()`
  /// past the `play()` it was meant to precede.
  Future<void> _queue = Future<void>.value();

  /// Idle: force the loudspeaker. Safe because no call holds the session, and
  /// `playAndRecord` alone would route a blip to the earpiece.
  static final AudioContext _speakerContext = _contextWith(speaker: true);

  /// In a call: no forced route. Set only if the player has never been
  /// configured; once a call owns the session we ride whatever it chose.
  static final AudioContext _callSafeContext = _contextWith(speaker: false);

  static AudioContext _contextWith({required bool speaker}) => AudioContext(
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playAndRecord,
          options: {
            AVAudioSessionOptions.mixWithOthers,
            AVAudioSessionOptions.allowBluetooth,
            if (speaker) AVAudioSessionOptions.defaultToSpeaker,
          },
        ),
        android: const AudioContextAndroid(
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.assistanceSonification,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
      );

  /// Sound [sound], unless [enabled] is false (the Sound effects setting is off),
  /// in which case this is a no-op. [inCall] is the caller's live call state: it
  /// picks the speaker route when idle and, crucially, suppresses any session
  /// reconfiguration while a call holds the shared audio session. Best-effort: a
  /// failed blip is logged and swallowed so it can never break the interaction it
  /// accompanies. Calls are serialised, so rapid presses cannot interleave.
  Future<void> play(
    GbSound sound, {
    required bool enabled,
    required bool inCall,
  }) async {
    if (!enabled) return;
    final op = _queue.then((_) => _playNow(sound, inCall: inCall));
    // Keep the chain alive even when a blip throws, so one failure does not wedge
    // every sound after it.
    _queue = op.catchError((_) {});
    return op;
  }

  /// Builds the player and pins its audio context **now**, so the first blip
  /// during a later call never has to call `setAudioContext` on the session the
  /// call owns. Meant to be called at an idle moment — when Gameboy mode or the
  /// sound-effects switch is turned on — where reconfiguring the session is free;
  /// pass the current [inCall] so a warm-up that does land mid-call still picks
  /// the call-safe, no-route context. Serialised with [play] and idempotent once
  /// warmed, so calling it more than once is harmless.
  Future<void> prewarm({required bool inCall}) {
    final op = _queue.then((_) => _ensurePlayer(inCall: inCall));
    _queue = op.then((_) {}).catchError((_) {});
    return _queue;
  }

  Future<void> _playNow(GbSound sound, {required bool inCall}) async {
    try {
      final player = await _ensurePlayer(inCall: inCall);
      final bytes = _cache[sound] ??= gbSoundWav(sound);
      // Stop any still-ringing blip first: presses come faster than a note's
      // tail, and restarting is snappier than letting them queue.
      await player.stop();
      await player.play(BytesSource(bytes, mimeType: 'audio/wav'));
    } on Object catch (error) {
      debugPrint('gameboy-sfx: could not play $sound: $error');
    }
  }

  Future<AudioPlayer> _ensurePlayer({required bool inCall}) async {
    final player = _player ??= await _createPlayer();
    // Idle is the only time it is safe to (re)configure the shared session, and
    // the only time we know enough to: the process-global `AVAudioSession` can be
    // re-routed out from under us by the call or the media check, so a cached flag
    // cannot prove the current route. We therefore reassert the speaker context on
    // every idle play rather than trusting `_appliedSpeaker` — reconfiguring is
    // safe while no call owns the session, and otherwise a blip after a call would
    // be stuck on the earpiece/prior route. In a call we ride whatever the call
    // set and never reconfigure; first-ever mid-call use already seeded the
    // call-safe context in _createPlayer.
    if (!inCall) {
      await player.setAudioContext(_speakerContext);
    }
    return player;
  }

  Future<AudioPlayer> _createPlayer() async {
    final player = AudioPlayer();
    await player.setReleaseMode(ReleaseMode.stop);
    // Seed with the call-safe (no-route) context so the very first blip — even if
    // it lands mid-call — never forces a route. Idle playback upgrades to the
    // speaker route in _ensurePlayer.
    await player.setAudioContext(_callSafeContext);
    return player;
  }

  /// For tests and teardown; the app itself keeps the one player for its life.
  @visibleForTesting
  Future<void> dispose() async {
    await _player?.dispose();
    _player = null;
    _queue = Future<void>.value();
    _cache.clear();
  }
}
