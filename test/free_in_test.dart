/// When a colleague next frees up, computed from their cached calendar. The "free in X"
/// countdown must report the end of the *continuous* busy period around now, not the
/// soonest single event end — a chain of back-to-back meetings keeps them busy until the
/// last one ends, even though an earlier one finishes sooner.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/google_calendar.dart';

GoogleEvent _event(DateTime start, DateTime end, {bool allDay = false}) =>
    GoogleEvent(
      id: '${start.toIso8601String()}-${end.toIso8601String()}',
      title: 'Busy',
      startsAt: start,
      endsAt: end,
      allDay: allDay,
    );

void main() {
  final now = DateTime(2026, 10, 16, 9, 45);
  DateTime at(int h, int m) => DateTime(2026, 10, 16, h, m);

  group('freeInFromEvents', () {
    test('no timed event covering now means no countdown', () {
      expect(freeInFromEvents(const [], now), isNull);
      expect(freeInFromEvents([_event(at(11, 0), at(12, 0))], now), isNull);
    });

    test('a single active event frees up at its end', () {
      final free = freeInFromEvents([_event(at(9, 30), at(10, 0))], now);
      expect(free, const Duration(minutes: 15));
    });

    test('back-to-back events merge into one busy span', () {
      // 09:30–10:00 then 10:00–11:00: busy until 11:00, not "free in 15".
      final free = freeInFromEvents([
        _event(at(9, 30), at(10, 0)),
        _event(at(10, 0), at(11, 0)),
      ], now);
      expect(free, const Duration(hours: 1, minutes: 15));
    });

    test('overlapping events extend the span to the latest end', () {
      // An active 09:00–11:00 with a shorter 09:30–10:00 inside it: busy until 11:00.
      final free = freeInFromEvents([
        _event(at(9, 0), at(11, 0)),
        _event(at(9, 30), at(10, 0)),
      ], now);
      expect(free, const Duration(hours: 1, minutes: 15));
    });

    test('a real gap ends the busy span before a later event', () {
      // 09:30–10:00, then a gap, then 10:15–11:00: they free up at 10:00.
      final free = freeInFromEvents([
        _event(at(9, 30), at(10, 0)),
        _event(at(10, 15), at(11, 0)),
      ], now);
      expect(free, const Duration(minutes: 15));
    });

    test('all-day events are ignored', () {
      final free = freeInFromEvents([
        _event(at(0, 0), at(23, 59), allDay: true),
        _event(at(9, 30), at(10, 0)),
      ], now);
      expect(free, const Duration(minutes: 15));
    });
  });
}
