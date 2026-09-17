/// The speaking ring, from the microphone to the game socket.
///
/// The measurement is `voice_activity_test.dart`, the poll is
/// `live_call_test.dart`, and the wire shape is `direct_collector_test.dart`.
/// This is the hop between them: [AppState] listening to the call and passing
/// the answer on. It is the one link that, when it was missing, produced a phone
/// that was perfectly audible in the room and drawn as silent on every screen in
/// it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/src/app_state.dart';

import 'fake_call.dart';

void main() {
  ({AppState state, FakeCall call, List<String> rebuilds}) wired() {
    final call = FakeCall();
    final rebuilds = <String>[];
    final state = AppState()..debugAttachCall(call);
    state.addListener(() => rebuilds.add('${state.amSpeaking}'));
    addTearDown(state.dispose);
    return (state: state, call: call, rebuilds: rebuilds);
  }

  test('nobody is talking until the call says so', () async {
    final (:state, :call, :rebuilds) = wired();

    expect(state.amSpeaking, isFalse);
    expect(rebuilds, isEmpty);
  });

  test('the call starting and stopping a sentence reaches the app', () async {
    final (:state, :call, :rebuilds) = wired();

    call.speak(true);
    await Future<void>.delayed(Duration.zero);
    expect(state.amSpeaking, isTrue);

    call.speak(false);
    await Future<void>.delayed(Duration.zero);
    expect(state.amSpeaking, isFalse);

    expect(rebuilds, ['true', 'false']);
  });

  test('the same answer twice is not redrawn', () async {
    final (:state, :call, :rebuilds) = wired();

    call
      ..speak(true)
      ..speak(true);
    await Future<void>.delayed(Duration.zero);

    // The poll runs five times a second. Without this guard every one of those
    // samples would rebuild the map and put a `startSpeaking` on the socket.
    expect(rebuilds, ['true']);
  });

  test('our own avatar is drawn talking from our own microphone', () async {
    final (:state, :call, :rebuilds) = wired();
    state.debugApplyRoster(Roster(
      selfId: 'me',
      rows: const [RosterRow(id: 'me', name: 'Jonas', x: 3, y: 4, connected: true)],
    ));

    expect(state.mePerson?.speaking, isFalse);

    call.speak(true);
    await Future<void>.delayed(Duration.zero);

    // Read here rather than off the roster, which carries `speaking` back a
    // moment later: a beat of lag is invisible on somebody else's avatar and
    // very visible on your own.
    expect(state.mePerson?.speaking, isTrue);
  });

  group('other people', () {
    RosterRow row(String id, {String? cluster, bool? speaking}) => RosterRow(
          id: id,
          name: id,
          clusterIdKnown: true,
          clusterId: cluster,
          connected: true,
          speaking: speaking,
          x: 3,
          y: 4,
        );

    ({AppState state, List<int> rebuilds}) watched() {
      final rebuilds = <int>[];
      final state = AppState();
      state.addListener(() => rebuilds.add(rebuilds.length));
      addTearDown(state.dispose);
      return (state: state, rebuilds: rebuilds);
    }

    test('somebody in the conversation starting to talk redraws the call', () {
      final (:state, :rebuilds) = watched();
      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        row('me', cluster: 'c1'),
        row('luca', cluster: 'c1', speaking: false),
      ]));
      rebuilds.clear();

      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        row('me', cluster: 'c1'),
        row('luca', cluster: 'c1', speaking: true),
      ]));

      // The call screen rebuilds on this and on nothing else. The presence fold
      // deliberately does not report voice activity as a state change, which is
      // what used to leave every ring in the call frozen at whatever it was when
      // something unrelated last woke the screen.
      expect(rebuilds, isNotEmpty);
    });

    test('a stranger across the office does not', () {
      final (:state, :rebuilds) = watched();
      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        row('me', cluster: 'c1'),
        row('stranger', cluster: 'c9', speaking: false),
      ]));
      rebuilds.clear();

      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        row('me', cluster: 'c1'),
        row('stranger', cluster: 'c9', speaking: true),
      ]));

      // Measured on a real space, `speaking` was the most frequent patch of any
      // kind across 111 rows. Rebuilding the tree for each one is the reason the
      // guard this works around exists.
      expect(rebuilds, isEmpty);
    });

    test('but the map draws them talking anyway, off the roster', () {
      final (:state, :rebuilds) = watched();
      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        row('me', cluster: 'c1'),
        row('stranger', cluster: 'c9', speaking: true),
      ]));

      // The map rides the `positions` ticker, so it repaints every roster
      // without a notification — it only needs the value to be current. Reading
      // it from the presence snapshot instead left everybody permanently silent,
      // because that snapshot is only rebuilt when the fold reports a change.
      final them = state.peopleOnMap.singleWhere((p) => p.id == 'stranger');
      expect(them.speaking, isTrue);
    });
  });
}
