import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/link_status.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/feed_screen.dart';
import 'package:gather_events/gather_events.dart';

/// Widget-level checks for the one thing the screen exists to say: who is
/// following you.
///
/// Being followed would otherwise only ever be seen by arranging for a colleague
/// to actually follow you, which is no way to know whether the card renders.
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
          builder: (context, _) => FeedScreen(state: state, onUnpair: () {}),
        ),
      );

  testWidgets('an empty room says so rather than looking broken', (tester) async {
    await tester.pumpWidget(wrap(connected(snapshotWith(const []))));
    await tester.pump();

    expect(find.text('Nobody is following you'), findsOneWidget);
  });

  testWidgets('an unreachable link says so, but not straight away', (tester) async {
    // The difference matters: silence because nothing happened is reassuring,
    // silence because Gather is unreachable is not. Only the strip says which.
    final state = AppState()..debugApplySnapshot(snapshotWith(const []));
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    // Not straight away: a launch that connects quickly must not flash a banner
    // in and out, so an unhealthy link has to persist before it takes a row.
    expect(find.text('Not connected'), findsNothing);

    // Explicit pumps rather than pumpAndSettle: the strip carries an
    // indeterminate spinner, so the tree is never quiescent.
    await tester.pump(const Duration(milliseconds: 700)); // past the grace
    await tester.pump(const Duration(milliseconds: 300)); // past the reveal

    expect(find.text('Not connected'), findsOneWidget);
  });

  testWidgets('being followed shows the alert card by name', (tester) async {
    final state = connected(snapshotWith([
        PlayerRef(
          id: 'a',
          name: 'Ada',
          isFollowingMe: true,
          followingMeSince: DateTime.now().subtract(const Duration(minutes: 3)),
        ),
        // In the space but not following: must not appear here.
        const PlayerRef(id: 'c', name: 'Cleo'),
      ]));
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    expect(find.text('Ada is following you'), findsOneWidget);
    expect(find.text('for 3 min'), findsOneWidget);
    expect(find.text('Cleo'), findsNothing);
  });

  testWidgets('several followers are named on chips', (tester) async {
    final state = connected(snapshotWith([
        const PlayerRef(id: 'a', name: 'Ada', isFollowingMe: true),
        const PlayerRef(id: 'b', name: 'Bram', isFollowingMe: true),
      ]));
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    expect(find.text('2 people are following you'), findsOneWidget);
    expect(find.text('Ada'), findsOneWidget);
    expect(find.text('Bram'), findsOneWidget);
  });

  testWidgets('a follower who is talking is marked as talking', (tester) async {
    // Somebody following you *and* speaking is the case this app exists for, so
    // `speaking` has to reach the screen — it is drawn nowhere else.
    final state = connected(snapshotWith([
        const PlayerRef(id: 'a', name: 'Ada', isFollowingMe: true, speaking: true),
      ]));
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    expect(find.text('Ada is following you'), findsOneWidget);
    expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);
  });

  testWidgets('a lone quiet follower gets no redundant chip', (tester) async {
    // The title already says the name; repeating it underneath is noise.
    final state = connected(snapshotWith([
        const PlayerRef(id: 'a', name: 'Ada', isFollowingMe: true),
      ]));
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    expect(find.text('Ada is following you'), findsOneWidget);
    expect(find.text('Ada'), findsNothing);
    expect(find.byIcon(Icons.graphic_eq_rounded), findsNothing);
  });

  testWidgets('the party button reads the bridge, not its own memory', (tester) async {
    // The bridge stops party mode by itself — on its timer, when it loses
    // Gather, when the daemon exits. A button holding local state would keep
    // glowing through all three, so it renders the snapshot and nothing else.
    final state = connected(snapshotWith(const []));
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    expect(find.text('Party mode'), findsOneWidget);
    expect(find.text('Teleport around the map!'), findsOneWidget);

    state.debugApplySnapshot(PresenceSnapshot(
      self: const SelfState(spaceId: 'space-1'),
      players: const [],
      health: const CollectorHealth(logTail: true, cdp: true),
      at: at,
      party: const PartyState(active: true, hops: 12, safeTiles: 40),
    ));
    await tester.pump();

    expect(find.text('Hopping four times a second'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);

    // Standing still because there is nowhere safe is not a fault, and saying so
    // beats a card that claims to be hopping while nothing moves.
    state.debugApplySnapshot(PresenceSnapshot(
      self: const SelfState(spaceId: 'space-1'),
      players: const [],
      health: const CollectorHealth(logTail: true, cdp: true),
      at: at,
      party: const PartyState(active: true, detail: 'everywhere known is within 8 tiles of someone'),
    ));
    await tester.pump();

    expect(find.text('everywhere known is within 8 tiles of someone'), findsOneWidget);

    // Let the controller stop before the test tears the tree down.
    state.debugApplySnapshot(snapshotWith(const []));
    await tester.pump();
  });

  test('a refresh lasts long enough to be seen', () async {
    // Regression: `reconnect()` used to return void, so the pull-to-refresh
    // future completed on the next microtask and the indicator snapped shut
    // within a frame or two of appearing — a twitch rather than a refresh.
    final state = AppState();
    final watch = Stopwatch()..start();
    await state.reconnect();
    watch.stop();

    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(400));
  });
}
