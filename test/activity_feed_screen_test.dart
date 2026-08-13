import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/activity_screen.dart';
import 'package:gather_events/gather_events.dart';

/// Widget-level checks for Gather's own activity feed.
///
/// The thing worth pinning here is the read-state split: a meeting memo can be
/// marked read from the phone and a wave cannot, because their read state lives
/// in different places in Gather. A screen that showed an unread dot it could not
/// clear would be lying about what tapping does.
void main() {
  final at = DateTime.utc(2026, 8, 13, 9, 30);

  AppState stateWith(List<ActivityItem> items) => AppState()
    ..debugApplySnapshot(PresenceSnapshot(
      self: const SelfState(spaceId: 'space-1'),
      players: const [PlayerRef(id: 'them', name: 'Ada')],
      health: const CollectorHealth(gather: true),
      at: at,
    ))
    ..debugApplyActivity(items);

  Widget wrap(AppState state) => MaterialApp(
        theme: buildGatherTheme(),
        home: ActivityScreen(state: state),
      );

  WaveActivity wave({String id = 'wave:1'}) =>
      WaveActivity(id: id, at: at, actorSpaceUserId: 'them');

  MeetingArtifactActivity memo({bool isRead = false}) => MeetingArtifactActivity(
        id: 'activity:s1',
        at: at,
        isRead: isRead,
        subscriptionId: 's1',
        // What `/toggle-read-status` is keyed on, and so what makes a row tappable.
        activityEventId: 'e1',
        meetingTitle: 'Daily',
        hasMeetingMemo: true,
        participantCount: 18,
      );

  testWidgets('an empty feed says so rather than looking broken', (tester) async {
    await tester.pumpWidget(wrap(stateWith(const [])));
    await tester.pump();

    expect(find.textContaining('Nothing yet'), findsOneWidget);
  });

  testWidgets('a failed fetch says so, so an empty list is not mistaken for calm',
      (tester) async {
    final state = AppState()..debugApplyActivity(const [], error: 'nope');
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    expect(find.textContaining("Couldn't read your activity"), findsOneWidget);
  });

  testWidgets('a wave names the person, resolved against the roster', (tester) async {
    await tester.pumpWidget(wrap(stateWith([wave()])));
    await tester.pump();

    expect(find.text('Ada waved at you'), findsOneWidget);
  });

  testWidgets('an id with no roster entry still renders, shortened', (tester) async {
    final state = AppState()
      ..debugApplyActivity([
        WaveActivity(id: 'wave:1', at: at, actorSpaceUserId: 'ffcd3ed7-a1aa-4fa5'),
      ]);
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    // `nameFor` falls back to a short id rather than showing nothing.
    expect(find.text('ffcd3ed7 waved at you'), findsOneWidget);
  });

  testWidgets('a meeting memo reads as what it is', (tester) async {
    await tester.pumpWidget(wrap(stateWith([memo()])));
    await tester.pump();

    expect(find.text('Notes ready from Daily'), findsOneWidget);
    expect(find.text('18 people'), findsOneWidget);
  });

  testWidgets('only what can be marked read offers to be', (tester) async {
    // A wave is unread-able: its read state is a chat cursor, not a subscription.
    // The offer is the double-check icon; the words live in its tooltip.
    await tester.pumpWidget(wrap(stateWith([wave()])));
    await tester.pump();
    expect(find.byIcon(Icons.done_all_rounded), findsNothing);

    await tester.pumpWidget(wrap(stateWith([memo()])));
    await tester.pump();
    expect(find.byIcon(Icons.done_all_rounded), findsOneWidget);
    expect(find.byTooltip('Mark all read'), findsOneWidget);
  });

  testWidgets('an already-read item offers nothing to clear', (tester) async {
    await tester.pumpWidget(wrap(stateWith([memo(isRead: true)])));
    await tester.pump();

    expect(find.byIcon(Icons.done_all_rounded), findsNothing);
  });

  testWidgets('the badge counts what is unread', (tester) async {
    final state = stateWith([memo(), memo(isRead: true), wave()]);

    // Waves arrive reported read, so only the one unread memo counts.
    expect(state.unreadActivityCount, 1);
  });

  testWidgets('days are grouped, so a month of feed stays readable', (tester) async {
    final state = AppState()
      ..debugApplyActivity([
        WaveActivity(id: 'wave:1', at: DateTime.now().toUtc(), actorSpaceUserId: 'them'),
        WaveActivity(
          id: 'wave:2',
          at: DateTime.now().toUtc().subtract(const Duration(days: 1)),
          actorSpaceUserId: 'them',
        ),
      ]);
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('YESTERDAY'), findsOneWidget);
  });

  testWidgets('an undecoded kind is named rather than dropped', (tester) async {
    await tester.pumpWidget(wrap(stateWith([
      const UnknownActivity(
        id: 'activity:s9',
        at: null,
        isRead: true,
        kind: 'SomethingGatherAddedLater',
        payload: {},
      ),
    ])));
    await tester.pump();

    expect(find.text('SomethingGatherAddedLater'), findsOneWidget);
    expect(find.text('EARLIER'), findsOneWidget);
  });
}
