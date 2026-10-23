/// Knocking on a locked room: the action layer under the "Request access" button.
///
/// Issue #69. The wire shape — `requestToAccess` on `MapArea`, bare frame — lives in
/// `direct_collector.dart` and is pinned there; this is the app's half: the id that
/// has to reach the collector is the area's `stableId` and never its `id`, a room
/// with no `stableId` has nothing to knock on, and a successful knock says so.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/harness/fake_collector.dart';
import 'package:gather_companion/src/app_state.dart';

void main() {
  ({AppState state, FakeCollector collector}) wired() {
    final collector = FakeCollector();
    final state = AppState()..debugAttachCollector(collector);
    addTearDown(state.dispose);
    return (state: state, collector: collector);
  }

  SpaceRoom room({String? stableId = 'area-7', String? name = 'Eng'}) => SpaceRoom(
        id: 'map-area-1',
        name: name,
        type: 'MeetingRoom',
        x: 2,
        y: 2,
        width: 4,
        height: 4,
        walled: true,
        stableId: stableId,
        locked: true,
      );

  test('knocks on the area by its stableId, not its id, and reports it sent', () {
    final (:state, :collector) = wired();

    final result = state.requestAccess(room());

    expect(result.ok, isTrue);
    // The stableId reaches the collector — `map-area-1`, the `MapArea.id`, would
    // create a request that joins nothing.
    expect(collector.accessRequests, ['area-7']);
  });

  test('a successful knock is announced on notices', () async {
    final (:state, :collector) = wired();

    final said = state.notices.first;
    state.requestAccess(room(name: 'Eng'));

    expect(await said.timeout(const Duration(seconds: 5)), contains('Eng'));
  });

  test('a room with no stableId has nothing to knock on', () {
    final (:state, :collector) = wired();

    final result = state.requestAccess(room(stableId: null));

    expect(result.ok, isFalse);
    expect(result.detail, isNotNull);
    expect(collector.accessRequests, isEmpty, reason: 'nothing to send');
  });

  test('says so, and sends nothing, when there is no collector', () {
    final state = AppState();
    addTearDown(state.dispose);

    final result = state.requestAccess(room());

    expect(result.ok, isFalse);
    expect(result.detail, isNotNull);
  });

  test('a failed send is not announced as asked', () {
    final (:state, :collector) = wired();
    collector.failSends = true;

    final result = state.requestAccess(room());

    expect(result.ok, isFalse);
    expect(collector.accessRequests, isEmpty);
  });
}
