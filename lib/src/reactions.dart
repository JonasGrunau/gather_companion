/// Who just threw an emoji, and everything still in the air.
///
/// Reactions arrive on the game socket's event bus as `EmoteEvent`, which is
/// news rather than state: nothing is written to any model, no patch follows,
/// and a client that only applies patches sees nothing at all. There is also no
/// "it ended" event — Gather's own clients pick the duration themselves — so the
/// expiry below is this app's, not the protocol's.
///
/// ## Every press is its own thing
///
/// This held one emoji per person first, and each press replaced the last. That
/// is wrong about what the button is for. Reacting is not a status somebody sets;
/// it is a thing they *do*, and doing it three times means three of them. Gather's
/// own client spawns one per press and lets them fly, which is why holding 👏
/// there reads as applause and here read as a single clap with a stuttering
/// timer.
///
/// So each press becomes a [ReactionFlight] with its own id and its own clock.
/// They overlap, they expire independently, and the screen animates each one from
/// wherever it is in its own life — a later arrival never restarts or hides an
/// earlier one.
///
/// ## Why it is not part of the roster
///
/// A reaction is over in a couple of seconds and belongs to a *moment*, while
/// the roster is a description of the room. Folding one into the other would
/// mean every reaction rewrote the roster, and every roster — four a second
/// while anybody is walking — would have to preserve a field nothing on the wire
/// carries. Keeping it separate is also what makes "show it instantly, before
/// the server echoes it back" possible for our own.
///
/// ## Why a timer per flight and not one clock
///
/// The obvious shape is an expiry time per entry and a single timer set to the
/// soonest. It was written that way first and it is subtly wrong: the timer runs
/// on the framework's clock and the expiry times were read from
/// `DateTime.now()`, so under anything that drives time — a widget test, and on
/// a phone a suspend — the two disagree and the sweep fires to find nothing due.
/// One timer per flight makes the timer *be* the expiry, with no second opinion
/// to fall out of step with.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

/// How long one emoji stays in the air.
///
/// The whole flight: the pop in at the bottom, the climb, and the fade at the
/// top. Long enough to follow across a glance at a phone, short enough that a
/// held button reads as a stream rather than as a crowd.
const reactionLinger = Duration(milliseconds: 2600);

/// One press, in flight.
///
/// [id] is what makes it its own: the screen keys each animation on it, so a new
/// arrival builds a new widget beside the others instead of rebuilding one of
/// them. It doubles as the seed for the sideways drift, which is what keeps two
/// simultaneous emoji from flying up the same line and hiding each other.
@immutable
class ReactionFlight {
  const ReactionFlight({
    required this.id,
    required this.personId,
    required this.emote,
  });

  final int id;
  final String personId;
  final String emote;

  @override
  bool operator ==(Object other) => other is ReactionFlight && other.id == id;

  @override
  int get hashCode => id;

  @override
  String toString() => 'ReactionFlight($id, $personId, $emote)';
}

/// Everything currently in the air, by the person who threw it.
///
/// Keyed by `SpaceUser.id`, which is what the event carries and what the call
/// tiles and the map both key on — not `UserAccount.id`, which is the media
/// plane's idea of a person and would need bridging at every read.
class Reactions extends ChangeNotifier {
  Reactions({this.linger = reactionLinger, this.maxInFlight = 8});

  final Duration linger;

  /// The most one person can have up at once.
  ///
  /// A held button on a fast connection is the case this exists for. Past this
  /// the oldest is dropped rather than the newest refused, so the stream stays
  /// live and stays bounded — the alternative is a face nobody can see behind a
  /// wall of 👏.
  final int maxInFlight;

  final List<ReactionFlight> _flights = [];
  final Map<int, Timer> _timers = {};
  int _nextId = 0;

  /// What [personId] currently has in the air, oldest first.
  ///
  /// Oldest first because that is painting order: the newest arrival, at the
  /// bottom and at full opacity, belongs on top of the ones fading out above it.
  List<ReactionFlight> forPerson(String? personId) {
    if (personId == null || _flights.isEmpty) return const [];
    return [
      for (final flight in _flights)
        if (flight.personId == personId) flight,
    ];
  }

  bool get isEmpty => _flights.isEmpty;

  /// How many are in the air, for a test that wants to count rather than look.
  int get length => _flights.length;

  /// Throws one more. Never replaces what is already up.
  void note(String personId, String emote) {
    if (personId.isEmpty || emote.isEmpty) return;

    final id = _nextId++;
    _flights.add(ReactionFlight(id: id, personId: personId, emote: emote));
    _timers[id] = Timer(linger, () => _land(id));

    // Oldest first, so this drops the one furthest through its climb — the one
    // already fading, and the one nobody is still reading.
    var over = _flights.where((f) => f.personId == personId).length - maxInFlight;
    for (var i = 0; i < _flights.length && over > 0; i++) {
      if (_flights[i].personId != personId) continue;
      _timers.remove(_flights[i].id)?.cancel();
      _flights.removeAt(i--);
      over--;
    }

    notifyListeners();
  }

  void _land(int id) {
    _timers.remove(id);
    final before = _flights.length;
    _flights.removeWhere((flight) => flight.id == id);
    if (_flights.length == before) return;
    notifyListeners();
  }

  /// Forgets the room. For unpairing, where the next person to use this phone
  /// must not inherit the last one's conversation.
  void clear() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    if (_flights.isEmpty) return;
    _flights.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _flights.clear();
    super.dispose();
  }
}
