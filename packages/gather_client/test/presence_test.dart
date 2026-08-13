/// Who is actually in the room — which `connected` does not answer.
///
/// Measured against a real 98-row space on 2026-08-13: **twelve** rows carried
/// `connected: true` and **nine** of those were `Offline`, one of them for a day. A
/// socket that dies without saying goodbye leaves the flag behind it, so a client
/// that trusts it draws bodies where the desktop app shows nobody and reports eleven
/// people in an office holding three.
///
/// Availability alone is no better — thirty-one rows were not `Offline`, because
/// people close the app without touching it. Presence is the pair, and these pin
/// both halves and the wire shape that carries the second one.
library;

import 'package:gather_client/gather_client.dart';
import 'package:test/test.dart';

const _me = 'me-1';

Map<String, Object?> _availability(String value) =>
    {r'$type': 'SpaceUserAvailability', 'value': value};

Map<String, Object?> _direction(String value) => {r'$type': 'Direction', 'value': value};

Map<String, Object?> _dump(List<Map<String, Object?>> users) => {
      'type': 'FullStateChunk',
      'fullStatePatches': [
        {
          'op': 'addmodel',
          'model': 'Connection',
          'data': {'id': 'c1', 'authUserId': 'uid-1', 'spaceUserId': _me},
        },
        for (final user in users) {'op': 'addmodel', 'model': 'SpaceUser', 'data': user},
      ],
    };

Map<String, Object?> _delta(List<Map<String, Object?>> patches) =>
    {'type': 'DeltaState', 'patches': patches};

Map<String, Object?> _replace(String id, String path, Object? data) =>
    {'op': 'replace', 'model': 'SpaceUser', 'id': id, 'path': path, 'data': data};

Roster _read(List<Map<String, Object?>> frames) {
  final reader = GameProtocolReader()..authUserId = 'uid-1';
  for (final frame in frames) {
    reader.ingest(frame);
  }
  return reader.roster();
}

RosterRow _row(Roster roster, String id) => roster.rows.firstWhere((r) => r.id == id);

void main() {
  test('connected and not offline is present; either half missing is not', () {
    final roster = _read([
      _dump([
        {'id': _me, 'name': 'Me', 'connected': true, 'userSetAvailability': _availability('Active')},
        {
          'id': 'here',
          'name': 'Here',
          'connected': true,
          'userSetAvailability': _availability('Active'),
        },
        {
          'id': 'busy',
          'name': 'Busy',
          'connected': true,
          'userSetAvailability': _availability('Busy'),
        },
        {
          // The shape the bug wore: the flag says yes, the person went home.
          'id': 'ghost',
          'name': 'Ghost',
          'connected': true,
          'userSetAvailability': _availability('Offline'),
        },
        {
          'id': 'closed',
          'name': 'Closed the app',
          'connected': false,
          'userSetAvailability': _availability('Active'),
        },
      ]),
    ]);

    expect(_row(roster, 'here').isPresent, isTrue);
    expect(_row(roster, 'busy').isPresent, isTrue, reason: 'busy is still in the building');
    expect(_row(roster, 'ghost').isPresent, isFalse);
    expect(_row(roster, 'closed').isPresent, isFalse);
  });

  test('a row that never says either way is taken at its word', () {
    // Absent availability is not "offline": a space that has never published the
    // field would otherwise read as empty.
    final roster = _read([
      _dump([
        {'id': _me, 'connected': true},
        {'id': 'quiet', 'connected': true},
      ]),
    ]);

    expect(_row(roster, 'quiet').availability, isNull);
    expect(_row(roster, 'quiet').isPresent, isTrue);
  });

  test('going away arrives as a patch on the value object, not the row', () {
    // The live path, and the one that would silently drop: availability is an ext-0
    // value object, so leaving is `/userSetAvailability/value`, one level down.
    final roster = _read([
      _dump([
        {'id': _me, 'connected': true},
        {
          'id': 'ada',
          'name': 'Ada',
          'connected': true,
          'userSetAvailability': _availability('Active'),
        },
      ]),
      _delta([_replace('ada', '/userSetAvailability/value', 'Offline')]),
    ]);

    expect(_row(roster, 'ada').availability, 'Offline');
    expect(_row(roster, 'ada').isPresent, isFalse);
  });

  test('and coming back replaces the whole object', () {
    final roster = _read([
      _dump([
        {'id': _me, 'connected': true},
        {
          'id': 'ada',
          'connected': true,
          'userSetAvailability': _availability('Offline'),
        },
      ]),
      _delta([_replace('ada', '/userSetAvailability', _availability('Active'))]),
    ]);

    expect(_row(roster, 'ada').isPresent, isTrue);
  });

  test('direction is a value object too, not a bare string', () {
    // The shape this test used to invent, and the bug it let through: `direction`
    // arrives as `{$type: 'Direction', value: 'Right'}` — measured on all 98 rows of
    // a live dump — exactly like availability. Read as a plain string it comes back
    // null for everybody, and `Facing.of(null)` is south, so the office fills up with
    // people staring at the floor and it looks like a rendering default rather than a
    // field that was never parsed.
    final roster = _read([
      _dump([
        {'id': _me, 'connected': true},
        {'id': 'ada', 'connected': true, 'direction': _direction('Down')},
      ]),
      _delta([_replace('ada', '/direction', _direction('Up'))]),
    ]);

    expect(_row(roster, 'ada').direction, 'Up');
  });

  test('turning around arrives as a patch on the value object, on its own', () {
    // You can face a new way without moving — and every step sends the turn before
    // the position — so `/direction/value` is the common case, not the rare one.
    final roster = _read([
      _dump([
        {'id': _me, 'connected': true},
        {'id': 'ada', 'connected': true, 'direction': _direction('Down')},
      ]),
      _delta([_replace('ada', '/direction/value', 'Left')]),
    ]);

    expect(_row(roster, 'ada').direction, 'Left');
  });
}
