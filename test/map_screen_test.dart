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
import 'package:gather_companion/ui/dpad.dart';
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

/// The floor's painter, out of a live tree.
///
/// Matched by name because `_OfficePainter` is private and there is deliberately
/// no seam for reaching it — [officePainter] exists for building one *outside* a
/// widget tree, which is the other half of the same job. The D-pad's painter is
/// the only other one down here, so the name is enough to tell them apart.
CustomPainter _officePainter(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((widget) => widget.painter)
    .whereType<CustomPainter>()
    .firstWhere((painter) => painter.runtimeType.toString().contains('OfficePainter'));

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

  testWidgets('the pad appears only once there is something for it to drive',
      (tester) async {
    // Both halves are needed and neither is optional: the socket to send the step on,
    // and the tile to judge it from. A pad shown without them is a control that cannot
    // be told apart from a broken one, so it is absent instead.
    final state = AppState()
      ..debugApplyLink(const LinkStatus(LinkState.live))
      ..debugMap = _map()
      ..debugApplyRoster(Roster(selfId: 'me', rows: [_row('me', 5, 5)]));

    await tester.pumpWidget(wrap(state));
    await tester.pump();
    expect(find.byType(DPad), findsNothing, reason: 'no live Gather behind it');

    state
      ..debugCanWalk = true
      ..debugApplyRoster(Roster(selfId: 'me', rows: [_row('me', 5, 5)]));
    await tester.pump();

    expect(find.byType(DPad), findsOneWidget);
    // Centred across the bottom, so it is the same reach from either hand.
    final size = tester.getSize(find.byType(MapScreen));
    expect(
      tester.getCenter(find.byType(DPad)).dx,
      moreOrLessEquals(size.width / 2, epsilon: 0.5),
    );
    expect(tester.getCenter(find.byType(DPad)).dy, greaterThan(size.height / 2),
        reason: 'the half of the screen a thumb reaches');
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

  testWidgets('walking redraws the map, though nothing else counts it as a change', (tester) async {
    // The bug: PresenceTracker never looks at coordinates — being near somebody says
    // nothing about whether they want you, which is this app's whole argument — so a
    // roster carrying only movement leaves `stateChanged` false. The map was the one
    // screen that needed it, and it sat frozen until somebody happened to follow you
    // or drop off.
    //
    // Asserted on the painter rather than on the app bar, which is where this used
    // to read the answer: the bar named the room you were standing in, and walking
    // between two rooms changed it. That line is gone, and the painter is the
    // honest place to ask anyway — repainting the floor *is* the behaviour, and the
    // app bar only ever stood in for it.
    final state = AppState()
      ..debugApplyLink(const LinkStatus(LinkState.live))
      ..debugMap = _map();

    await tester.pumpWidget(wrap(state));
    state.debugApplyRoster(Roster(selfId: 'me', rows: [
      _row('me', 1, 1),
      _row('ada', 8, 4, name: 'Ada'),
    ]));
    await tester.pump();
    final before = _officePainter(tester);

    // Only a position moves. Same people, same names, same connections.
    state.debugApplyRoster(Roster(selfId: 'me', rows: [
      _row('me', 5, 5),
      _row('ada', 8, 4, name: 'Ada'),
    ]));
    await tester.pump();

    expect(
      _officePainter(tester).shouldRepaint(before),
      isTrue,
      reason: 'a roster carrying only movement still has to reach the floor',
    );
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

  testWidgets('the app bar names the space and nothing else', (tester) async {
    // It used to carry a second line: the room you were standing in, falling back
    // to the floor's size in tiles. Both are gone — the area name changed as you
    // walked, which put a flickering line directly under one that does not move,
    // and the map already writes the zone names on the floor.
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
      ..debugApplyRoster(Roster(
        selfId: 'me',
        rows: [_row('me', 5, 5)],
        spaceName: 'Test Space',
      ));

    await tester.pumpWidget(wrap(state));
    await tester.pump();

    expect(find.text('Test Space'), findsOneWidget);
    expect(find.text('Green Park'), findsNothing, reason: 'standing in it is not news');
    expect(find.text('20×10 tiles'), findsNothing);
  });

  testWidgets('a teleport is drawn from both ends at once', (tester) async {
    // Two bodies of the same person on the map for a moment — one dissolving where
    // they were, one arriving where they went — plus a name plate faded through its
    // own layer. Nothing here has a widget to find, so what this pins is the paint
    // itself: a ghost sorted into the depth list at the wrong end, or a `saveLayer`
    // without its `restore`, throws rather than merely looking wrong.
    final state = AppState()
      ..debugApplyLink(const LinkStatus(LinkState.live))
      ..debugMap = _map()
      ..debugApplyRoster(Roster(selfId: 'me', rows: [_row('me', 1, 1, name: 'Me')]));

    await tester.pumpWidget(wrap(state));
    await tester.pump();

    state.debugTeleport('me', 18, 8);
    await tester.pump();

    // The rosters that follow a hop still name the tile it left, for up to the 250ms
    // the collector coalesces over. The map must not walk anybody back to it.
    state.debugApplyRoster(Roster(selfId: 'me', rows: [_row('me', 1, 1, name: 'Me')]));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 60));

    // Then Gather catches up and says the same thing we did.
    state.debugApplyRoster(Roster(selfId: 'me', rows: [_row('me', 18, 8, name: 'Me')]));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 200));

    expect(tester.takeException(), isNull);
    expect(find.text('1 here'), findsOneWidget, reason: 'one person, however many bodies');
  });
}
