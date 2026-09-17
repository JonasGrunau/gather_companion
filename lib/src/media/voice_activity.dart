/// Turns a microphone level into "is this person talking".
///
/// Gather draws the speaking ring from `SpaceUser.speaking`, a boolean its own
/// clients set with `startSpeaking` / `stopSpeaking`. Nothing on the media plane
/// produces it: the SFU carries the audio and says nothing about whether anybody
/// is using it, so a client that publishes perfectly and never sends these two
/// actions is audible to the room and invisible on it. That was this app until
/// now — the audio arrived on the desktop and the border never lit.
///
/// ## Why two thresholds and not one
///
/// A single threshold on a level that updates ten times a second produces a ring
/// that strobes through every pause between words. The pair below is ordinary
/// hysteresis: it takes [onLevel] to start and a drop below [offLevel] to be
/// considered stopping at all, and then [hold] of continuous quiet before the
/// answer actually changes.
///
/// [hold] is doing most of the work. Speech is mostly gaps — the stops in
/// "that's right" are longer than the poll interval — so without it the ring
/// would flicker at roughly syllable rate. Slightly under a second is long
/// enough to bridge a sentence and short enough that a finished turn does not
/// leave a stale ring glowing on somebody else's screen.
///
/// ## Where the numbers came from
///
/// `audioLevel` on the `media-source` stats row is linear, 0 to 1, where 1 is
/// full scale. Measured on the phone on 2026-09-17: a quiet room in a held hand
/// read **0.00104** (about −60 dBFS). Ordinary speech into a phone at arm's
/// length runs two orders of magnitude above that. So [onLevel] sits at 0.012
/// (about −38 dBFS), well clear of that floor, and [offLevel] at half of it.
///
/// These are deliberately *not* the `hark` defaults Gather's own web client
/// uses. `hark` thresholds in dB against an FFT bin maximum; this thresholds a
/// linear RMS-derived level from `getStats`. The two numbers are not comparable
/// and copying one across would only look like agreement.
library;

/// The talking/not-talking decision, as a small state machine.
///
/// Pure: no timers, no stats, no clock of its own. It is handed a level and a
/// time and says whether the answer changed. That is what lets the thresholds
/// above be tested at all — the alternative is a device and a stopwatch.
class VoiceActivity {
  VoiceActivity({
    this.onLevel = 0.012,
    this.offLevel = 0.006,
    this.hold = const Duration(milliseconds: 900),
  });

  /// Above this, somebody is talking.
  final double onLevel;

  /// Below this, they may have stopped — see [hold].
  final double offLevel;

  /// How long it has to stay quiet before "stopped" is believed.
  final Duration hold;

  bool _speaking = false;

  /// When the level last sat below [offLevel], or null if it is not quiet now.
  DateTime? _quietSince;

  bool get speaking => _speaking;

  /// Feeds in one measurement. Returns true when [speaking] flipped.
  ///
  /// A null [level] is "the stats did not say" and is treated as quiet rather
  /// than as silence: a producer that stops reporting has usually gone away, and
  /// the hold below means a single missing sample changes nothing.
  bool note(double? level, DateTime at) {
    final value = level ?? 0;

    if (value >= onLevel) {
      _quietSince = null;
      if (_speaking) return false;
      _speaking = true;
      return true;
    }

    if (value > offLevel) {
      // The dead zone between the two thresholds. Neither loud enough to start
      // nor quiet enough to begin counting towards a stop, so it holds whatever
      // the answer already was — which is the entire point of having two.
      return false;
    }

    final since = _quietSince ??= at;
    if (!_speaking) return false;
    if (at.difference(since) < hold) return false;
    _speaking = false;
    return true;
  }

  /// Stops, now, without waiting out [hold].
  ///
  /// For the moments where the answer is known rather than measured: a mute, a
  /// hang-up, a producer closing. Nobody should have to watch a ring fade out
  /// over the better part of a second after they pressed mute.
  bool silence() {
    _quietSince = null;
    if (!_speaking) return false;
    _speaking = false;
    return true;
  }
}
