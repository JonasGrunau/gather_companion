/// The Dial tab, at the widget level: that it shows the office as a directory with
/// the people who are here above the people who are not, draws a card for a
/// conversation already happening, and offers a warp only against someone it can
/// reach.
///
/// The warp *action* — the teleport, the auto-mic, the offline refusal — is
/// asserted in `directory_test.dart`, where it needs no navigator; this is about
/// what the screen puts on the glass.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/harness/fake_collector.dart';
import 'package:gather_companion/harness/harness_data.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/link_status.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/dial_screen.dart';
import 'package:gather_events/gather_events.dart';

void main() {
  RosterRow row(
    String id, {
    required String name,
    bool connected = true,
    String availability = 'Active',
    String? clusterId,
    num? x,
    num? y,
  }) =>
      RosterRow(
        id: id,
        name: name,
        connected: connected,
        availability: availability,
        clusterId: clusterId,
        clusterIdKnown: clusterId != null,
        x: x,
        y: y,
      );

  /// A roster with a conversation in the Lounge (Ada + Bob), a lone present
  /// person (Zoe), and somebody offline (Xander).
  Roster peopledRoster() => Roster(selfId: kSelfId, spaceName: 'SafeNow', rows: [
        const RosterRow(id: kSelfId, name: 'You', x: 10, y: 7),
        row('a', name: 'Ada', clusterId: 'c1', x: 8, y: 10),
        row('b', name: 'Bob', clusterId: 'c1', x: 9, y: 11),
        row('z', name: 'Zoe', x: 15, y: 7),
        row('x', name: 'Xander', connected: false, availability: 'Offline', x: 3, y: 3),
      ]);

  AppState peopled() => AppState()
    ..debugApplyLink(const LinkStatus(LinkState.live))
    ..debugMap = schematicOffice()
    ..debugApplyRoster(peopledRoster())
    // After the roster: its fold rebuilds the snapshot, so the name has to be set
    // last to survive to the title.
    ..debugApplySnapshot(PresenceSnapshot(
      self: const SelfState(spaceId: 'space-1', spaceName: 'SafeNow'),
      players: const [],
      health: const CollectorHealth(logTail: true, cdp: true),
      at: DateTime(2026),
    ));

  Widget wrap(AppState state) => MaterialApp(
        theme: buildGatherTheme(),
        home: ListenableBuilder(
          listenable: state,
          builder: (context, _) => DialScreen(state: state),
        ),
      );

  // The same screen stood up with explicit visibility, so a test can flip the tab
  // on and off the way the shell does.
  Widget wrapVisible(AppState state, {required bool visible}) => MaterialApp(
        theme: buildGatherTheme(),
        home: DialScreen(state: state, visible: visible),
      );

  // The codename's warp-in opacity: 0 while the flourish is held at its start,
  // climbing to 1 as it lands. The readable proxy for "the animation is running".
  double warpOpacity(WidgetTester tester) => tester
      .widget<Opacity>(find.ancestor(of: find.text('warp dial'), matching: find.byType(Opacity)))
      .opacity;

  testWidgets('shows the space name, and everyone in it including the offline', (tester) async {
    final state = peopled();
    addTearDown(state.dispose);
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    expect(find.text('SafeNow'), findsOneWidget);
    expect(find.text('warp dial'), findsOneWidget, reason: 'the tab wears its codename beside the space name');
    expect(find.text('Zoe'), findsOneWidget);
    expect(find.text('Xander'), findsOneWidget, reason: 'the offline are listed, not hidden');
  });

  testWidgets('puts the people who are here above the people who are not', (tester) async {
    final state = peopled();
    addTearDown(state.dispose);
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    final here = tester.getTopLeft(find.text('Zoe')).dy;
    final gone = tester.getTopLeft(find.text('Xander')).dy;
    expect(here, lessThan(gone));
  });

  testWidgets('draws a card for a conversation, named by its room', (tester) async {
    final state = peopled();
    addTearDown(state.dispose);
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    expect(find.text('Lounge'), findsOneWidget);
    expect(find.text('Join'), findsOneWidget);
  });

  testWidgets('offers a warp only against the reachable', (tester) async {
    final state = peopled();
    addTearDown(state.dispose);
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    // Ada, Bob and Zoe are here; Xander is not. One warp each for the present.
    expect(find.text('Warp'), findsNWidgets(3));
  });

  testWidgets('offers a wave against everyone present, and nobody offline', (tester) async {
    final state = peopled();
    addTearDown(state.dispose);
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    // Ada, Bob and Zoe are here; Xander is away. A wave at an absent person would
    // land nowhere, so the button is withheld there.
    expect(find.byIcon(Icons.waving_hand_rounded), findsNWidgets(3));
  });

  testWidgets('tapping a wave sends one at that person', (tester) async {
    final collector = FakeCollector();
    final state = AppState()
      ..debugApplyLink(const LinkStatus(LinkState.live))
      ..debugAttachCollector(collector)
      ..debugApplyRoster(peopledRoster());
    addTearDown(state.dispose);

    await tester.pumpWidget(wrap(state));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.waving_hand_rounded).first);
    await tester.pump();

    expect(collector.waves, hasLength(1), reason: 'the press reached the wave action');
  });

  testWidgets('replays the codename flourish each time the tab becomes visible', (tester) async {
    final state = peopled();
    addTearDown(state.dispose);

    // Stood up off-screen: initState withholds the flourish, so it sits at its
    // start and the codename is invisible.
    await tester.pumpWidget(wrapVisible(state, visible: false));
    await tester.pump();
    expect(warpOpacity(tester), 0.0, reason: 'a hidden tab holds the flourish at frame zero');

    // The tab comes on screen: didUpdateWidget restarts the animation from zero,
    // so mid-flight the codename is part-way faded in.
    await tester.pumpWidget(wrapVisible(state, visible: true));
    await tester.pump(const Duration(milliseconds: 325));
    final mid = warpOpacity(tester);
    expect(mid, greaterThan(0.0));
    expect(mid, lessThan(1.0));
    await tester.pumpAndSettle();
    expect(warpOpacity(tester), 1.0, reason: 'the flourish lands fully opaque');

    // Leaving and returning replays it from the start, not from where it rested.
    await tester.pumpWidget(wrapVisible(state, visible: false));
    await tester.pump();
    await tester.pumpWidget(wrapVisible(state, visible: true));
    await tester.pump(const Duration(milliseconds: 16));
    expect(warpOpacity(tester), lessThan(1.0), reason: 'a return to the tab restarts the flourish');
    await tester.pumpAndSettle();
  });
}
