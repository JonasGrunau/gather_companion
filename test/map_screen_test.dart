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

RosterRow _row(
  String id,
  num x,
  num y, {
  bool connected = true,
  String? name,
  String? availability,
}) =>
    RosterRow(
      id: id,
      name: name,
      x: x,
      y: y,
      floorId: 'f1',
      connected: connected,
      availability: availability,
    );

void main() {
  // The same pair of listenables the app opens this screen with. `state` alone is
  // not enough: walking is not a presence event, so a roster where everybody moved
  // and nothing else changed never reaches a listener of `state`.
  Widget wrap(AppState state) => MaterialApp(
        theme: buildGatherTheme(),
        home: ListenableBuilder(
          listenable: Listenable.merge([state, state.positions]),
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

    expect(find.text('3 here'), findsOneWidget, reason: 'me and two others; the parked one does not count');
  });

  testWidgets('somebody still marked connected but away is not here', (tester) async {
    // The bug this rule exists for. Measured against a real space: twelve rows said
    // `connected: true` and nine of them were people who had gone home hours before,
    // so the map drew eleven bodies into an office holding three. A socket that dies
    // without saying goodbye leaves `connected` behind it; availability is what
    // moves when somebody actually leaves.
    final state = AppState()
      ..debugApplyLink(const LinkStatus(LinkState.live))
      ..debugMap = _map()
      ..debugApplyRoster(Roster(selfId: 'me', rows: [
        _row('me', 5, 5),
        _row('ada', 8, 4, name: 'Ada', availability: 'Active'),
        _row('busy', 9, 6, name: 'Bram', availability: 'Busy'),
        _row('ghost', 2, 2, name: 'Ghost', availability: 'Offline'),
      ]));

    await tester.pumpWidget(wrap(state));
    await tester.pump();

    // Busy is still in the building; Offline is not, however connected it claims.
    expect(find.text('3 here'), findsOneWidget, reason: 'Ada, Bram and me');
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

  testWidgets('walking redraws the map, though nothing else counts it as a change', (tester) async {
    // The bug: PresenceTracker never looks at coordinates — being near somebody says
    // nothing about whether they want you, which is this app's whole argument — so a
    // roster carrying only movement leaves `stateChanged` false. The map was the one
    // screen that needed it, and it sat frozen until somebody happened to follow you
    // or drop off.
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
      ]);

    await tester.pumpWidget(wrap(state));
    state.debugApplyRoster(Roster(selfId: 'me', rows: [
      _row('me', 1, 1),
      _row('ada', 8, 4, name: 'Ada'),
    ]));
    await tester.pump();
    expect(find.text('20×10 tiles'), findsOneWidget, reason: 'standing in no room');

    // Only a position moves. Same people, same names, same connections.
    state.debugApplyRoster(Roster(selfId: 'me', rows: [
      _row('me', 5, 5),
      _row('ada', 8, 4, name: 'Ada'),
    ]));
    await tester.pump();

    expect(find.text('Green Park'), findsOneWidget, reason: 'I walked into the park');
  });

  group('framing', () {
    // A phone, and the office as it is laid out on one: 124×82 tiles covering the
    // height exactly and overflowing sideways.
    const viewport = Size(390, 780);
    const child = Size(1178.78, 780);

    test('there is never anything on screen that is not map', () {
      // Aiming past the right-hand edge stops with the edge on the edge, rather than
      // centring the point and letting the background in beside it.
      final past = framedOn(
        at: const Offset(1178.78, 400),
        viewport: viewport,
        child: child,
        zoom: 1,
      );
      expect(past.getTranslation().x, closeTo(viewport.width - child.width, 0.01));
      expect(past.getTranslation().y, closeTo(0, 0.01));

      // And the other corner, which clamps the other way.
      final origin = framedOn(at: Offset.zero, viewport: viewport, child: child, zoom: 1);
      expect(origin.getTranslation().x, closeTo(0, 0.01));
      expect(origin.getTranslation().y, closeTo(0, 0.01));
    });

    test('a point with room around it is simply centred', () {
      final centred = framedOn(
        at: const Offset(400, 300),
        viewport: viewport,
        child: child,
        zoom: 3,
      );
      expect(centred.getMaxScaleOnAxis(), 3);
      expect(centred.getTranslation().x, closeTo(390 / 2 - 3 * 400, 0.01));
      expect(centred.getTranslation().y, closeTo(780 / 2 - 3 * 300, 0.01));
    });

    test('and the zoom itself cannot go below covering the screen', () {
      final out = framedOn(at: const Offset(400, 300), viewport: viewport, child: child, zoom: 0.2);
      expect(out.getMaxScaleOnAxis(), kMinZoom);
    });
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
