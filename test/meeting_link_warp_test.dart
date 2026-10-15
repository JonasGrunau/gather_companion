/// The Plans tab turning a Gather link into a walk — and, when the door is locked,
/// into a knock instead of a dead end.
///
/// The link parser and the REST resolver are tested on their own; this is the state
/// glue between them and the floor: a room that is open is walked into, a room that
/// is locked and shut to us is *asked* into rather than refused in silence, and the
/// button only offers itself for a link this phone could act on.
library;

import 'dart:convert';

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

  // The link parser and the REST resolver each have their own tests; these drive
  // the whole chain through AppState — an opaque /m/ code turned into one REST
  // lookup, the returned area matched against the floor, and the locked door
  // knocked on — with a stand-in auth client so no live login is needed.
  group('/m/ short link, resolved and walked', () {
    AppState stateWith(_MapCollector collector, GatherHttp http) => AppState()
      ..debugAttachCollector(collector)
      ..debugAttachAuth(
        GatherAuth(
          credentials: GatherCredentials(refreshToken: 'r', idToken: _jwt()),
          http: http,
        ),
      );

    test('resolves to a locked room on this floor and knocks', () async {
      final collector = _MapCollector(mapWith(room(locked: true)));
      final http = _JoinInfo(spaceId: 'space', areaId: 'area-9');
      final state = stateWith(collector, http);

      final note = await state.walkToGoogleEvent(
        eventAt('https://app.v2.gather.town/m/ktvILgXphb'),
      );

      // One lookup, on the code from the URL; the area it named was asked into.
      expect(http.lookups, ['ktvILgXphb']);
      expect(collector.accessRequests, ['area-9']);
      expect(note, contains('Asked to join'));
    });

    test('a link into another space is as far as one walk goes', () async {
      final collector = _MapCollector(mapWith(room(locked: true)));
      final http = _JoinInfo(spaceId: 'elsewhere', areaId: 'area-9');
      final state = stateWith(collector, http);

      final note = await state.walkToGoogleEvent(
        eventAt('https://app.v2.gather.town/m/ktvILgXphb'),
      );

      expect(http.lookups, ['ktvILgXphb']);
      expect(collector.accessRequests, isEmpty);
      expect(note, contains('another Gather space'));
    });

    test('a resolve the server refuses is reported, not crashed through', () async {
      final collector = _MapCollector(mapWith(room(locked: true)));
      final http = _JoinInfo(spaceId: 'space', areaId: 'area-9', status: 404);
      final state = stateWith(collector, http);

      final note = await state.walkToGoogleEvent(
        eventAt('https://app.v2.gather.town/m/ktvILgXphb'),
      );

      expect(collector.accessRequests, isEmpty);
      expect(note, contains("Couldn't open that meeting link"));
    });
  });
}

/// A `none`-algorithm JWT with an hour of life, enough for [GatherAuth] to read an
/// expiry off it and never try to refresh — the fake http has no mint endpoint.
String _jwt() {
  String seg(Object o) =>
      base64Url.encode(utf8.encode(json.encode(o))).replaceAll('=', '');
  final exp = DateTime(2099).millisecondsSinceEpoch ~/ 1000;
  return '${seg({'alg': 'none'})}.${seg({'user_id': 'uid-1', 'exp': exp})}.sig';
}

/// Answers `/meeting-join-info/:linkId` with a normalized-state envelope and notes
/// every code it was asked about, so a test can both plant the destination and
/// check the lookup happened.
class _JoinInfo implements GatherHttp {
  _JoinInfo({required this.spaceId, required this.areaId, this.status = 200});

  final String spaceId;
  final String areaId;
  final int status;
  final List<String> lookups = [];

  @override
  Future<({int status, Object? body})> getJson(Uri uri, String bearer) async {
    lookups.add(uri.pathSegments.last);
    if (status != 200) return (status: status, body: null);
    return (
      status: 200,
      body: {
        'normalizedGSState': {
          'MeetingJoinInfo': [
            {'spaceId': spaceId, 'linkId': 'ktvILgXphb', 'areaId': areaId},
          ],
        },
      },
    );
  }

  @override
  Future<({int status, Map<String, Object?> body})> postForm(
          Uri uri, Map<String, String> fields) =>
      throw UnimplementedError('no token should need minting');

  @override
  Future<({int status, List<int> body})> getBytes(Uri uri, String bearer) =>
      throw UnimplementedError();

  @override
  Future<({int status, List<int> body})> postJson(
          Uri uri, String bearer, Object? body) =>
      throw UnimplementedError();
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
