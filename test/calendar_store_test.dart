/// The planned-meeting model and its keychain store.
///
/// Two things are worth pinning. A plan survives a round trip through JSON with
/// every field it was given — a dropped `roomStableId` would mean a meeting that
/// can no longer be walked to, and a dropped `deviceEventId` would orphan its
/// mirrored calendar event. And a store that cannot read one row does not lose the
/// rest: a single corrupt record is dropped, not the whole calendar.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/calendar.dart';
import 'package:gather_companion/src/calendar_store.dart';

PlannedMeeting _meeting({
  String id = 'm1',
  String title = 'Standup',
  DateTime? start,
  String? roomStableId = 'room-stable-7',
  String? roomName = 'Green Park',
  String? deviceEventId,
}) {
  final s = start ?? DateTime(2026, 10, 13, 9, 30);
  return PlannedMeeting(
    id: id,
    title: title,
    startsAt: s,
    endsAt: s.add(const Duration(minutes: 30)),
    roomStableId: roomStableId,
    roomName: roomName,
    floorId: 'floor-1',
    remindMinutesBefore: 10,
    deviceEventId: deviceEventId,
  );
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  CalendarStore store() => CalendarStore(storage: const FlutterSecureStorage());

  test('a meeting survives a round trip through JSON with every field', () {
    final before = _meeting(deviceEventId: 'dev-99');
    final after = PlannedMeeting.fromJson(before.toJson());

    expect(after.id, before.id);
    expect(after.title, before.title);
    expect(after.startsAt, before.startsAt);
    expect(after.endsAt, before.endsAt);
    expect(after.roomStableId, before.roomStableId);
    expect(after.roomName, before.roomName);
    expect(after.floorId, before.floorId);
    expect(after.remindMinutesBefore, 10);
    expect(after.deviceEventId, 'dev-99');
  });

  test('times are persisted as UTC instants and round-trip to the same moment', () {
    // A bare local ISO string carries no offset, so after a time-zone change it would
    // be re-read in the new zone and the meeting would slide. Persisting the UTC `…Z`
    // form pins the instant; it is converted back to local on load.
    final before = _meeting(start: DateTime(2026, 10, 13, 9, 30));
    final json = before.toJson();

    expect(json['startsAt'], endsWith('Z'));
    expect(json['endsAt'], endsWith('Z'));
    expect(DateTime.parse(json['startsAt']! as String).isUtc, isTrue);

    final after = PlannedMeeting.fromJson(json);
    expect(after.startsAt.isUtc, isFalse); // handed back in local time
    expect(after.startsAt.isAtSameMomentAs(before.startsAt), isTrue);
    expect(after.endsAt.isAtSameMomentAs(before.endsAt), isTrue);
  });

  test('remindAt is the start minus the lead, and a bare meeting defaults to five', () {
    final m = PlannedMeeting(
      id: 'x',
      title: 'Sync',
      startsAt: DateTime(2026, 10, 13, 15, 0),
      endsAt: DateTime(2026, 10, 13, 15, 30),
    );

    expect(m.remindMinutesBefore, 5);
    expect(m.remindAt, DateTime(2026, 10, 13, 14, 55));
  });

  test('withDeviceEventId changes only the mirror id', () {
    final before = _meeting();
    final after = before.withDeviceEventId('dev-123');

    expect(after.deviceEventId, 'dev-123');
    expect(after.id, before.id);
    expect(after.title, before.title);
    expect(after.roomStableId, before.roomStableId);
  });

  test('a fresh install has no meetings', () async {
    expect(await store().load(), isEmpty);
  });

  test('what was saved comes back, soonest and latest alike', () async {
    final a = _meeting(id: 'a', title: 'A', start: DateTime(2026, 10, 13, 9, 0));
    final b = _meeting(id: 'b', title: 'B', start: DateTime(2026, 10, 14, 11, 0));
    await store().save([a, b]);

    final back = await store().load();

    expect(back.map((m) => m.id), ['a', 'b']);
    expect(back.map((m) => m.title), ['A', 'B']);
  });

  test('one unreadable row is dropped, the rest survive', () async {
    // A record written by a newer build, or a corrupted one: it must not take the
    // whole calendar down with it.
    final good = _meeting(id: 'good');
    await store().save([good]);
    // Smuggle a broken second row in alongside the good one.
    const storage = FlutterSecureStorage();
    final raw = await storage.read(key: 'calendar.meetings');
    final tampered = raw!.replaceFirst('[', '[{"id":"broken"},');
    await storage.write(key: 'calendar.meetings', value: tampered);

    final back = await store().load();

    expect(back.map((m) => m.id), ['good'], reason: 'the broken row is skipped, not fatal');
  });

  test('clearing leaves nothing behind', () async {
    await store().save([_meeting()]);
    await store().clear();

    expect(await store().load(), isEmpty);
  });
}
