import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/app_state.dart';

/// The loosened Gather-label → shared-calendar matching: a short handle has to find a
/// calendar named for the whole person or their address, without ever landing on the
/// wrong one. Driven through the public [AppState.hasCalendarFor] over a seeded index.
void main() {
  AppState seeded(Map<String, String> index) =>
      AppState()..debugSeedCalendarIndex(index);

  group('hasCalendarFor name matching', () {
    test('exact name still matches', () {
      final s = seeded({'jaime': 'cal-jaime'});
      expect(s.hasCalendarFor('jaime'), isTrue);
    });

    test('first name matches a full display name', () {
      final s = seeded({'jaime garcía': 'cal-jaime'});
      expect(s.hasCalendarFor('jaime'), isTrue);
    });

    test('handle matches the local part of an email calendar', () {
      final s = seeded({'jaime@safenow.de': 'cal-jaime'});
      expect(s.hasCalendarFor('jaime'), isTrue);
    });

    test('a role suffix on the label is ignored', () {
      final s = seeded({'dio moretti': 'cal-dio'});
      expect(s.hasCalendarFor('dio (extern)'), isTrue);
    });

    test('a title prefix on the label is ignored', () {
      final s = seeded({'simon weber': 'cal-simon'});
      expect(s.hasCalendarFor('dr. simon'), isTrue);
    });

    test('a handle that is a prefix of the full first name matches', () {
      final s = seeded({'jaimeg mertens': 'cal-jaimeg'});
      expect(s.hasCalendarFor('jaimeg'), isTrue);
    });

    test('unrelated name does not match', () {
      final s = seeded({'bernd huber': 'cal-bernd'});
      expect(s.hasCalendarFor('jaime'), isFalse);
    });

    test('the shared email domain cannot carry a match', () {
      // Everyone is @safenow.de; a label must match a person, not the domain.
      final s = seeded({
        'andi@safenow.de': 'cal-andi',
        'bernd@safenow.de': 'cal-bernd',
      });
      expect(s.hasCalendarFor('safenow'), isFalse);
    });

    test('a label matching two calendars resolves to neither', () {
      // Two different Simons: cannot tell them apart, so show nothing rather than guess.
      final s = seeded({
        'simon weber': 'cal-simon-weber',
        'simon klein': 'cal-simon-klein',
      });
      expect(s.hasCalendarFor('simon'), isFalse);
    });

    test('two calendar names for the same id is not ambiguous', () {
      // Same person under two share names resolves fine — one id, not two.
      final s = seeded({
        'jaime garcía': 'cal-jaime',
        'jaime@safenow.de': 'cal-jaime',
      });
      expect(s.hasCalendarFor('jaime'), isTrue);
    });

    test('topical calendars never match a person handle', () {
      // The real-world index that started this: holidays, birthdays, projects.
      final s = seeded({
        'holidays in germany': 'cal-hol',
        'personio safenow geburtstage': 'cal-bday',
        'bmw': 'cal-bmw',
        'mercedes': 'cal-mb',
        'setups (prev events)': 'cal-setup',
      });
      for (final handle in ['andi', 'benni', 'jaime', 'hannes', 'ines']) {
        expect(s.hasCalendarFor(handle), isFalse, reason: handle);
      }
    });

    test('short fragment does not over-reach into a longer name', () {
      // "jan" is under four chars, so it cannot prefix-match "janet".
      final s = seeded({'janet fischer': 'cal-janet'});
      expect(s.hasCalendarFor('jan'), isFalse);
    });

    test('disconnected account matches nothing', () {
      final s = AppState(); // never seeded → not connected
      expect(s.hasCalendarFor('jaime'), isFalse);
    });
  });
}
