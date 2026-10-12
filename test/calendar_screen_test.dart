/// The Plans tab at the widget level: that it says so when there is nothing
/// planned, draws a card with the meeting's name, time and room under the right
/// day header, and that the delete action takes a meeting off the glass.
///
/// The create sheet's date and time pickers are platform dialogs, exercised by
/// `calendar_state_test.dart` at the `AppState` level instead; this is about what
/// the screen puts up and what its buttons do.
library;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/calendar.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/calendar_screen.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  PlannedMeeting meeting({
    String id = 'm1',
    String title = 'Standup',
    Duration fromNow = const Duration(hours: 2),
    String? roomName = 'Lounge',
  }) {
    final start = DateTime.now().add(fromNow);
    return PlannedMeeting(
      id: id,
      title: title,
      startsAt: start,
      endsAt: start.add(const Duration(minutes: 30)),
      roomStableId: roomName == null ? null : 'stable',
      roomName: roomName,
    );
  }

  Widget wrap(AppState state) => MaterialApp(
        theme: buildGatherTheme(),
        home: CalendarScreen(state: state),
      );

  testWidgets('an empty calendar says so and offers the add button', (tester) async {
    await tester.pumpWidget(wrap(AppState()));

    expect(find.textContaining('No plans yet'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('a planned meeting shows its name, room and today header', (tester) async {
    final state = AppState()..debugPlannedMeetings = [meeting(title: 'Design review')];

    await tester.pumpWidget(wrap(state));

    expect(find.text('Design review'), findsOneWidget);
    expect(find.text('Lounge'), findsOneWidget);
    // Two hours out is still today.
    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('Walk here'), findsOneWidget);
  });

  testWidgets('a meeting with no room offers no walk action', (tester) async {
    final state = AppState()..debugPlannedMeetings = [meeting(roomName: null)];

    await tester.pumpWidget(wrap(state));

    expect(find.text('Walk here'), findsNothing);
    expect(find.text('Delete'), findsOneWidget);
  });

  testWidgets('deleting a meeting takes it off the list', (tester) async {
    final state = AppState()..debugPlannedMeetings = [meeting(title: 'Standup')];

    await tester.pumpWidget(wrap(state));
    expect(find.text('Standup'), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Standup'), findsNothing);
    expect(state.plannedMeetings, isEmpty);
  });

  testWidgets('a past meeting is kept under Earlier with no walk action', (tester) async {
    final state = AppState()
      ..debugPlannedMeetings = [meeting(title: 'Yesterday sync', fromNow: const Duration(hours: -26))];

    await tester.pumpWidget(wrap(state));

    expect(find.text('EARLIER'), findsOneWidget);
    expect(find.text('Yesterday sync'), findsOneWidget);
    expect(find.text('Walk here'), findsNothing);
  });

  testWidgets('the add button opens the new-meeting sheet', (tester) async {
    await tester.pumpWidget(wrap(AppState()));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.text('New meeting'), findsOneWidget);
    expect(find.text('Add meeting'), findsOneWidget);
  });
}
