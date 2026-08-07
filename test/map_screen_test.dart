/// The map screen, which exists because the floor plan turned out to be free.
///
/// Two things are worth pinning. The first is that "no map yet" and "not connected"
/// are different sentences — the map arrives a moment after the roster, so a screen
/// that said "not connected" during that gap would be lying once a second on every
/// launch. The second is that offline avatars are not drawn: their coordinates are
/// wherever somebody logged off, and a map full of people who went home is worse
/// than a map with nobody on it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/link_status.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/map_screen.dart';

SpaceMap _map({Set<int> blocked = const {}, List<SpaceRoom> rooms = const []}) => SpaceMap(
      floorId: 'f1',
      width: 20,
      height: 10,
      blocked: blocked,
      rooms: rooms,
    );

RosterRow _row(String id, num x, num y, {bool connected = true, String? name}) =>
    RosterRow(id: id, name: name, x: x, y: y, floorId: 'f1', connected: connected);

void main() {
  Widget wrap(AppState state) => MaterialApp(
        theme: buildGatherTheme(),
        home: ListenableBuilder(
          listenable: state,
          builder: (context, _) => MapScreen(state: state),
        ),
      );

  testWidgets('a connected app with no map yet says it is still reading one', (tester) async {
    final state = AppState()..debugApplyLink(const LinkStatus(LinkState.live));
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    expect(find.textContaining('Reading the floor plan'), findsOneWidget);
    expect(find.text('Not connected'), findsNothing);
  });

  testWidgets('without a connection it says that instead', (tester) async {
    final state = AppState();
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    expect(find.text('Not connected'), findsOneWidget);
  });

  testWidgets('the map draws, and counts only the people who are here', (tester) async {
    final state = AppState()
      ..debugApplyLink(const LinkStatus(LinkState.live))
      ..debugMap = _map()
      ..debugApplyRoster(Roster(selfId: 'me', rows: [
        _row('me', 5, 5),
        _row('ada', 8, 4, name: 'Ada'),
        _row('bram', 9, 6, name: 'Bram'),
        _row('gone', 2, 2, name: 'Gone home', connected: false),
      ]));

    await tester.pumpWidget(wrap(state));
    await tester.pump();

    expect(find.text('2 here'), findsOneWidget, reason: 'me and the parked one do not count');
    expect(find.text('You'), findsOneWidget, reason: 'the key is drawn');
  });

  testWidgets('the room you are standing in is named', (tester) async {
    final state = AppState()
      ..debugApplyLink(const LinkStatus(LinkState.live))
      ..debugMap = _map(rooms: const [
        SpaceRoom(
          id: 'r1',
          name: 'Green Park',
          type: 'Common',
          x: 4,
          y: 4,
          width: 4,
          height: 4,
          walled: false,
        ),
      ])
      ..debugApplyRoster(Roster(selfId: 'me', rows: [_row('me', 5, 5)]));

    await tester.pumpWidget(wrap(state));
    await tester.pump();

    expect(find.text('Green Park'), findsOneWidget);
  });

  testWidgets('outside every room it falls back to the size of the floor', (tester) async {
    final state = AppState()
      ..debugApplyLink(const LinkStatus(LinkState.live))
      ..debugMap = _map()
      ..debugApplyRoster(Roster(selfId: 'me', rows: [_row('me', 1, 1)]));

    await tester.pumpWidget(wrap(state));
    await tester.pump();

    expect(find.text('20×10 tiles'), findsOneWidget);
  });
}
