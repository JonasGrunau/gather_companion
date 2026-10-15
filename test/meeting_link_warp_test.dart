/// The Plans tab turning a Gather link into a walk — and, when the door is locked,
/// into a knock instead of a dead end.
///
/// The link parser and the REST resolver are tested on their own; this is the state
/// glue between them and the floor: a room that is open is walked into, a room that
/// is locked and shut to us is *asked* into rather than refused in silence, and the
/// button only offers itself for a link this phone could act on.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/google_calendar.dart';
import 'package:gather_companion/harness/fake_collector.dart';

void main() {
  GoogleEvent eventAt(String? location) => GoogleEvent(
        id: 'e1',
        title: 'Standup',
        startsAt: DateTime(2026, 1, 1, 9),
        endsAt: DateTime(2026, 1, 1, 9, 30),
        location: location,
      );

  SpaceRoom room({required bool locked}) => SpaceRoom(
        id: 'area-9',
        name: 'Boardroom',
        type: 'MeetingRoom',
        x: 0,
        y: 0,
        width: 2,
        height: 2,
        walled: true,
        locked: locked,
      );

  SpaceMap mapWith(SpaceRoom r) => SpaceMap(
        floorId: 'floor-1',
        width: 10,
        height: 10,
        blocked: const {},
        rooms: [r],
      );

  test('a locked room this phone is not admitted to turns into a requestToAccess', () async {
    final collector = _MapCollector(mapWith(room(locked: true)));
    final state = AppState()..debugAttachCollector(collector);

    final note = await state.walkToGoogleEvent(
      eventAt('https://app.v2.gather.town/app/space/Office?room=Boardroom'),
    );

    // Asked, not walked: the one id we sent is the area's own.
    expect(collector.accessRequests, ['area-9']);
    expect(note, contains('Asked to join'));
  });

  test('an open room is walked into, never asked about', () async {
    final collector = _MapCollector(mapWith(room(locked: false)));
    final state = AppState()..debugAttachCollector(collector);

    final note = await state.walkToGoogleEvent(
      eventAt('https://app.v2.gather.town/app/space/Office?room=Boardroom'),
    );

    // No knock on an unlocked door. (The walk itself can't complete with no live
    // connection, so the note is the offline one — the point is only that the open
    // branch routed to the walk, not to a request.)
    expect(collector.accessRequests, isEmpty);
    expect(note, isNotNull);
  });

  test('canGoToMeeting offers the button for a /m/ short link', () {
    final collector = _MapCollector(mapWith(room(locked: true)));
    final state = AppState()..debugAttachCollector(collector);

    expect(
      state.canGoToMeeting(eventAt('https://app.v2.gather.town/m/ktvILgXphb')),
      isTrue,
    );
  });

  test('canGoToMeeting declines a non-Gather location', () {
    final collector = _MapCollector(mapWith(room(locked: true)));
    final state = AppState()..debugAttachCollector(collector);

    expect(state.canGoToMeeting(eventAt('https://zoom.us/j/123')), isFalse);
    expect(state.canGoToMeeting(eventAt(null)), isFalse);
  });
}

/// A [FakeCollector] that answers with one hand-built office, so a test can plant a
/// locked room and watch what the Plans tab does with it.
class _MapCollector extends FakeCollector {
  _MapCollector(this._map) {
    spaceId = 'space';
  }

  final SpaceMap _map;

  @override
  SpaceMap? mapFor(String? floorId) => _map;
}
