/// Who is in the conversation with me — the question a call has to answer first.
///
/// Gather computes this server-side and publishes it as `SpaceUser.clusterId`.
/// Sharing a non-null value with somebody is what the video bubble means, and it
/// is the signal a call joins and leaves on, so the ways of misreading it all cost
/// something: opening a call with nobody in it, never opening one, or keeping a
/// tile for somebody whose socket has already died.
library;

import 'package:gather_client/gather_client.dart';
import 'package:test/test.dart';

const _me = 'me-1';

/// A dump that establishes identity, plus whatever rows a test asks for.
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

/// A `replace` on one field of one row, which is how a bubble forms on the wire.
Map<String, Object?> _replace(String id, String path, Object? data) =>
    {'op': 'replace', 'model': 'SpaceUser', 'id': id, 'path': path, 'data': data};

Roster _read(List<Map<String, Object?>> frames) {
  final reader = GameProtocolReader()..authUserId = 'uid-1';
  for (final frame in frames) {
    reader.ingest(frame);
  }
  return reader.roster();
}

void main() {
  test('standing alone is an empty cluster, not an unknown one', () {
    final roster = _read([
      _dump([
        {'id': _me, 'name': 'Me', 'connected': true, 'clusterId': null},
        {'id': 'them-1', 'name': 'Them', 'connected': true, 'clusterId': null},
      ]),
    ]);

    expect(roster.myCluster, isEmpty);
    // Both rows carried the key, so we genuinely know we are alone rather than
    // merely failing to tell.
    expect(roster.rows.every((r) => r.clusterIdKnown), isTrue);
  });

  test('sharing a cluster id is what puts somebody in the call', () {
    final roster = _read([
      _dump([
        {'id': _me, 'name': 'Me', 'connected': true, 'clusterId': 'bubble-1'},
        {'id': 'them-1', 'name': 'Them', 'connected': true, 'clusterId': 'bubble-1'},
        {'id': 'other-1', 'name': 'Other', 'connected': true, 'clusterId': 'bubble-2'},
        {'id': 'alone-1', 'name': 'Alone', 'connected': true, 'clusterId': null},
      ]),
    ]);

    expect(roster.myCluster.map((r) => r.id), ['them-1']);
  });

  test('a bubble forming arrives as a replace patch, not a new row', () {
    // The reason `clusterId` has to be in the tracked-field set: Gather patches
    // the field on rows that already exist, so a reader that only reads whole
    // rows would watch a call form and see nothing at all.
    final roster = _read([
      _dump([
        {'id': _me, 'name': 'Me', 'connected': true, 'clusterId': null},
        {'id': 'them-1', 'name': 'Them', 'connected': true, 'clusterId': null},
      ]),
      _delta([
        _replace(_me, '/clusterId', 'bubble-1'),
        _replace('them-1', '/clusterId', 'bubble-1'),
      ]),
    ]);

    expect(roster.myCluster.map((r) => r.id), ['them-1']);
  });

  test('walking away empties the cluster again', () {
    final roster = _read([
      _dump([
        {'id': _me, 'name': 'Me', 'connected': true, 'clusterId': 'bubble-1'},
        {'id': 'them-1', 'name': 'Them', 'connected': true, 'clusterId': 'bubble-1'},
      ]),
      _delta([_replace(_me, '/clusterId', null)]),
    ]);

    expect(roster.myCluster, isEmpty);
  });

  test('a cluster member whose socket died is not still in the call', () {
    // A cluster outlives the moment somebody drops, so without this the call
    // would hold a tile open for a person who has gone.
    final roster = _read([
      _dump([
        {'id': _me, 'name': 'Me', 'connected': true, 'clusterId': 'bubble-1'},
        {'id': 'them-1', 'name': 'Them', 'connected': true, 'clusterId': 'bubble-1'},
        {'id': 'gone-1', 'name': 'Gone', 'connected': false, 'clusterId': 'bubble-1'},
      ]),
    ]);

    expect(roster.myCluster.map((r) => r.id), ['them-1']);
  });

  test('not knowing our own cluster is not the same as being alone', () {
    // Absent is not null. If the dump never carried the field, the honest answer
    // is that there is no call to join — but the flag has to say why, because
    // something acting on it would otherwise be acting on missing data.
    final roster = _read([
      _dump([
        {'id': _me, 'name': 'Me', 'connected': true},
        {'id': 'them-1', 'name': 'Them', 'connected': true},
      ]),
    ]);

    expect(roster.myCluster, isEmpty);
    expect(roster.rows.every((r) => r.clusterIdKnown), isFalse);
  });

  test('the cluster is empty until the dump says which avatar is ours', () {
    final reader = GameProtocolReader()..authUserId = 'nobody';
    reader.ingest(_dump([
      {'id': 'them-1', 'name': 'Them', 'connected': true, 'clusterId': 'bubble-1'},
      {'id': 'them-2', 'name': 'Also', 'connected': true, 'clusterId': 'bubble-1'},
    ]));

    final roster = reader.roster();
    expect(roster.selfId, isNull);
    expect(roster.myCluster, isEmpty, reason: 'a cluster we are not in is not our call');
  });
}
