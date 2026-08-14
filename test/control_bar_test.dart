/// The control bar and the status sheet.
///
/// What is worth pinning here is not the drawing — it is the two rules the bar
/// keeps repeating. A control that cannot do anything is *absent* rather than
/// dimmed, so the conversation button appears with a conversation and goes with
/// it. And every action answers: a refusal reaches the person as a sentence
/// rather than as a tap that did nothing, which is the whole contract
/// `setPartyMode` established and everything here follows.
///
/// The desk is the one documented exception to the first rule, so it is tested as
/// an exception: absent when there is no desk, dim when you are already at it, and
/// inert rather than quietly failing while it is dim.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/link_status.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/control_bar.dart';

RosterRow _row(
  String id, {
  String? name,
  String? availability,
  String? deskId,
  num x = 5,
  num y = 5,
}) =>
    RosterRow(
      id: id,
      name: name,
      x: x,
      y: y,
      floorId: 'f1',
      connected: true,
      availability: availability,
      deskId: deskId,
    );

/// A floor with one desk on it, at 10,10 and two tiles square.
///
/// `stableId` and not `id`: `SpaceUser.deskId` points at the area's
/// `MapEntityIdentifier`, and a test that matched on `id` would pass against a
/// reading of the roster that finds nobody's desk in production.
SpaceMap _floorWithADesk() => SpaceMap(
      floorId: 'f1',
      width: 20,
      height: 20,
      blocked: const {},
      rooms: const [
        SpaceRoom(
          id: 'area-1',
          stableId: 'desk-1',
          name: null,
          type: 'Desk',
          x: 10,
          y: 10,
          width: 2,
          height: 2,
          walled: false,
        ),
      ],
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
  });

  testWidgets('a muted microphone is grey, not red', (tester) async {
    await tester.pumpWidget(wrap(connected()));
    final t = tester.element(find.byTooltip('Unmute')).tokens;

    for (final off in ['Unmute', 'Turn the camera on']) {
      final icon = tester.widget<Icon>(
        find.descendant(of: find.byTooltip(off), matching: find.byType(Icon)),
      );
      expect(
        icon.color,
        t.mutedForeground,
        reason: '$off: the crossed-out glyph is the state — see the header',
      );
    }
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

  group('back to my desk', () {
    /// Paired, on a floor with a desk, standing wherever [at] says.
    AppState atDesk({String? deskId, required int x, required int y}) => AppState()
      ..debugApplyLink(const LinkStatus(LinkState.live))
      ..debugMap = _floorWithADesk()
      ..debugApplyRoster(Roster(
        selfId: 'me',
        rows: [_row('me', name: 'Jonas', deskId: deskId, x: x, y: y)],
      ));

    testWidgets('is absent for somebody Gather has given no desk', (tester) async {
      await tester.pumpWidget(wrap(atDesk(x: 5, y: 5)));

      expect(
        find.byIcon(Icons.meeting_room_rounded),
        findsNothing,
        reason: 'dimming it would tell them they are sitting at a desk they '
            'have never had',
      );
    });

    testWidgets('is red and walks you back when you are away from it',
        (tester) async {
      final state = atDesk(deskId: 'desk-1', x: 5, y: 5);
      await tester.pumpWidget(wrap(state));

      final button = find.byTooltip('Back to my desk');
      expect(button, findsOneWidget);
      expect(
        tester
            .widget<Icon>(
                find.descendant(of: button, matching: find.byType(Icon)))
            .color,
        tester.element(button).tokens.danger,
      );

      // The refusal is the proof it is wired to `AppState` and not only to the
      // widget: there is no socket here, so the walk cannot start.
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('Not connected to Gather.'), findsOneWidget);
    });

    testWidgets('is dim and does nothing once you are sitting at it',
        (tester) async {
      // 11,10 rather than 10,10: anywhere inside the desk's rectangle counts,
      // which is what `currentMapArea === desk` means.
      await tester.pumpWidget(wrap(atDesk(deskId: 'desk-1', x: 11, y: 10)));

      final button = find.byTooltip('You are at your desk');
      expect(button, findsOneWidget);

      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(
        find.text('Not connected to Gather.'),
        findsNothing,
        reason: 'a dimmed control is inert, not merely quiet about failing',
      );
    });
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

    testWidgets('opening it does not change how wide the dock is', (tester) async {
      // Measured the way the dock measures — an `IntrinsicWidth` over a floor of
      // [kRailMinWidth], which is `_Dock` in home_shell.dart — because that is
      // where the bug was: eight 40-point reactions measured 328 against a floor
      // of 320, so the island grew by eight points as the tray opened and shrank
      // back as a reaction was picked, under the thumb reaching for it.
      //
      // Not asserted through the whole shell. There the navigation labels are
      // wider than the tray under the test font and the island is set by them, so
      // a shell-level test would pass against the bug and prove nothing.
      final state = connected();
      await tester.pumpWidget(MaterialApp(
        theme: buildGatherTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: IntrinsicWidth(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: kRailMinWidth),
                child: ListenableBuilder(
                  listenable: state,
                  builder: (context, _) => ControlBar(state: state),
                ),
              ),
            ),
          ),
        ),
      ));

      final shut = tester.getSize(find.byType(ControlBar)).width;
      expect(shut, kRailMinWidth, reason: 'the controls alone sit on the floor');

      await tester.tap(find.byTooltip('React'));
      await tester.pumpAndSettle();

      expect(find.text('👋'), findsOneWidget, reason: 'the tray really did open');
      expect(tester.getSize(find.byType(ControlBar)).width, shut);
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
