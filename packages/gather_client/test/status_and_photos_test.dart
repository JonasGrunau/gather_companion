/// The status line, and the id behind a face.
///
/// Both are joins the wire does not make for you, and both were got wrong in an
/// obvious way first. The status looked like it should hang off
/// `SpaceUser.activeCustomStatusId`; on a live 98-row space that field was never
/// set on anybody, and the link runs the other way. The picture looked like it
/// should be a URL on the `UserFile` row; all three URL fields on all sixty rows
/// came across undefined.
library;

import 'package:gather_client/gather_client.dart';
import 'package:test/test.dart';

/// One `addmodel` patch, as a `FullStateChunk` carries it.
Map<String, Object?> add(String model, Map<String, Object?> data) =>
    {'op': 'addmodel', 'model': model, 'data': data};

Map<String, Object?> chunk(List<Map<String, Object?>> patches) =>
    {'type': 'FullStateChunk', 'fullStatePatches': patches};

RosterRow? rowFor(GameProtocolReader reader, String id) {
  for (final row in reader.roster().rows) {
    if (row.id == id) return row;
  }
  return null;
}

void main() {
  late GameProtocolReader reader;

  setUp(() => reader = GameProtocolReader());

  group('the status line', () {
    test('is joined from the status row, not from a pointer on the person', () {
      // The two pointer fields (`activeCustomStatusId`,
      // `activeUserGeneratedStatusId`) are deliberately absent here, because
      // that is how they arrive: measured across 98 rows, neither was ever set,
      // including on people whose status was on screen at the time.
      reader.ingest(chunk([
        add('SpaceUser', {'id': 'ada', 'name': 'Ada'}),
        add('SpaceUserStatus', {
          'id': 'status-1',
          'spaceUserId': 'ada',
          'text': 'Heads down',
          'emoji': '🎧',
          'type': 'Custom',
        }),
      ]));

      final status = rowFor(reader, 'ada')?.status;
      expect(status?.text, 'Heads down');
      expect(status?.emoji, '🎧');
      expect(status?.isCustom, isTrue);
    });

    test('a calendar one counts too, but a typed one wins over it', () {
      // Half a busy office has a status nobody set by hand — Gather writes them
      // from calendars — so dropping those would leave most people blank. When
      // somebody has both, the one they chose is the one to show.
      reader.ingest(chunk([
        add('SpaceUser', {'id': 'ada', 'name': 'Ada'}),
        add('SpaceUserStatus', {
          'id': 'cal',
          'spaceUserId': 'ada',
          'text': 'Lunch',
          'emoji': '🥗',
          'type': 'CalendarInferred',
        }),
      ]));
      expect(rowFor(reader, 'ada')?.status?.text, 'Lunch');

      reader.ingest(chunk([
        add('SpaceUserStatus', {
          'id': 'mine',
          'spaceUserId': 'ada',
          'text': 'Heads down',
          'type': 'Custom',
        }),
      ]));
      expect(rowFor(reader, 'ada')?.status?.text, 'Heads down');
    });

    test('one that has outlived its clearAt is not shown', () {
      // The row outlives the status. Measured: one set at 16:33 to clear at
      // 17:03 was still on the wire, unchanged, at 20:20. Gather's own client
      // filters on read, so a client that does not shows people at lunch all
      // evening.
      reader.ingest(chunk([
        add('SpaceUser', {'id': 'ada', 'name': 'Ada'}),
        add('SpaceUserStatus', {
          'id': 'stale',
          'spaceUserId': 'ada',
          'text': 'Back at three',
          'type': 'Custom',
          'clearAt': DateTime.utc(2020, 1, 1),
        }),
      ]));

      expect(rowFor(reader, 'ada')?.status, isNull);
    });

    test('clearing it deletes the row, which is the only signal there is', () {
      reader.ingest(chunk([
        add('SpaceUser', {'id': 'ada', 'name': 'Ada'}),
        add('SpaceUserStatus', {
          'id': 'status-1',
          'spaceUserId': 'ada',
          'text': 'Heads down',
          'type': 'Custom',
        }),
      ]));
      expect(rowFor(reader, 'ada')?.status, isNotNull);

      // Nothing on the `SpaceUser` side changes when a status goes away.
      reader.ingest({
        'type': 'DeltaState',
        'patches': [
          {'op': 'deletemodel', 'model': 'SpaceUserStatus', 'id': 'status-1'},
        ],
      });

      expect(rowFor(reader, 'ada')?.status, isNull);
    });

    test('editing the text in place is carried through', () {
      reader.ingest(chunk([
        add('SpaceUser', {'id': 'ada', 'name': 'Ada'}),
        add('SpaceUserStatus', {
          'id': 'status-1',
          'spaceUserId': 'ada',
          'text': 'Heads down',
          'emoji': '🎧',
          'type': 'Custom',
        }),
      ]));

      reader.ingest({
        'type': 'DeltaState',
        'patches': [
          {
            'op': 'replace',
            'model': 'SpaceUserStatus',
            'id': 'status-1',
            'path': '/text',
            'data': 'In a meeting',
          },
        ],
      });

      final status = rowFor(reader, 'ada')?.status;
      expect(status?.text, 'In a meeting');
      expect(status?.emoji, '🎧', reason: 'the rest of the row survives the edit');
    });
  });

  group('the profile picture id', () {
    test('is carried when set and null when not', () {
      // 45 of 98 people had one on the space this was measured against. The
      // other 53 had the field absent rather than empty, which is why "no
      // picture" has to be a null and not a sentinel worth requesting.
      reader.ingest(chunk([
        add('SpaceUser', {
          'id': 'ada',
          'name': 'Ada',
          'profilePictureId': '2f8ae0b0-6169-431a-8939-d191e527bfca',
        }),
        add('SpaceUser', {'id': 'bram', 'name': 'Bram'}),
      ]));

      expect(rowFor(reader, 'ada')?.profilePictureId,
          '2f8ae0b0-6169-431a-8939-d191e527bfca');
      expect(rowFor(reader, 'bram')?.profilePictureId, isNull);
    });

    test('changing your picture arrives as a field patch', () {
      reader.ingest(chunk([
        add('SpaceUser', {'id': 'ada', 'name': 'Ada', 'profilePictureId': 'old'}),
      ]));

      reader.ingest({
        'type': 'DeltaState',
        'patches': [
          {
            'op': 'replace',
            'model': 'SpaceUser',
            'id': 'ada',
            'path': '/profilePictureId',
            'data': 'new',
          },
        ],
      });

      expect(rowFor(reader, 'ada')?.profilePictureId, 'new');
    });
  });
}
