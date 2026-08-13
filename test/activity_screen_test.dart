import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/link_status.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/activity_screen.dart';
import 'package:gather_events/gather_events.dart';

/// Widget-level checks for the history screen: the empty state says which kind
/// of empty it is.
///
/// The follower card used to be pinned here and its tests with it; both moved
/// to the office's app bar — see `map_screen_test.dart` for the badge. The
/// link strip and its deliberate delay went with the strip itself: the
/// settings tab owns up to a dead connection now, and pull-to-refresh no
/// longer drops the socket, which was the strip's main occasion to appear.
void main() {
  final at = DateTime(2026, 8, 4, 12, 30);

  PresenceSnapshot snapshotWith(List<PlayerRef> players) => PresenceSnapshot(
        self: const SelfState(spaceId: 'space-1'),
        players: players,
        health: const CollectorHealth(logTail: true, cdp: true),
        at: at,
      );

  /// A state that believes it is connected, which is the normal case.
  AppState connected(PresenceSnapshot snapshot) => AppState()
    ..debugApplyLink(const LinkStatus(LinkState.live))
    ..debugApplySnapshot(snapshot);

  Widget wrap(AppState state) => MaterialApp(
        theme: buildGatherTheme(),
        home: ListenableBuilder(
          listenable: state,
          builder: (context, _) => ActivityScreen(state: state),
        ),
      );

  testWidgets('an empty history says so rather than looking broken', (tester) async {
    // Fetched and empty — the claim has been checked, so it may be made.
    final state = connected(snapshotWith(const []))..debugApplyActivity(const []);
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    expect(find.textContaining('Waves and meeting notes'), findsOneWidget);
  });

  testWidgets('before the first read answers, bones rather than a claim', (tester) async {
    // Connected and the space named, but the feed not yet fetched: "nothing
    // yet" in this window would be an assertion nobody has checked. The
    // skeleton says "still reading" without words — the words are VoiceOver's.
    final handle = tester.ensureSemantics();
    final state = connected(snapshotWith(const []));
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    expect(find.textContaining('Waves and meeting notes'), findsNothing);
    expect(find.bySemanticsLabel('Reading your activity…'), findsOneWidget);

    // The fetch answers empty: bones give way to the honest sentence.
    state.debugApplyActivity(const []);
    await tester.pump();

    expect(find.bySemanticsLabel('Reading your activity…'), findsNothing);
    expect(find.textContaining('Waves and meeting notes'), findsOneWidget);

    handle.dispose();
  });

}
