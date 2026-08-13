/// The control bar and the status sheet.
///
/// What is worth pinning here is not the drawing — it is the two rules the bar
/// keeps repeating. A control that cannot do anything is *absent* rather than
/// dimmed, so the conversation button appears with a conversation and goes with
/// it. And every action answers: a refusal reaches the person as a sentence
/// rather than as a tap that did nothing, which is the whole contract
/// `setPartyMode` established and everything here follows.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/link_status.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/control_bar.dart';

RosterRow _row(String id, {String? name, String? availability}) => RosterRow(
      id: id,
      name: name,
      x: 5,
      y: 5,
      floorId: 'f1',
      connected: true,
      availability: availability,
    );

void main() {
  Widget wrap(AppState state) => MaterialApp(
        theme: buildGatherTheme(),
        home: Scaffold(
          // The bar puts failures in a snack bar, which needs a Scaffold to land
          // in — the real one is the shell's.
          body: Align(
            alignment: Alignment.bottomCenter,
            // The shell wraps the bar in exactly this, because it lives outside
            // the `IndexedStack` and so has no listener of its own.
            child: ListenableBuilder(
              listenable: state,
              builder: (context, _) => ControlBar(state: state),
            ),
          ),
        ),
      );

  /// A paired app that knows which avatar is ours, which is what the bar draws
  /// itself from.
  AppState connected({String? availability}) => AppState()
    ..debugApplyLink(const LinkStatus(LinkState.live))
    ..debugApplyRoster(Roster(
      selfId: 'me',
      rows: [_row('me', name: 'Jonas', availability: availability)],
    ));

  testWidgets('the bar carries you, your hardware and the room', (tester) async {
    await tester.pumpWidget(wrap(connected()));

    expect(find.byTooltip('Your status'), findsOneWidget);
    // Both start off, and off is what the label says — nothing here claims to be
    // carrying audio before anybody has asked it to.
    expect(find.byTooltip('Unmute'), findsOneWidget);
    expect(find.byTooltip('Turn the camera on'), findsOneWidget);
    expect(find.byTooltip('React'), findsOneWidget);
    expect(find.byTooltip('Raise your hand'), findsOneWidget);
  });

  testWidgets('the camera flip is only there once there is a camera to flip',
      (tester) async {
    await tester.pumpWidget(wrap(connected()));

    expect(
      find.byTooltip('Switch camera'),
      findsNothing,
      reason: 'absent rather than dimmed, like everything else here',
    );
  });

  testWidgets('leaving the conversation appears with one and goes with it',
      (tester) async {
    // The rosters differ by who is in them rather than only by the seam, because
    // that is what actually happens: a conversation starts when somebody walks up
    // to you, and `debugApplyRoster` deliberately stays silent for a roster the
    // tracker finds nothing in.
    final state = connected();
    await tester.pumpWidget(wrap(state));
    expect(find.byTooltip('Leave the conversation'), findsNothing);

    state.debugHuddle = ['Ada'];
    state.debugApplyRoster(Roster(
      selfId: 'me',
      rows: [_row('me', name: 'Jonas'), _row('ada', name: 'Ada')],
    ));
    await tester.pump();
    expect(find.byTooltip('Leave the conversation'), findsOneWidget);

    state.debugHuddle = const [];
    state.debugApplyRoster(Roster(selfId: 'me', rows: [_row('me', name: 'Jonas')]));
    await tester.pump();
    expect(find.byTooltip('Leave the conversation'), findsNothing);
  });

  group('the reaction tray', () {
    testWidgets('opens on the button and holds Gather\'s eight', (tester) async {
      await tester.pumpWidget(wrap(connected()));
      expect(find.text('👋'), findsNothing);

      await tester.tap(find.byTooltip('React'));
      await tester.pumpAndSettle();

      for (final emote in ['👋', '❤️', '🎉', '👍️', '🤣', '👏', '💯', '🔥']) {
        expect(find.text(emote), findsOneWidget, reason: 'the bar is missing $emote');
      }
    });

    testWidgets('picking one closes the tray and says so when it cannot send',
        (tester) async {
      // No collector, so the send is refused — which is exactly what proves the
      // button is wired to `AppState` rather than only to `setState`.
      await tester.pumpWidget(wrap(connected()));
      await tester.tap(find.byTooltip('React'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('🎉'));
      await tester.pumpAndSettle();

      expect(find.text('🎉'), findsNothing, reason: 'the tray closes behind a pick');
      expect(find.text('Not connected to Gather.'), findsOneWidget);
    });
  });

  group('the status sheet', () {
    testWidgets('opens off the avatar and offers the three you can set',
        (tester) async {
      await tester.pumpWidget(wrap(connected(availability: 'Busy')));

      await tester.tap(find.byTooltip('Your status'));
      await tester.pumpAndSettle();

      expect(find.text('Jonas'), findsOneWidget);
      // Three choices, and the current one named again underneath the name.
      expect(find.text('Active'), findsOneWidget);
      expect(find.text('Busy'), findsNWidgets(2));
      expect(find.text('Away'), findsOneWidget);
      expect(find.text('Update your status'), findsOneWidget);
    });

    testWidgets('picking a state reports a refusal rather than swallowing it',
        (tester) async {
      await tester.pumpWidget(wrap(connected()));
      await tester.tap(find.byTooltip('Your status'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Away'));
      await tester.pumpAndSettle();

      expect(find.text('Not connected to Gather.'), findsOneWidget);
    });

    testWidgets('there is nothing to clear until something has been set',
        (tester) async {
      await tester.pumpWidget(wrap(connected()));
      await tester.tap(find.byTooltip('Your status'));
      await tester.pumpAndSettle();

      expect(find.text('Clear it'), findsNothing);
    });
  });
}
