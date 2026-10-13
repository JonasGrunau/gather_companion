/// Planned meetings at the `AppState` level: that adding one keeps it, editing one
/// replaces it in place, deleting one removes it, and that the device-calendar
/// mirror is driven exactly when it should be — on add when mirroring is on, and
/// backfilled for existing plans the moment it is turned on.
///
/// The keychain is mocked, so the store is real; the mirror is a fake that records
/// what it was asked to write. The reminder scheduler is never initialised here —
/// a bare `Notifier` no-ops until `init`, which is the production guard too — so a
/// meeting's reminder path runs without a platform behind it.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/calendar.dart';
import 'package:gather_companion/src/calendar_mirror.dart';
import 'package:gather_companion/src/calendar_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records every write and hands back a predictable id, so a test can see both
/// that the mirror was driven and that the id it returned is kept on the meeting.
class FakeCalendarMirror implements CalendarMirror {
  final List<PlannedMeeting> created = [];
  final List<String> deleted = [];
  List<MirrorCalendar> calendars = const [
    MirrorCalendar(id: 'work', name: 'Work', accountName: 'me@work'),
  ];
  int _n = 0;

  @override
  Future<List<MirrorCalendar>> writableCalendars() async => calendars;

  @override
  Future<String?> createOrUpdate(PlannedMeeting meeting, {required String calendarId}) async {
    created.add(meeting);
    // Keep an existing id stable on update; mint one on create.
    return meeting.deviceEventId ?? 'dev-${_n++}';
  }

  @override
  Future<void> delete(String? deviceEventId, {required String calendarId}) async {
    if (deviceEventId != null) deleted.add(deviceEventId);
  }
}

/// A mirror whose write never lands — [createOrUpdate] always returns null, as a
/// denied permission or a vanished calendar would. Used to prove a plan is still
/// kept, and left un-suppressed, when the calendar refuses it.
class _FailingMirror implements CalendarMirror {
  @override
  Future<List<MirrorCalendar>> writableCalendars() async =>
      const [MirrorCalendar(id: 'work', name: 'Work')];

  @override
  Future<String?> createOrUpdate(PlannedMeeting meeting, {required String calendarId}) async => null;

  @override
  Future<void> delete(String? deviceEventId, {required String calendarId}) async {}
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  PlannedMeeting meeting({
    String id = 'm1',
    String title = 'Standup',
    Duration fromNow = const Duration(hours: 2),
    String? roomName = 'Lounge',
    String? deviceEventId,
  }) {
    final start = DateTime.now().add(fromNow);
    return PlannedMeeting(
      id: id,
      title: title,
      startsAt: start,
      endsAt: start.add(const Duration(minutes: 30)),
      roomStableId: roomName == null ? null : 'stable-$roomName',
      roomName: roomName,
      remindMinutesBefore: 5,
      deviceEventId: deviceEventId,
    );
  }

  AppState appState({CalendarMirror? mirror}) =>
      AppState(calendarStore: CalendarStore(storage: const FlutterSecureStorage()), calendarMirror: mirror);

  test('a meeting added is kept, in the list and on disk', () async {
    final state = appState();

    final error = await state.addMeeting(meeting());

    expect(error, isNull);
    expect(state.plannedMeetings.map((m) => m.id), ['m1']);
    // Reloaded from the store, so it really landed in the keychain.
    expect((await CalendarStore(storage: const FlutterSecureStorage()).load()).map((m) => m.id), ['m1']);
  });

  test('the list comes back soonest first regardless of insertion order', () async {
    final state = appState();
    await state.addMeeting(meeting(id: 'late', fromNow: const Duration(days: 2)));
    await state.addMeeting(meeting(id: 'soon', fromNow: const Duration(hours: 1)));

    expect(state.plannedMeetings.map((m) => m.id), ['soon', 'late']);
  });

  test('editing replaces in place, keeping the id', () async {
    final state = appState();
    await state.addMeeting(meeting(title: 'Standup'));

    final error = await state.updateMeeting(meeting(title: 'Retro'));

    expect(error, isNull);
    expect(state.plannedMeetings.single.title, 'Retro');
    expect(state.plannedMeetings.single.id, 'm1');
  });

  test('deleting removes it from the list and the store', () async {
    final state = appState();
    await state.addMeeting(meeting());

    final error = await state.deleteMeeting('m1');

    expect(error, isNull);
    expect(state.plannedMeetings, isEmpty);
    expect(await CalendarStore(storage: const FlutterSecureStorage()).load(), isEmpty);
  });

  test('with mirroring off, no calendar is written and nothing is pinned', () async {
    final mirror = FakeCalendarMirror();
    final state = appState(mirror: mirror);

    await state.addMeeting(meeting());

    expect(mirror.created, isEmpty);
    expect(state.plannedMeetings.single.deviceEventId, isNull);
  });

  test('with mirroring on, a new meeting is written and its device id kept', () async {
    final mirror = FakeCalendarMirror();
    final state = appState(mirror: mirror);
    await state.setMirrorCalendar('work');

    await state.addMeeting(meeting());

    expect(mirror.created, hasLength(1));
    expect(state.plannedMeetings.single.deviceEventId, 'dev-0');
  });

  test('turning mirroring on backfills the plans that are not yet mirrored', () async {
    final mirror = FakeCalendarMirror();
    final state = appState(mirror: mirror);
    await state.addMeeting(meeting(id: 'a'));
    await state.addMeeting(meeting(id: 'b'));
    expect(mirror.created, isEmpty, reason: 'nothing mirrored while it was off');

    await state.setMirrorCalendar('work');

    expect(mirror.created.map((m) => m.id).toSet(), {'a', 'b'});
    expect(state.plannedMeetings.every((m) => m.deviceEventId != null), isTrue);
  });

  test('turning mirroring off forgets the device ids but keeps the plans', () async {
    final mirror = FakeCalendarMirror();
    final state = appState(mirror: mirror);
    await state.setMirrorCalendar('work');
    await state.addMeeting(meeting());
    expect(state.plannedMeetings.single.deviceEventId, isNotNull);

    await state.setMirrorCalendar(null);

    // The plan stays; its calendar event is left in place (not deleted) but its id is
    // forgotten, so the app's own reminder is free to fire for it again.
    expect(state.plannedMeetings, hasLength(1));
    expect(state.plannedMeetings.single.deviceEventId, isNull);
    expect(mirror.deleted, isEmpty);
    // It survives a reload — the cleared id was persisted, not just dropped in memory.
    final reloaded = await CalendarStore(storage: const FlutterSecureStorage()).load();
    expect(reloaded.single.deviceEventId, isNull);
  });

  test('switching calendars re-mirrors every future plan into the new one', () async {
    final mirror = FakeCalendarMirror()
      ..calendars = const [
        MirrorCalendar(id: 'work', name: 'Work'),
        MirrorCalendar(id: 'home', name: 'Home'),
      ];
    final state = appState(mirror: mirror);
    await state.setMirrorCalendar('work');
    await state.addMeeting(meeting());
    mirror.created.clear();

    await state.setMirrorCalendar('home');

    // The old id named an event in Work, so switching pushes the plan into Home
    // afresh rather than leaving it behind — the stale-id skip that used to strand it
    // is gone.
    expect(mirror.created.map((m) => m.id), ['m1']);
    expect(state.plannedMeetings.single.deviceEventId, isNotNull);
  });

  test('a mirror write that fails to return an id does not suppress the plan', () async {
    final mirror = _FailingMirror();
    final state = appState(mirror: mirror);
    await state.setMirrorCalendar('work');

    final error = await state.addMeeting(meeting());

    // The plan is kept regardless, and carries no device id — so nothing thinks a
    // calendar alert exists for it and its own reminder stands.
    expect(error, isNull);
    expect(state.plannedMeetings.single.deviceEventId, isNull);
  });

  test('deleting a mirrored meeting removes its calendar event too', () async {
    final mirror = FakeCalendarMirror();
    final state = appState(mirror: mirror);
    await state.setMirrorCalendar('work');
    await state.addMeeting(meeting());
    final deviceId = state.plannedMeetings.single.deviceEventId;

    await state.deleteMeeting('m1');

    expect(mirror.deleted, [deviceId]);
  });

  test('writableCalendars passes the mirror through for the settings picker', () async {
    final mirror = FakeCalendarMirror();
    final state = appState(mirror: mirror);

    expect((await state.writableCalendars()).map((c) => c.id), ['work']);
  });
}
