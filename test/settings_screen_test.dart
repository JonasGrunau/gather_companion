/// The settings tab, which is mostly a screen that reads state back to you.
///
/// Worth pinning because it is the one place the app explains itself, and the
/// four connection states have to stay four different sentences. A revoked
/// credential asking you to wait, or a healthy connection that will not say
/// which space it is in, are both the kind of wrong that nobody notices until
/// they are trying to work out why nothing is arriving.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/link_status.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/settings_screen.dart';
import 'package:gather_events/gather_events.dart';

void main() {
  AppState withLink(LinkStatus link, {String? space}) => AppState()
    ..debugApplyLink(link)
    ..debugApplySnapshot(PresenceSnapshot(
      self: SelfState(spaceId: 'space-1', spaceName: space),
      players: const [],
      health: const CollectorHealth(logTail: true, cdp: true),
      at: DateTime(2026, 8, 4, 12, 30),
    ));

  Widget wrap(AppState state, {VoidCallback? onUnpair}) => MaterialApp(
        theme: buildGatherTheme(),
        home: ListenableBuilder(
          listenable: state,
          builder: (context, _) => SettingsScreen(state: state, onUnpair: onUnpair ?? () {}),
        ),
      );

  testWidgets('a live connection names the space it is in', (tester) async {
    await tester.pumpWidget(wrap(withLink(const LinkStatus(LinkState.live), space: 'HQ')));
    await tester.pump();

    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('In HQ.'), findsOneWidget);
  });

  testWidgets('a live connection without a space name still says it is connected', (tester) async {
    // The space name arrives a moment after the socket does. Saying nothing in
    // that gap is fine; saying "not connected" would not be.
    await tester.pumpWidget(wrap(withLink(const LinkStatus(LinkState.live))));
    await tester.pump();

    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Talking to Gather.'), findsOneWidget);
  });

  testWidgets('a dead credential asks you to act rather than to wait', (tester) async {
    // Kept apart from `retrying` for the reason the link strip keeps them apart:
    // one of these is fixed by waiting and the other never is.
    await tester.pumpWidget(wrap(withLink(const LinkStatus(LinkState.retrying, null, true))));
    await tester.pump();

    expect(find.text('Signed out'), findsOneWidget);
    expect(find.textContaining('Pair again'), findsOneWidget);
    expect(find.text('Reconnecting'), findsNothing);
  });

  testWidgets('a dropped connection says what dropped it when it knows', (tester) async {
    await tester.pumpWidget(wrap(withLink(const LinkStatus(LinkState.retrying, 'the socket closed'))));
    await tester.pump();

    expect(find.text('Reconnecting'), findsOneWidget);
    expect(find.text('the socket closed'), findsOneWidget);
  });

  testWidgets('an unreachable computer says what that costs', (tester) async {
    // The bridge only does pairing and push now, so "unreachable" has one
    // consequence worth naming rather than a hostname worth staring at.
    await tester.pumpWidget(wrap(withLink(const LinkStatus(LinkState.live))));
    await tester.pump();

    expect(find.textContaining('notifications may not arrive'), findsOneWidget);
  });

  testWidgets('the device check is a place you go, not a switch you flip', (tester) async {
    // It opens the camera in `initState` and holds it until it is disposed, so
    // it has to be pushed and left rather than parked behind another tab.
    await tester.pumpWidget(wrap(withLink(const LinkStatus(LinkState.live))));
    await tester.pump();

    expect(find.text('Mic & camera'), findsOneWidget);
    // Exactly one chevron on the screen, and it is this row's. Reconnect and
    // "Forget this computer" are tappable but go nowhere, and a chevron next to
    // either would be promising a screen that does not exist.
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
  });

  testWidgets('forgetting the computer calls through exactly once', (tester) async {
    var forgotten = 0;
    await tester.pumpWidget(wrap(
      withLink(const LinkStatus(LinkState.live)),
      onUnpair: () => forgotten++,
    ));
    await tester.pump();

    await tester.tap(find.text('Forget this computer'));
    await tester.pump();

    expect(forgotten, 1);
  });
}
