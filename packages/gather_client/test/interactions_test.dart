/// The four things somebody can do *at* you, and the ways of getting them wrong.
///
/// Two arrive on Gather's event bus (a wave, a chat message) and two are read out
/// of state (a meeting invite, a knock on a meeting). The state pair is where the
/// traps are, because the same rows arrive in the initial dump as well as in the
/// deltas — and a dump row is history, not news.
library;

import 'package:gather_client/gather_client.dart';
import 'package:gather_events/gather_events.dart';
import 'package:test/test.dart';

const _me = 'me-1';
const _them = 'them-1';

/// The dump: enough to establish identity, plus whatever else is asked for.
Map<String, Object?> _dump(List<Map<String, Object?>> extra) => {
      'type': 'FullStateChunk',
      'fullStatePatches': [
        {
          'op': 'addmodel',
          'model': 'Connection',
          'data': {'id': 'c1', 'authUserId': 'uid-1', 'spaceUserId': _me},
        },
        {
          'op': 'addmodel',
          'model': 'SpaceUser',
          'data': {'id': _them, 'name': 'Neighbour', 'connected': true},
        },
        ...extra,
      ],
    };

Map<String, Object?> _delta(List<Map<String, Object?>> patches) =>
    {'type': 'DeltaState', 'patches': patches};

Map<String, Object?> _participant({
  required String id,
  required String spaceUserId,
  String? inviterId,
  String meetingId = 'meeting-1',
}) =>
    {
      'op': 'addmodel',
      'model': 'MeetingParticipant',
      'data': {
        'id': id,
        'spaceUserId': spaceUserId,
        'meetingId': meetingId,
        'inviterId': ?inviterId,
        'inviteStatus': inviterId == null ? 'NotInvited' : 'InvitedRequired',
        'createdAt': '2026-08-07T08:01:42.405Z',
      },
    };

Map<String, Object?> _joinRequest({
  required String id,
  required String asker,
  String meetingId = 'meeting-1',
  String? respondedAt,
}) =>
    {
      'op': 'addmodel',
      'model': 'MeetingJoinRequest',
      'data': {
        'id': id,
        'spaceUserId': asker,
        'meetingId': meetingId,
        'respondedAt': ?respondedAt,
        'createdAt': '2026-08-07T09:45:21.834Z',
      },
    };

/// Feeds frames through a reader and folds whatever comes out.
List<GatherEvent> run(List<Map<String, Object?>> frames) {
  final reader = GameProtocolReader()..authUserId = 'uid-1';
  final tracker = PresenceTracker();
  final out = <GatherEvent>[];
  for (final frame in frames) {
    if (reader.ingest(frame)) tracker.applyRoster(reader.roster());
    tracker.applyRoster(reader.roster());
    for (final event in reader.takePending()) {
      out.addAll(tracker.applyInteraction(event).emit);
    }
  }
  return out;
}

void main() {
  group('meeting invites', () {
    test('an invite in a delta is reported, and names who sent it', () {
      final events = run([
        _dump(const []),
        _delta([_participant(id: 'p1', spaceUserId: _me, inviterId: _them)]),
      ]);

      final shown = events.whereType<NotificationShownEvent>().single;
      expect(shown.notificationType, 'meeting invite');
      expect(shown.senderId, _them);
      expect(shown.body, 'Neighbour invited you to a meeting');
    });

    test('the same invites in the state dump are history, not news', () {
      // The trap. 56 `MeetingParticipant` rows arrived in the measured space, four
      // of them naming us. Reporting those would announce every meeting we have ever
      // been invited to — on every reconnect, and this collector reconnects whenever
      // the phone wakes up.
      final events = run([
        _dump([
          _participant(id: 'p1', spaceUserId: _me, inviterId: _them),
          _participant(id: 'p2', spaceUserId: _me, inviterId: _them, meetingId: 'm2'),
        ]),
      ]);

      expect(events, isEmpty);
    });

    test('a row we created by walking in is not an invitation', () {
      // No `inviterId`: nobody invited us, we just turned up.
      final events = run([
        _dump(const []),
        _delta([_participant(id: 'p1', spaceUserId: _me)]),
      ]);

      expect(events, isEmpty);
    });

    test("somebody else's invite is not ours", () {
      final events = run([
        _dump(const []),
        _delta([_participant(id: 'p1', spaceUserId: 'someone-else', inviterId: _them)]),
      ]);

      expect(events, isEmpty);
    });

    test('a dump row seen again as a delta is still not news', () {
      // Gather re-sends rows: an `updatedAt` touch, a response being recorded. Only
      // the first sighting of an id can be an invitation.
      final events = run([
        _dump([_participant(id: 'p1', spaceUserId: _me, inviterId: _them)]),
        _delta([_participant(id: 'p1', spaceUserId: _me, inviterId: _them)]),
      ]);

      expect(events, isEmpty);
    });

    test('an invite arriving before we know who we are is still reported', () {
      // Identity is one `Connection` patch among ~1500 and is not guaranteed to land
      // first. Judging against a null selfId and moving on would drop it silently.
      final reader = GameProtocolReader()..authUserId = 'uid-1';
      final tracker = PresenceTracker();

      // A delta *before* any dump: selfId is unknown when the row arrives.
      reader.ingest(_delta([_participant(id: 'p1', spaceUserId: _me, inviterId: _them)]));
      expect(reader.takePending(), isEmpty, reason: 'held, not judged');

      reader.ingest(_dump(const []));
      tracker.applyRoster(reader.roster());
      final out = <GatherEvent>[];
      for (final event in reader.takePending()) {
        out.addAll(tracker.applyInteraction(event).emit);
      }

      expect(out.whereType<NotificationShownEvent>().single.notificationType,
          'meeting invite');
    });
  });

  group('somebody knocking on a meeting', () {
    /// Puts us in `meeting-1` first, the way the dump would.
    List<Map<String, Object?>> inMeeting(List<Map<String, Object?>> then) => [
          _dump([_participant(id: 'mine', spaceUserId: _me)]),
          ...then.map((p) => _delta([p])),
        ];

    test('an unanswered request on our meeting is reported', () {
      final events = run(inMeeting([_joinRequest(id: 'j1', asker: _them)]));

      final shown = events.whereType<NotificationShownEvent>().single;
      expect(shown.notificationType, 'meeting join request');
      expect(shown.body, 'Neighbour is asking to join your meeting');
    });

    test('one already answered is not', () {
      // `respondedAt` is msgpack `undefined` when absent, not null — so this asks
      // what an answer looks like rather than testing for the absence of one.
      final events = run(inMeeting([
        _joinRequest(id: 'j1', asker: _them, respondedAt: '2026-08-07T09:45:23.710Z'),
      ]));

      expect(events, isEmpty);
    });

    test('a knock on a meeting we are not in is not ours to answer', () {
      final events = run(inMeeting([
        _joinRequest(id: 'j1', asker: _them, meetingId: 'someone-elses-meeting'),
      ]));

      expect(events, isEmpty);
    });
  });

  group('chat', () {
    Map<String, Object?> chat(String text, {String from = _them}) => {
          'type': 'DeltaState',
          'patches': const <Object?>[],
          'events': [
            {
              'payload': {
                'eventName': 'ChatBroadcastNewMessage',
                'senderId': from,
                'message': {
                  'id': 'c1',
                  'message': text,
                  'spaceUserId': from,
                  'chatChannelId': 'channel-1',
                },
              },
              'options': const <String, Object?>{},
            },
          ],
        };

    test('a message becomes a chat event with its text and channel', () {
      final events = run([_dump(const []), chat('are you around?')]);

      final message = events.whereType<ChatMessageEvent>().single;
      expect(message.text, 'are you around?');
      expect(message.playerId, _them);
      expect(message.channel, 'channel-1');
    });

    test('the empty system rows every meeting join writes are not chat', () {
      // Observed on the wire: 45 `ChatBroadcastNewMessage`es, most with `message: ""`.
      final events = run([_dump(const []), chat('')]);

      expect(events, isEmpty);
    });

    test('our own message is not news to us', () {
      final events = run([_dump(const []), chat('hello', from: _me)]);

      expect(events, isEmpty);
    });
  });

  test('an eventName nobody has wording for is dropped, not guessed at', () {
    final events = run([
      _dump(const []),
      {
        'type': 'DeltaState',
        'patches': const <Object?>[],
        'events': [
          {
            'payload': {'eventName': 'SomethingNewEvent', 'senderId': _them},
            'options': {
              'targetUserIds': [_me],
            },
          },
        ],
      },
    ]);

    expect(events, isEmpty, reason: 'guessing wrong on a lock screen beats silence');
  });
}
