/// Issue #41: an external device on the same account hangs our call up.
///
/// The phone and the desktop client are one shared `SpaceUser`. When the desktop
/// locks or sleeps it flips that shared user to `availability: Offline` and the
/// server tears the phone's call down with it. The phone has no control that sets
/// itself Offline, so an Offline reading while we are foreground and in a call is
/// always some other device's doing — these tests pin the fight-back: re-assert our
/// presence, restore what the person actually chose, rebuild the dead media session,
/// and stop before it becomes a loop with a Mac that is staying asleep.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/harness/fake_collector.dart';
import 'package:gather_companion/src/app_state.dart';

import 'fake_call.dart';

void main() {
  void withClock(void Function(FakeAsync clock) body) => fakeAsync((clock) {
        body(clock);
        clock.elapse(const Duration(seconds: 15));
      });

  void settle(FakeAsync clock) {
    clock.elapse(const Duration(milliseconds: 1700));
    clock.flushMicrotasks();
  }

  /// A placed row, so [Roster.nearby] can tell a held conversation from a walk-away.
  RosterRow placed(
    String id, {
    String? cluster,
    String? account,
    String? availability,
    num x = 0,
    num y = 0,
  }) =>
      RosterRow(
        id: id,
        name: id,
        x: x,
        y: y,
        floorId: 'f1',
        clusterIdKnown: true,
        clusterId: cluster,
        userAccountId: account,
        availability: availability,
        connected: true,
      );

  /// An [AppState] with a call and a collector attached, foregrounded and in a call
  /// with `them` — the state the desktop lock arrives into.
  ({AppState state, FakeCall call, FakeCollector collector}) inACall(
    FakeAsync clock, {
    String selfAvailability = 'Active',
  }) {
    final call = FakeCall();
    final collector = FakeCollector();
    final state = AppState()
      ..debugAttachCall(call)
      ..debugAttachCollector(collector);
    addTearDown(state.dispose);
    // Foreground, the way the lifecycle reports it on resume.
    state.setActive(true);

    state.debugApplyRoster(Roster(selfId: 'me', rows: [
      placed('me', cluster: 'c1', account: 'acct-me', availability: selfAvailability),
      placed('them', cluster: 'c1', account: 'acct-them', x: 1),
    ]));
    settle(clock);
    expect(state.inHuddle, isTrue, reason: 'precondition: we are in a call');
    return (state: state, call: call, collector: collector);
  }

  /// The desktop-lock roster: our shared user dropped to Offline. [stillClustered]
  /// chooses the fingerprint — out of the cluster entirely (clusterId null, the real
  /// drop) or still named in it (a briefer transient) — both with `them` in range.
  Roster offlineRoster({bool stillClustered = false}) =>
      Roster(selfId: 'me', rows: [
        placed('me',
            cluster: stillClustered ? 'c1' : null,
            account: 'acct-me',
            availability: 'Offline'),
        placed('them', cluster: 'c1', account: 'acct-them', x: 1),
      ]);

  test('an external Offline mid-call is fought and the dead session rebuilt', () {
    withClock((clock) {
      final (:state, :call, :collector) = inACall(clock);

      state.debugApplyRoster(offlineRoster());
      clock.flushMicrotasks();

      // Re-asserted: at the desk again, and the availability the person actually had
      // put back rather than stomped to a default.
      expect(collector.activesSet.last, isTrue);
      expect(collector.availabilitiesSet, ['Active']);
      // A fresh dump forced, and the media session the suspend killed rebuilt.
      expect(collector.resyncs, 1);
      expect(call.rebuilds, 1);
      // And the call was held across it, not blinked out.
      expect(state.inHuddle, isTrue);
    });
  });

  test('a busy person is restored to Busy, not Active', () {
    withClock((clock) {
      final (:state, :call, :collector) = inACall(clock, selfAvailability: 'Busy');

      state.debugApplyRoster(offlineRoster());
      clock.flushMicrotasks();

      expect(collector.availabilitiesSet, ['Busy']);
      expect(call.rebuilds, 1);
    });
  });

  test('the re-assert is bounded, not a loop with a sleeping Mac', () {
    withClock((clock) {
      // Held *in* the cluster so the call never tears down under us, isolating the
      // self-heal bound from the 12s cluster hold.
      final (:state, :call, :collector) = inACall(clock);

      // Six Offline rosters, a cooldown apart. The ladder must stop at four.
      for (var i = 0; i < 6; i++) {
        state.debugApplyRoster(offlineRoster(stillClustered: true));
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 3));
      }

      expect(collector.availabilitiesSet, hasLength(4));
      expect(collector.resyncs, 4);
      // The media rebuild is once per episode, not once per try.
      expect(call.rebuilds, 1);
    });
  });

  test('two rosters inside one cooldown re-assert only once', () {
    withClock((clock) {
      final (:collector, :state, :call) = inACall(clock);

      state.debugApplyRoster(offlineRoster(stillClustered: true));
      clock.flushMicrotasks();
      // A second roster a quarter-second later — positions move four times a second.
      clock.elapse(const Duration(milliseconds: 250));
      state.debugApplyRoster(offlineRoster(stillClustered: true));
      clock.flushMicrotasks();

      expect(collector.availabilitiesSet, hasLength(1));
      expect(call.rebuilds, 1);
    });
  });

  test('coming back online resets the ladder, so a later lock is fought afresh', () {
    withClock((clock) {
      final (:state, :call, :collector) = inACall(clock);

      // First lock: the during-lock rebuild attempt.
      state.debugApplyRoster(offlineRoster(stillClustered: true));
      clock.flushMicrotasks();
      expect(call.rebuilds, 1);

      // The Mac wakes: we are Active again. The ladder resets, and the dead session
      // the lock left behind is rebuilt on the recovery edge (issue #41).
      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        placed('me', cluster: 'c1', account: 'acct-me', availability: 'Active'),
        placed('them', cluster: 'c1', account: 'acct-them', x: 1),
      ]));
      clock.flushMicrotasks();
      expect(call.rebuilds, 2);
      clock.elapse(const Duration(seconds: 3));

      // A second lock is a new episode, fought from scratch.
      state.debugApplyRoster(offlineRoster(stillClustered: true));
      clock.flushMicrotasks();
      expect(call.rebuilds, 3);
      expect(collector.availabilitiesSet, hasLength(2));
    });
  });

  test('the desktop unlocking rebuilds the media the lock left dead', () {
    withClock((clock) {
      final (:state, :call, :collector) = inACall(clock);

      // Desktop locks: shared user Offline, the banner raised and a during-lock
      // rebuild attempted.
      state.debugApplyRoster(offlineRoster(stillClustered: true));
      clock.flushMicrotasks();
      expect(call.rebuilds, 1);
      expect(state.callInterrupted, isTrue);

      // Desktop unlocks: Active again. The session the lock tore down server-side is
      // rebuilt immediately rather than left for the slow websocket ladder, and the
      // banner clears.
      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        placed('me', cluster: 'c1', account: 'acct-me', availability: 'Active'),
        placed('them', cluster: 'c1', account: 'acct-them', x: 1),
      ]));
      clock.flushMicrotasks();
      expect(call.rebuilds, 2);
      expect(state.callInterrupted, isFalse);
    });
  });

  test('a backgrounded phone going Offline is left alone', () {
    withClock((clock) {
      final (:state, :call, :collector) = inACall(clock);
      // Phone pocketed: the lifecycle reported paused.
      state.setActive(false);

      state.debugApplyRoster(offlineRoster(stillClustered: true));
      clock.flushMicrotasks();

      // Backgrounded Offline is correct, not something to fight — and no banner.
      expect(call.rebuilds, 0);
      expect(collector.availabilitiesSet, isEmpty);
      expect(collector.resyncs, 0);
      expect(state.callInterrupted, isFalse);
    });
  });

  test('a partial roster without our row does not reset the episode', () {
    withClock((clock) {
      // Held in the cluster so the call never tears down under us, isolating the
      // self-heal bound from the 12s cluster hold.
      final (:state, :call, :collector) = inACall(clock);

      // The lock lands: fought once, the dead session rebuilt once.
      state.debugApplyRoster(offlineRoster(stillClustered: true));
      clock.flushMicrotasks();
      expect(call.rebuilds, 1);
      clock.elapse(const Duration(seconds: 3));

      // A reconnect's fresh reader emits a partial dump before our own row lands:
      // `them` is there, we are not, so `myAvailability` reads null. This must not be
      // mistaken for recovery — resetting here would clear the once-per-episode
      // rebuild guard and let the next Offline rebuild all over again, unbounded.
      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        placed('them', cluster: 'c1', account: 'acct-them', x: 1),
      ]));
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 3));

      // Our row arrives, still Offline — the same episode, not a new one.
      state.debugApplyRoster(offlineRoster(stillClustered: true));
      clock.flushMicrotasks();

      // Still one rebuild: the partial roster did not reopen the episode.
      expect(call.rebuilds, 1);
    });
  });

  test('a focus-area availability is not restored as an unsendable write', () {
    withClock((clock) {
      // The desktop put the shared user in a focus area — a real availability that
      // `setAvailability` refuses to send (only Active/Busy/Away are sendable).
      final (:state, :call, :collector) =
          inACall(clock, selfAvailability: 'Focused');

      state.debugApplyRoster(offlineRoster());
      clock.flushMicrotasks();

      // The restore must be a sendable value, not the discarded 'Focused' that would
      // leave us stuck Offline. With no sendable state seen, it falls back to Active.
      expect(collector.availabilitiesSet, ['Active']);
      expect(collector.availabilitiesSet, isNot(contains('Focused')));
      expect(call.rebuilds, 1);
    });
  });

  test('Offline while not in a call does nothing', () {
    withClock((clock) {
      final call = FakeCall();
      final collector = FakeCollector();
      final state = AppState()
        ..debugAttachCall(call)
        ..debugAttachCollector(collector);
      addTearDown(state.dispose);
      state.setActive(true);

      // Alone and Offline — there is no call to defend.
      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        placed('me', account: 'acct-me', availability: 'Offline'),
      ]));
      clock.flushMicrotasks();

      expect(state.inCall, isFalse);
      expect(call.rebuilds, 0);
      expect(collector.availabilitiesSet, isEmpty);
      expect(state.callInterrupted, isFalse);
    });
  });
}
