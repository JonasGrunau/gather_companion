/// The shell, which is the first thing in this app that is above a single screen.
///
/// Two of these tests are about navigation and the rest are about the thing that
/// made the shell worth writing carefully: the office has to be *kept* when you
/// leave it, not rebuilt when you come back. Its decoded artwork, where you have
/// panned to, and whether the opening shot has already played all live on the
/// screen's `State`, so "did the same State survive a round trip" is the honest
/// question, and the one asserted here. The rest — muted tickers, and the 4Hz
/// position feed only reaching the map while the map is what you are looking at —
/// are the two leaks that keeping it alive would otherwise open.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/link_status.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/activity_screen.dart';
import 'package:gather_companion/ui/control_bar.dart';
import 'package:gather_companion/ui/home_shell.dart';
import 'package:gather_companion/ui/map_screen.dart';
import 'package:gather_companion/ui/settings_screen.dart';
import 'package:gather_events/gather_events.dart';

void main() {
  AppState connected() => AppState()
    ..debugApplyLink(const LinkStatus(LinkState.live))
    ..debugApplySnapshot(PresenceSnapshot(
      self: const SelfState(spaceId: 'space-1', spaceName: 'HQ'),
      players: const [],
      health: const CollectorHealth(logTail: true, cdp: true),
      at: DateTime(2026, 8, 4, 12, 30),
    ));

  Widget wrap(AppState state, {VoidCallback? onUnpair}) => MaterialApp(
        theme: buildGatherTheme(),
        home: ListenableBuilder(
          listenable: state,
          builder: (context, _) => HomeShell(state: state, onUnpair: onUnpair ?? () {}),
        ),
      );

  testWidgets('activity is what the app opens on', (tester) async {
    await tester.pumpWidget(wrap(connected()));
    await tester.pump();

    expect(find.text('Nobody is following you'), findsOneWidget);
    // The other two are in the tree but not on screen, which is the whole point.
    expect(find.textContaining('Reading the floor plan'), findsNothing);
    expect(find.byType(MapScreen, skipOffstage: false), findsOneWidget);
  });

  testWidgets('the controls belong to the office and travel with it', (tester) async {
    // They are one dock rather than two floating bars, so this is a section of
    // the same island appearing and disappearing — the navigation underneath is
    // there throughout.
    final state = connected();
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    expect(find.byType(ControlBar), findsNothing, reason: 'not on the activity tab');

    await tester.tap(find.byTooltip('The office'));
    await tester.pumpAndSettle();
    expect(find.byType(ControlBar), findsOneWidget);
    expect(find.byTooltip('Your status'), findsOneWidget);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(ControlBar), findsNothing);
    // And the rail is still there, which is the difference between a section
    // closing up and the whole dock leaving.
    expect(find.byTooltip('The office'), findsOneWidget);
  });

  testWidgets('every destination on the rail goes somewhere', (tester) async {
    // Also the only thing pinning rail order to `IndexedStack` order. They were
    // parallel hand-written lists once, and reordering `_Tab` without reordering
    // the children swapped two tabs' bodies — the rail said Activity and the
    // office appeared.
    await tester.pumpWidget(wrap(connected()));
    await tester.pump();

    await tester.tap(find.byTooltip('The office'));
    await tester.pump();
    expect(find.textContaining('Reading the floor plan'), findsOneWidget);
    expect(find.text('Nobody is following you'), findsNothing);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();
    expect(find.text('Forget this computer'), findsOneWidget);
    expect(find.textContaining('Reading the floor plan'), findsNothing);

    await tester.tap(find.byTooltip('Activity'));
    await tester.pump();
    expect(find.text('Nobody is following you'), findsOneWidget);
  });

  testWidgets('leaving the office and coming back returns to it rather than rebuilding it', (tester) async {
    // The guarantee behind the `IndexedStack`. `_MapScreenState` owns the art
    // cache — 573 decoded images on the reference space — and `_PlanState` owns
    // where you have panned to and whether the opening shot has played. A new
    // State means all three are gone, which is the difference between coming
    // back to the office and reloading it.
    await tester.pumpWidget(wrap(connected()));
    await tester.pump();

    await tester.tap(find.byTooltip('The office'));
    await tester.pump();
    final before = tester.state(find.byType(MapScreen));

    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();
    // Still in the tree while it is not on screen.
    expect(find.byType(MapScreen), findsNothing);
    expect(find.byType(MapScreen, skipOffstage: false), findsOneWidget);

    await tester.tap(find.byTooltip('The office'));
    await tester.pump();

    expect(identical(tester.state(find.byType(MapScreen, skipOffstage: false)), before), isTrue);
  });

  testWidgets('a tab you are not looking at has its clocks stopped', (tester) async {
    // Kept alive is not the same as kept running. `MapMotion` walks people at
    // 60fps and the party card's gradient turns on a five-second loop, and
    // neither of them can tell that it is behind another tab.
    await tester.pumpWidget(wrap(connected()));
    await tester.pump();

    expect(TickerMode.valuesOf(tester.element(find.byType(ActivityScreen, skipOffstage: false))).enabled, isTrue);
    expect(TickerMode.valuesOf(tester.element(find.byType(MapScreen, skipOffstage: false))).enabled, isFalse);

    await tester.tap(find.byTooltip('The office'));
    await tester.pump();

    expect(TickerMode.valuesOf(tester.element(find.byType(ActivityScreen, skipOffstage: false))).enabled, isFalse);
    expect(TickerMode.valuesOf(tester.element(find.byType(MapScreen, skipOffstage: false))).enabled, isTrue);
  });

  testWidgets('footsteps only reach the map while the map is the tab you are on', (tester) async {
    // `AppState.positions` exists so that walking repaints the office without
    // waking the rest of the tree. Merging it in unconditionally would undo
    // that from the other side: four rebuilds a second behind the settings list.
    final state = connected();
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    Listenable feeding() => tester
        .widget<ListenableBuilder>(
          find
              .ancestor(
                of: find.byType(MapScreen, skipOffstage: false),
                matching: find.byType(ListenableBuilder),
              )
              .first,
        )
        .listenable;

    // Opening on Activity, so the map is behind another tab: presence only.
    expect(identical(feeding(), state), isTrue,
        reason: 'off the map tab, only presence should rebuild it');

    await tester.tap(find.byTooltip('The office'));
    await tester.pump();

    expect(identical(feeding(), state), isFalse,
        reason: 'on the map tab it should be fed positions too');
  });

  testWidgets('the rail says which destination you are on', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(wrap(connected()));
    await tester.pump();

    expect(tester.getSemantics(find.byTooltip('Activity')), isSemantics(isButton: true, isSelected: true));
    expect(tester.getSemantics(find.byTooltip('Settings')), isSemantics(isButton: true, isSelected: false));

    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();

    expect(tester.getSemantics(find.byTooltip('Activity')), isSemantics(isSelected: false));
    expect(tester.getSemantics(find.byTooltip('Settings')), isSemantics(isSelected: true));

    handle.dispose();
  });

  testWidgets('forgetting the computer is reachable, and only from settings', (tester) async {
    var forgotten = 0;
    await tester.pumpWidget(wrap(connected(), onUnpair: () => forgotten++));
    await tester.pump();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();
    expect(find.byType(SettingsScreen), findsOneWidget);

    await tester.tap(find.text('Forget this computer'));
    await tester.pump();

    expect(forgotten, 1);
  });
}
