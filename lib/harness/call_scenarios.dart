/// Scripts a multi-party call forward in time, so the call screen animates on a
/// simulator with no network behind it.
///
/// The decision — who is in the call, who is talking, right now — is a pure
/// function of elapsed time ([scenarioFrame]); [CallScenarioDriver] is the thin
/// part that owns a timer and pushes each frame into [AppState] through its test
/// seams. Keeping the decision pure is what lets `call_scenario_driver_test.dart`
/// assert a whole scenario without a clock, the same split
/// `spotlight_director.dart` keeps one level down.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../src/app_state.dart';
import '../src/media/call.dart';
import '../src/media/media_engine.dart';
import 'harness_data.dart';
import 'scripted_call.dart';

/// The shapes of call the harness can play.
enum Scenario {
  /// Just me. The spotlight has nobody to follow — the empty baseline.
  solo,

  /// Me and one other, who talks in bursts.
  pair,

  /// A few people, nobody talking. The manual-mode grid at rest.
  group,

  /// Each person takes the floor for 3s in turn. Auto mode should follow,
  /// promoting one speaker per turn with no jump between.
  roundRobin,

  /// Two dominant speakers. One holds the floor, the other talks over without
  /// stealing it (sticky), then the first stops and the second earns it.
  debate,

  /// Short blips, none held past the 1.5s dwell. Auto mode must stay on the
  /// overview — the cough-and-chair-scrape rejection test.
  briefNoise,

  /// People join and leave mid-call. Tiles and the strip track it; the spotlight
  /// target survives or re-floors cleanly.
  churn;

  static Scenario fromName(String name) => Scenario.values.firstWhere(
        (s) => s.name.toLowerCase() == name.toLowerCase(),
        orElse: () => Scenario.group,
      );
}

/// A single moment of a scenario: who is present, who is audible, and whether I
/// am talking.
@immutable
class ScenarioFrame {
  const ScenarioFrame({
    required this.count,
    required this.speaking,
    this.ownSpeaking = false,
  });

  /// How many of [kCast] are in the call this instant.
  final int count;

  /// The `accountId`s talking right now.
  final Set<String> speaking;

  /// Whether my own ring is lit.
  final bool ownSpeaking;

  @override
  bool operator ==(Object other) =>
      other is ScenarioFrame &&
      other.count == count &&
      other.ownSpeaking == ownSpeaking &&
      setEquals(other.speaking, speaking);

  @override
  int get hashCode => Object.hash(count, ownSpeaking, Object.hashAllUnordered(speaking));

  @override
  String toString() =>
      'ScenarioFrame(count: $count, speaking: $speaking, ownSpeaking: $ownSpeaking)';
}

/// The dwell the auto spotlight gates on. Scenarios are timed around it.
const Duration kDwell = Duration(milliseconds: 1500);

String _acc(int i) => kCast[i].accountId;

/// Who is where, and talking, at [elapsed] into [scenario] with [participants]
/// seated at the start. Pure: the same inputs always give the same frame.
ScenarioFrame scenarioFrame(
  Scenario scenario,
  Duration elapsed,
  int participants,
) {
  final ms = elapsed.inMilliseconds;
  final n = participants.clamp(0, castSize);

  switch (scenario) {
    case Scenario.solo:
      return const ScenarioFrame(count: 0, speaking: {});

    case Scenario.pair:
      // One other, talking 2.5s on / 1s off.
      const count = 1;
      final on = ms % 3500 < 2500;
      return ScenarioFrame(count: count, speaking: on ? {_acc(0)} : const {});

    case Scenario.group:
      return ScenarioFrame(count: n, speaking: const {});

    case Scenario.roundRobin:
      if (n == 0) return const ScenarioFrame(count: 0, speaking: {});
      // Each holds the floor 3s — twice the dwell — so every turn promotes.
      final active = (ms ~/ 3000) % n;
      return ScenarioFrame(count: n, speaking: {_acc(active)});

    case Scenario.debate:
      final count = n < 2 ? 2 : n;
      // A 12s cycle: A earns it, B talks over (A sticky), A stops, B earns it.
      final t = ms % 12000;
      final Set<String> speaking;
      if (t < 5000) {
        speaking = {_acc(0)}; // A holds the floor.
      } else if (t < 7000) {
        speaking = {_acc(0), _acc(1)}; // B over A — A keeps it.
      } else {
        speaking = {_acc(1)}; // A done; B holds long enough to earn it.
      }
      return ScenarioFrame(count: count, speaking: speaking);

    case Scenario.briefNoise:
      if (n == 0) return const ScenarioFrame(count: 0, speaking: {});
      // 1.5s slots; a different person blips for only the first 800ms of each —
      // under the dwell — so nobody is ever promoted.
      final slot = ms ~/ 1500;
      final blip = ms % 1500 < 800;
      final who = slot % n;
      return ScenarioFrame(count: n, speaking: blip ? {_acc(who)} : const {});

    case Scenario.churn:
      final base = n < 2 ? 2 : n;
      // Drop to base-2 and back, 2s a step, so people leave and rejoin.
      const steps = [0, 1, 2, 1];
      final drop = steps[(ms ~/ 2000) % steps.length];
      final count = (base - drop).clamp(1, castSize);
      // Round-robin the floor among whoever is present.
      final active = (ms ~/ 3000) % count;
      return ScenarioFrame(count: count, speaking: {_acc(active)});
  }
}

/// Plays a [Scenario] into an [AppState] by pushing a fresh roster and call state
/// on every tick, the same two seams `call_screen_test.dart` uses by hand.
class CallScenarioDriver {
  CallScenarioDriver({
    required this.state,
    required this.call,
    required this.scenario,
    required this.participants,
    this.period = const Duration(milliseconds: 250),
  });

  final AppState state;
  final ScriptedCall call;
  final Scenario scenario;
  final int participants;

  /// How often the scene is re-evaluated. Finer than the dwell so the ring and
  /// the promotion timer both look live.
  final Duration period;

  Timer? _timer;
  int _ticks = 0;

  /// The state the self tile needs to exist: the camera "open", so `_tiles`
  /// draws a "You" avatar at the head of the strip.
  static const _selfMedia = LocalMediaState(capturing: true, audioEnabled: true);

  /// Applies the frame at [elapsed]. Public and clock-free so a test can step the
  /// scenario without a timer.
  void applyAt(Duration elapsed) {
    final frame = scenarioFrame(scenario, elapsed, participants);
    // Call state first — the roster push below is what notifies the screen, and
    // the rebuild then reads this. Participants carry audio; video stays off, so
    // tiles are avatars.
    call.emit(CallState(
      media: _selfMedia,
      publishingAudio: true,
      participants: participantsFor(frame.count),
    ));
    call.speak(frame.ownSpeaking);
    // This harness is the one lib entrypoint that drives the test seams on
    // purpose — the roster push is what notifies the screen.
    // ignore: invalid_use_of_visible_for_testing_member
    state.debugApplyRoster(
      rosterFor(frame.count, speakingAccountIds: frame.speaking),
    );
  }

  /// Seeds the first frame and starts the clock.
  void start() {
    applyAt(Duration.zero);
    _ticks = 0;
    _timer = Timer.periodic(period, (_) {
      _ticks++;
      applyAt(period * _ticks);
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
