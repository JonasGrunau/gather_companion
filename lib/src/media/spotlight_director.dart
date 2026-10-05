/// Picks whose face to enlarge in automatic mode, from who is talking.
///
/// The call screen's spotlight can follow the active speaker, and the one thing
/// that must not happen is for it to jump — a cough, a one-word "yeah", a scrape
/// of a chair all light the speaking ring for a moment, and a big view that
/// chased every one of them would be unwatchable. So promotion is gated two ways,
/// the same shape as [VoiceActivity] one level down:
///
///  * **Dwell.** A new speaker has to hold the floor for [dwell] before the view
///    moves to them. Shorter than that and they never become the target.
///  * **Sticky.** Once somebody is the target, they keep it for as long as they
///    keep talking. A second person talking over them does not steal it; the view
///    moves only once the current speaker actually stops and somebody else has
///    held the floor for the dwell. That is what turns "loudest wins, moment to
///    moment" into "the person with the floor", which is what a meeting actually
///    looks like.
///
/// Pure on purpose, exactly like [VoiceActivity]: no timers, no clock of its own.
/// It is handed the set of people speaking and the time, and it answers who to
/// show. The call screen owns the one timer that re-asks when a dwell elapses.
///
/// Self is never in the set it is handed — you do not get enlarged on your own
/// screen for talking — so that rule lives in the caller, not here.
library;

/// The automatic-spotlight decision, as a small state machine.
class SpotlightDirector {
  SpotlightDirector({this.dwell = const Duration(milliseconds: 1500)});

  /// How long a new speaker must hold the floor before the view moves to them.
  final Duration dwell;

  /// Who the view is on now, or null for the overview grid.
  String? _target;

  /// Who is counting towards becoming the target, and since when.
  String? _candidate;
  DateTime? _candidateSince;

  String? get target => _target;

  /// Feeds in who is speaking right now. Returns the id to enlarge — or null for
  /// the overview grid — and whether that was a *fresh* promotion, which is the
  /// signal the caller uses to drop a manual pin.
  ({String? target, bool promoted}) update(Set<String> speaking, DateTime now) {
    // Sticky: the current target keeps the floor while they keep talking, no
    // matter who else has started up alongside them.
    if (_target != null && speaking.contains(_target)) {
      _candidate = null;
      _candidateSince = null;
      return (target: _target, promoted: false);
    }

    // The target has gone quiet (or there was none). They lose the spotlight at
    // once — a finished turn should not leave a stale big view glowing — and the
    // screen falls back to the overview until somebody earns it.
    _target = null;

    if (speaking.isEmpty) {
      _candidate = null;
      _candidateSince = null;
      return (target: null, promoted: false);
    }

    final next = _pick(speaking);
    if (next != _candidate) {
      _candidate = next;
      _candidateSince = now;
    }

    if (now.difference(_candidateSince!) >= dwell) {
      _target = next;
      _candidate = null;
      _candidateSince = null;
      return (target: _target, promoted: true);
    }

    // Speaking, but not yet long enough to move the view.
    return (target: null, promoted: false);
  }

  /// Which speaker to count. Stays with whoever is already counting — so a brief
  /// second voice cannot reset the clock on the one who was about to be promoted
  /// — and otherwise takes the lowest id, so the same set always picks the same
  /// person rather than flickering between two.
  String _pick(Set<String> speaking) {
    final current = _candidate;
    if (current != null && speaking.contains(current)) return current;
    return (speaking.toList()..sort()).first;
  }

  /// How long until the pending candidate would be promoted, or null if nobody
  /// is counting. The call screen schedules its one timer off this, so promotion
  /// fires even when no further speaking change arrives to re-ask.
  Duration? timeToPromote(DateTime now) {
    final since = _candidateSince;
    if (since == null) return null;
    final left = dwell - now.difference(since);
    return left.isNegative ? Duration.zero : left;
  }

  /// Back to the overview, now. For the return button and for leaving auto mode.
  void reset() {
    _target = null;
    _candidate = null;
    _candidateSince = null;
  }
}
