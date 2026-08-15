import 'package:gather_client/gather_client.dart';
import 'package:test/test.dart';

import 'fake_gather.dart';

/// Builds a body in the shape measured on 2026-08-13. Encoding it rather than
/// checking in a captured blob keeps real colleagues out of the repo and exercises
/// the msgpack round trip on the way past.
List<int> feedBytes({
  List<String> waveIds = const [],
  List<String> subscriptionIds = const [],
  Map<String, Object?> models = const {},
  List<String> mentionIds = const [],
  List<String> reactionIds = const [],
  List<String> replyIds = const [],
}) =>
    msgpackEncode({
      'activityFeed': {
        'chatMessageIdsForActivityFeedWaveItems': waveIds,
        'chatMentionIdsForActivityFeedMentionItems': mentionIds,
        'chatMessageIdsForActivityFeedReactionItems': reactionIds,
        'threadParentIdsForActivityFeedReplyItems': replyIds,
        'activityEventSubscriptionIds': subscriptionIds,
      },
      'serializedModels': models,
    });

Map<String, Object?> waveMessage(String id, {required String at, String? channelId}) => {
      'id': id,
      'message': '',
      'type': 'System',
      // The channel's other party, not the waver — the point of the metadata join.
      'spaceUserId': 'author-not-the-waver',
      'chatChannelId': channelId ?? 'channel-1',
      'createdAt': at,
    };

Map<String, Object?> wavedMetadata(String messageId, {required String actor}) => {
      'id': 'meta-$messageId',
      'chatMessageId': messageId,
      'metadata': {
        'type': chatMetadataWaved,
        'waveRecipientId': 'me',
        'actorSpaceUserId': actor,
      },
    };

ActivityFeed feedWith(FakeGatherHttp http) => ActivityFeed(
      auth: GatherAuth(
        credentials: const GatherCredentials(refreshToken: 'r'),
        http: http,
      ),
      http: http,
    );

void main() {
  group('parseActivityFeed', () {
    test('takes a wave\'s actor from its metadata, not its message author', () {
      final items = parseActivityFeed(
        msgpackDecode(feedBytes(
          waveIds: ['m1'],
          models: {
            'ChatMessage': [waveMessage('m1', at: '2026-08-07T14:27:42.594Z')],
            'ChatMessageMetadata': [wavedMetadata('m1', actor: 'them')],
          },
        )) as Map<String, Object?>,
      );

      expect(items, hasLength(1));
      final wave = items.single as WaveActivity;
      expect(wave.actorSpaceUserId, 'them');
      expect(wave.channelId, 'channel-1');
      expect(wave.at, DateTime.utc(2026, 8, 7, 14, 27, 42, 594));
      // Waves have no subscription row, so they cannot be flipped read.
      expect(wave.canMarkRead, isFalse);
    });

    test('an unread readAt is undefined, not null, and still reads as unread', () {
      // The trap this file exists to keep shut. Bodies here are msgpack, and an
      // unset optional column on this protocol arrives as ext-4 **undefined** —
      // every `undefined` in the observed state dump is that encoding, and
      // `msgpackDecode` maps it to a sentinel that is emphatically not null. A
      // `readAt != null` test therefore calls every unread item read: badge stuck at
      // zero, and `markRead` with nothing left to send.
      //
      // Built as a decoded map rather than through [feedBytes], because the encoder
      // drops undefined keys on the way out by design — msgpack_test.dart is where
      // ext-4 decoding itself is pinned.
      final items = parseActivityFeed({
        'activityFeed': {
          'activityEventSubscriptionIds': ['s1'],
        },
        'serializedModels': {
          'ActivityEventSubscription': [
            {'id': 's1', 'activityEventId': 'e1', 'readAt': msgpackUndefined},
          ],
          'ActivityEvent': [
            {
              'id': 'e1',
              'createdAt': '2026-07-20T10:08:59.101Z',
              'metadata': {'type': activityOnboardingChat},
            },
          ],
        },
      });

      expect(items.single.isRead, isFalse);
      expect(items.single.canMarkRead, isTrue);
    });

    test('joins a subscription to its event and reads unread off readAt', () {
      final items = parseActivityFeed(
        msgpackDecode(feedBytes(
          subscriptionIds: ['s1', 's2'],
          models: {
            'ActivityEventSubscription': [
              {'id': 's1', 'activityEventId': 'e1', 'readAt': null},
              {'id': 's2', 'activityEventId': 'e2', 'readAt': '2026-07-20T10:09:00.000Z'},
            ],
            'ActivityEvent': [
              {
                'id': 'e1',
                'createdAt': '2026-07-20T10:08:59.101Z',
                'metadata': {
                  'type': activityMeetingArtifactReady,
                  'meetingId': 'meeting-1',
                  'meetingTitle': 'Daily',
                  'hasMeetingMemo': true,
                  'hasVideoRecording': false,
                  'meetingParticipantCount': 18,
                },
              },
              {
                'id': 'e2',
                'createdAt': '2025-09-15T07:21:20.851Z',
                'metadata': {'type': activityOnboardingDesk},
              },
            ],
          },
        )) as Map<String, Object?>,
      );

      final artifact = items.first as MeetingArtifactActivity;
      expect(artifact.isRead, isFalse);
      expect(artifact.subscriptionId, 's1');
      expect(artifact.canMarkRead, isTrue);
      expect(artifact.meetingTitle, 'Daily');
      expect(artifact.hasMeetingMemo, isTrue);
      expect(artifact.hasVideoRecording, isFalse);
      expect(artifact.participantCount, 18);

      final onboarding = items.last as OnboardingActivity;
      expect(onboarding.isRead, isTrue);
      expect(onboarding.kind, activityOnboardingDesk);
    });

    test('keeps an unrecognised metadata type instead of dropping or throwing', () {
      final items = parseActivityFeed(
        msgpackDecode(feedBytes(
          subscriptionIds: ['s1'],
          models: {
            'ActivityEventSubscription': [
              {'id': 's1', 'activityEventId': 'e1', 'readAt': null},
            ],
            'ActivityEvent': [
              {
                'id': 'e1',
                'createdAt': '2026-08-13T10:00:00.000Z',
                'metadata': {'type': 'SomethingGatherAddedLater', 'detail': 42},
              },
            ],
          },
        )) as Map<String, Object?>,
      );

      final unknown = items.single as UnknownActivity;
      expect(unknown.kind, 'SomethingGatherAddedLater');
      expect(unknown.isRead, isFalse);
      expect(unknown.canMarkRead, isTrue);
      // The row survives intact, so a decoder can be written from a bug report.
      expect((unknown.payload['metadata']! as Map)['detail'], 42);
    });

    test('tolerates a bucket whose backing model was not sent', () {
      // Measured: a bucket with no items brings no model, so an id list that
      // outruns the store must not throw. Mentions here have neither model.
      final items = parseActivityFeed(
        msgpackDecode(feedBytes(
          waveIds: ['missing'],
          mentionIds: ['also-missing'],
          subscriptionIds: ['no-such-subscription'],
        )) as Map<String, Object?>,
      );

      // The wave and the subscription have nothing to show, so they drop; the
      // mention degrades rather than vanishing, because its id is all we have.
      expect(items, hasLength(1));
      expect(items.single, isA<UnknownActivity>());
      expect((items.single as UnknownActivity).kind, 'mention');
    });

    test('sorts newest first and puts undatable items last', () {
      final items = parseActivityFeed(
        msgpackDecode(feedBytes(
          waveIds: ['old', 'new', 'undated'],
          models: {
            'ChatMessage': [
              waveMessage('old', at: '2026-08-01T00:00:00.000Z'),
              waveMessage('new', at: '2026-08-09T00:00:00.000Z'),
              {'id': 'undated', 'message': '', 'chatChannelId': 'c'},
            ],
            'ChatMessageMetadata': [
              wavedMetadata('old', actor: 'a'),
              wavedMetadata('new', actor: 'b'),
              wavedMetadata('undated', actor: 'c'),
            ],
          },
        )) as Map<String, Object?>,
      );

      expect(items.map((i) => i.id), ['wave:new', 'wave:old', 'wave:undated']);
      expect(items.last.at, isNull);
    });

    test('reads a msgpack ext-1 DateTime as well as an ISO string', () {
      // A msgpack ext-1 field decodes to a DateTime, and sibling fields on this
      // protocol are plain ISO strings, so both have to land on the same instant.
      // Fed in already-decoded: the encoder deliberately refuses a DateTime, so
      // there is no round trip to make here.
      final items = parseActivityFeed({
        'activityFeed': {
          'chatMessageIdsForActivityFeedWaveItems': ['m1'],
        },
        'serializedModels': {
          'ChatMessage': [
            {
              'id': 'm1',
              'message': '',
              'chatChannelId': 'c',
              'createdAt': DateTime.utc(2026, 8, 7, 14, 27, 42, 594),
            },
          ],
          'ChatMessageMetadata': [wavedMetadata('m1', actor: 'them')],
        },
      });

      expect(items.single.at, DateTime.utc(2026, 8, 7, 14, 27, 42, 594));
    });
  });

  group('ActivityFeed.fetch', () {
    test('decodes the msgpack body and counts what is unread', () async {
      final http = FakeGatherHttp()
        ..bytes = {
          'activity-feed': feedBytes(
            subscriptionIds: ['s1'],
            models: {
              'ActivityEventSubscription': [
                {'id': 's1', 'activityEventId': 'e1', 'readAt': null},
              ],
              'ActivityEvent': [
                {
                  'id': 'e1',
                  'createdAt': '2026-07-20T10:08:59.101Z',
                  'metadata': {'type': activityOnboardingChat},
                },
              ],
            },
          ),
        };

      final page = await feedWith(http).fetch('space-1');

      expect(page.items, hasLength(1));
      expect(page.unreadCount, 1);
    });

    test('throws with the status when Gather refuses', () async {
      final http = FakeGatherHttp()..byteStatus = 403;

      await expectLater(
        feedWith(http).fetch('space-1'),
        throwsA(isA<ActivityFeedException>().having((e) => e.status, 'status', 403)),
      );
    });
  });

  group('ActivityFeed.markRead', () {
    OnboardingActivity nudge({
      String subscriptionId = 's1',
      String eventId = 'e1',
      bool isRead = false,
    }) =>
        OnboardingActivity(
          id: 'activity:$subscriptionId',
          at: null,
          isRead: isRead,
          subscriptionId: subscriptionId,
          activityEventId: eventId,
          kind: activityOnboardingChat,
        );

    test('names the event, not the subscription, and sends JSON', () async {
      // Captured off the desktop client: `{"activityEventId": "<id>"}`. The
      // subscription is what carries `readAt`, which makes its id the tempting
      // one to send — and the wrong one.
      final http = FakeGatherHttp();

      await feedWith(http).markRead('space-1', [nudge()]);

      expect(http.posts, hasLength(1));
      expect(http.posts.single.uri.path, endsWith('/chat/activity-feed/toggle-read-status'));
      expect(http.posts.single.body, {'activityEventId': 'e1'});
    });

    test('sends one request per event, because no batch form exists', () async {
      final http = FakeGatherHttp();

      await feedWith(http).markRead('space-1', [
        nudge(subscriptionId: 's1', eventId: 'e1'),
        nudge(subscriptionId: 's2', eventId: 'e2'),
      ]);

      expect(http.posts, hasLength(2));
      expect(
        http.posts.map((p) => (p.body! as Map)['activityEventId']),
        containsAll(['e1', 'e2']),
      );
    });

    test('skips items that are already read, because the endpoint toggles', () async {
      // The one that would actually hurt: `/toggle-read-status` has no
      // `read: true`, so re-sending a read item marks it unread again. "Mark all
      // read" on a mostly-read list would flip most of it back.
      final http = FakeGatherHttp();

      await feedWith(http).markRead('space-1', [
        nudge(subscriptionId: 's1', eventId: 'e1', isRead: true),
        nudge(subscriptionId: 's2', eventId: 'e2'),
      ]);

      expect(http.posts, hasLength(1));
      expect(http.posts.single.body, {'activityEventId': 'e2'});
    });

    test('does not call Gather for kinds whose read state lives elsewhere', () async {
      // A wave's read state is a ChatReadCursor on its channel, not a
      // subscription — so there is nothing here to send.
      final http = FakeGatherHttp();

      await feedWith(http).markRead('space-1', [
        const WaveActivity(id: 'wave:1', at: null, actorSpaceUserId: 'them'),
      ]);

      expect(http.posts, isEmpty);
    });

    test('reports the status when Gather refuses', () async {
      final http = FakeGatherHttp()..byteStatus = 500;

      await expectLater(
        feedWith(http).markRead('space-1', [nudge()]),
        throwsA(isA<ActivityFeedException>().having((e) => e.status, 'status', 500)),
      );
    });
  });
}
