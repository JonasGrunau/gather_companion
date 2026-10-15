/// Pulling a Gather destination out of an event's location string. The parser is the
/// gate on the Plans tab's "Go to meeting": it must recognise a real Gather link,
/// reject everything else (so a Zoom link or an address never grows a button), and
/// surface the space id and any room hint for [AppState.gatherRoomFor] to match.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/gather_link.dart';

void main() {
  group('GatherLink.tryParse', () {
    test('reads space id from a v2 app link', () {
      final link = GatherLink.tryParse('https://app.v2.gather.town/app/mySpace123/SafeNow');
      expect(link, isNotNull);
      expect(link!.spaceId, 'mySpace123');
      expect(link.roomHint, isNull);
    });

    test('accepts the plain app.gather.town host', () {
      final link = GatherLink.tryParse('https://app.gather.town/app/spc/Office');
      expect(link?.spaceId, 'spc');
    });

    test('percent-decodes a backslash-bearing space id', () {
      // Gather space ids embed a backslash the URL escapes as %5C.
      final link = GatherLink.tryParse('https://app.v2.gather.town/app/abc123%5CSafeNow/SafeNow');
      expect(link?.spaceId, r'abc123\SafeNow');
    });

    test('takes a room hint from a recognised query parameter', () {
      final link = GatherLink.tryParse('https://app.v2.gather.town/app/spc/Office?room=Green%20Park');
      expect(link?.spaceId, 'spc');
      expect(link?.roomHint, 'Green Park');
    });

    test('takes a room hint from a path segment past the space name', () {
      final link = GatherLink.tryParse('https://app.v2.gather.town/app/spc/Office/Boardroom');
      expect(link?.roomHint, 'Boardroom');
    });

    test('prefers an explicit query parameter over the path tail', () {
      final link = GatherLink.tryParse('https://app.v2.gather.town/app/spc/Office/Ignored?area=Kitchen');
      expect(link?.roomHint, 'Kitchen');
    });

    test('returns null for a non-Gather URL', () {
      expect(GatherLink.tryParse('https://zoom.us/j/123456'), isNull);
      expect(GatherLink.tryParse('https://meet.google.com/abc-defg-hij'), isNull);
    });

    test('returns null for a bare address or empty location', () {
      expect(GatherLink.tryParse('Meeting Room 3, 2nd floor'), isNull);
      expect(GatherLink.tryParse(''), isNull);
      expect(GatherLink.tryParse('   '), isNull);
      expect(GatherLink.tryParse(null), isNull);
    });

    test('returns null when the path carries no space id', () {
      expect(GatherLink.tryParse('https://app.v2.gather.town/'), isNull);
      expect(GatherLink.tryParse('https://app.v2.gather.town/app'), isNull);
      expect(GatherLink.tryParse('https://app.v2.gather.town/app/'), isNull);
    });

    test('rejects a look-alike host that only ends in a different domain', () {
      expect(GatherLink.tryParse('https://gather.town.evil.com/app/spc/X'), isNull);
    });

    test('accepts the apex gather.town host', () {
      expect(GatherLink.tryParse('https://gather.town/app/spc/X')?.spaceId, 'spc');
    });

    test('is host-case-insensitive', () {
      expect(GatherLink.tryParse('https://APP.V2.GATHER.TOWN/app/spc/X')?.spaceId, 'spc');
    });
  });
}
