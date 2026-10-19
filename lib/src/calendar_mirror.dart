/// The one bridge a plan made here has back to Gather's own calendar.
///
/// Gather reads its Calendar Panel from a connected Google/Outlook account, and we
/// have no way to write that account directly — no Gather calendar API exists, and
/// this app has no backend of its own. What it *can* reach is the phone's native
/// calendar. If that calendar is the same Google/Outlook account Gather is
/// connected to, an event written here surfaces in Gather too, the long way round.
/// If it is not, it is still a real calendar entry on the phone, with the OS's own
/// reminder — which is the whole of what mirroring promises.
///
/// This is a seam, defaulted to [NoopCalendarMirror], for two reasons the codebase
/// already lives by. One: the real implementation is a native plugin, and
/// everything above the microphone and the keychain is kept testable on a machine
/// that has neither — a widget test gets the no-op and never touches a calendar.
/// Two: the native calendar plugin carries its own iOS build weight, so the one
/// place it is named is `main.dart`, exactly as the media engine is.
///
/// Every method is best-effort by contract: a denied permission, a missing plugin
/// or a calendar that has gone away returns null (or does nothing) rather than
/// throwing. Mirroring is a bonus on top of a plan that is already saved locally;
/// it must never be the thing that fails a save.
library;

import 'calendar.dart';

/// A calendar the phone can write to.
class MirrorCalendar {
  const MirrorCalendar({required this.id, required this.name, this.accountName});

  final String id;
  final String name;

  /// The account it belongs to — "work@…", "iCloud" — shown in the picker so two
  /// calendars with the same name can be told apart.
  final String? accountName;
}

abstract class CalendarMirror {
  /// The calendars the phone will let us write to, for the settings picker. Empty
  /// when permission has not been granted or there are none.
  Future<List<MirrorCalendar>> writableCalendars();

  /// Creates or updates [meeting] in [calendarId] and returns the device event id
  /// to remember, or null if nothing could be written. When
  /// [PlannedMeeting.deviceEventId] is already set, the existing event is updated
  /// in place rather than a duplicate created.
  Future<String?> createOrUpdate(PlannedMeeting meeting, {required String calendarId});

  /// Removes a previously mirrored event. A no-op when [deviceEventId] is null.
  Future<void> delete(String? deviceEventId, {required String calendarId});
}

/// The default: a calendar that is never there. Mirroring asked for on a build
/// with no plugin — every widget test, and `dart test` — resolves to this, so the
/// settings picker shows nothing to mirror into and the save path writes nothing.
class NoopCalendarMirror implements CalendarMirror {
  const NoopCalendarMirror();

  @override
  Future<List<MirrorCalendar>> writableCalendars() async => const [];

  @override
  Future<String?> createOrUpdate(PlannedMeeting meeting, {required String calendarId}) async => null;

  @override
  Future<void> delete(String? deviceEventId, {required String calendarId}) async {}
}
