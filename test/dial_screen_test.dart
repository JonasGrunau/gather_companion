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

  testWidgets('shows the space name, and everyone in it including the offline', (tester) async {
    final state = peopled();
    addTearDown(state.dispose);
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    expect(find.text('SafeNow'), findsOneWidget);
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
}
