/// Gather's activity feed — the one durable history it keeps for you.
///
/// The app used to have a scrolling log of its own and deleted it, for a good
/// reason: the phone only sees what happens while it is awake, so a locally-built
/// history is empty exactly when you want it. This one is different. It is
/// recorded server-side, it survives a reinstall, and it is what the desktop
/// client shows behind its `gather-chat-activity-feed-nav` link.
///
/// ## The wire format, measured 2026-08-13
///
/// `GET /spaces/:spaceId/chat/activity-feed` answers **msgpack**
/// (`application/x.gather.msgpack`), not JSON — so [msgpackDecode] reads it, the
/// same decoder the game socket uses. The body is normalised the same way a state
/// dump is: index lists of ids, plus one store of rows to look them up in.
///
/// ```jsonc
/// { "activityFeed": {
///     "chatMessageIdsForActivityFeedWaveItems":     [ "<ChatMessage id>", … ],
///     "chatMentionIdsForActivityFeedMentionItems":  [ … ],
///     "chatMessageIdsForActivityFeedReactionItems": [ … ],
///     "threadParentIdsForActivityFeedReplyItems":   [ … ],
///     "activityEventSubscriptionIds":               [ "<subscription id>", … ] },
///   "serializedModels": {
///     "ChatMessage": […], "ChatMessageMetadata": […], "ChatChannel": […],
///     "ActivityEvent": […], "ActivityEventSubscription": […] } }
/// ```
///
/// Two properties of that shape drive the code below:
///
/// - **A bucket brings its models only when it is non-empty.** The measured space
///   had 100 waves and zero mentions, and the response carried no mention model at
///   all. Every lookup therefore has to tolerate a missing model key rather than
///   assume the store is complete.
/// - **Read state lives on `ActivityEventSubscription.readAt`,** not on the event.
///   `null` means unread. That row's id — not the event's — is what
///   `/toggle-read-status` takes, so it is carried through to [ActivityItem].
///
/// ## What is measured and what is inferred
///
/// Waves and activity events were seen in full and are decoded from observation.
/// Mentions, reactions and thread replies were **empty** in every space available
/// to measure, so their joins are written from the shape of their id lists and
/// must be treated as unverified: each degrades to [UnknownActivity] rather than
/// throwing when the model it expects is absent. If you are the first person to
/// see one arrive, check it against this file and delete this paragraph.
///
/// ## No pagination
///
/// `?limit`, `?cursor`, `?before`, `?page` and `?offset` were each tried and all
/// return a byte-identical body. The feed is a fixed snapshot — the last 100 waves
/// and the live activity events — so there is no page to ask for.
library;

import 'gather_auth.dart';
import 'msgpack.dart';

/// How Gather discriminates an `ActivityEvent.metadata`. Observed values only.
const activityMeetingArtifactReady = 'MeetingArtifactReady';
const activityOnboardingChat = 'OnboardingChat';
const activityOnboardingDesk = 'OnboardingDesk';

/// How Gather discriminates a `ChatMessageMetadata.metadata`.
const chatMetadataWaved = 'Waved';

/// One row in the activity list.
///
/// [id] is stable and unique across kinds, so the UI can key on it and the live
/// socket tail can dedupe against a later refresh.
sealed class ActivityItem {
  const ActivityItem({
    required this.id,
    required this.at,
    required this.isRead,
    this.subscriptionId,
    this.activityEventId,
    this.actorSpaceUserId,
  });

  final String id;

  /// When it happened. Null only if Gather sent a timestamp we could not read;
  /// such items sort last rather than being dropped.
  final DateTime? at;

  final bool isRead;

  /// The `ActivityEventSubscription` row this item's read state lives on. Null for
  /// the chat-backed kinds, whose read state is a `ChatReadCursor` instead — see
  /// [ActivityFeed.markRead].
  ///
  /// Carried for identity and debugging; the *request* is keyed on
  /// [activityEventId], not on this.
  final String? subscriptionId;

  /// The `ActivityEvent` this item came from — what `/toggle-read-status` takes.
  ///
  /// Measured 2026-08-13: the endpoint's body is `{"activityEventId": "<id>"}`.
  /// The subscription is what *carries* `readAt`, but it is not what the request
  /// names, which is an easy and silent thing to get backwards.
  final String? activityEventId;

  /// Who did it, as a `SpaceUser` id. Resolve to a name against the roster the app
  /// already holds; this package deliberately does not fetch users.
  final String? actorSpaceUserId;

  /// Whether marking this read is something we know how to do.
  bool get canMarkRead => activityEventId != null;

  /// The same item, read.
  ///
  /// Returns `this` for the chat-backed kinds, which have no subscription row to
  /// flip and are reported read already — so an optimistic update can call this on
  /// a whole selection without filtering it first.
  ActivityItem markedRead() => this;
}

/// Somebody waved at you.
class WaveActivity extends ActivityItem {
  const WaveActivity({
    required super.id,
    required super.at,
    required super.actorSpaceUserId,
    this.channelId,
  }) : super(isRead: true);

  /// The `DirectMessage` channel the wave was recorded in.
  final String? channelId;
}

/// Somebody @-mentioned you. Unverified — see the library doc.
class MentionActivity extends ActivityItem {
  const MentionActivity({
    required super.id,
    required super.at,
    required super.actorSpaceUserId,
    this.message,
    this.channelId,
  }) : super(isRead: true);

  final String? message;
  final String? channelId;
}

/// Somebody reacted to a message of yours. Unverified — see the library doc.
class ReactionActivity extends ActivityItem {
  const ReactionActivity({
    required super.id,
    required super.at,
    required super.actorSpaceUserId,
    this.message,
    this.channelId,
  }) : super(isRead: true);

  final String? message;
  final String? channelId;
}

/// Somebody replied in a thread you started. Unverified — see the library doc.
class ReplyActivity extends ActivityItem {
  const ReplyActivity({
    required super.id,
    required super.at,
    required super.actorSpaceUserId,
    this.message,
    this.channelId,
  }) : super(isRead: true);

  final String? message;
  final String? channelId;
}

/// A meeting you were in has a memo or a recording ready.
class MeetingArtifactActivity extends ActivityItem {
  const MeetingArtifactActivity({
    required super.id,
    required super.at,
    required super.isRead,
    required super.subscriptionId,
    required super.activityEventId,
    this.meetingId,
    this.meetingTitle,
    this.hasMeetingMemo = false,
    this.hasVideoRecording = false,
    this.participantCount,
  });

  final String? meetingId;
  final String? meetingTitle;
  final bool hasMeetingMemo;
  final bool hasVideoRecording;
  final int? participantCount;

  @override
  ActivityItem markedRead() => MeetingArtifactActivity(
        id: id,
        at: at,
        isRead: true,
        subscriptionId: subscriptionId,
        activityEventId: activityEventId,
        meetingId: meetingId,
        meetingTitle: meetingTitle,
        hasMeetingMemo: hasMeetingMemo,
        hasVideoRecording: hasVideoRecording,
        participantCount: participantCount,
      );
}

/// One of Gather's own onboarding nudges. `isGlobal` on the underlying event —
/// everybody in the space gets these, and they are years old by now.
class OnboardingActivity extends ActivityItem {
  const OnboardingActivity({
    required super.id,
    required super.at,
    required super.isRead,
    required super.subscriptionId,
    required super.activityEventId,
    required this.kind,
  });

  /// [activityOnboardingChat] or [activityOnboardingDesk].
  final String kind;

  @override
  ActivityItem markedRead() => OnboardingActivity(
        id: id,
        at: at,
        isRead: true,
        subscriptionId: subscriptionId,
        activityEventId: activityEventId,
        kind: kind,
      );
}

/// Something we have no decoder for, kept rather than dropped.
///
/// This payload is undocumented and Gather will add kinds to it. An unrecognised
/// item must reach the screen as "something happened" rather than vanish or throw
/// — the same bargain `RawEvent` makes in `package:gather_events`.
class UnknownActivity extends ActivityItem {
  const UnknownActivity({
    required super.id,
    required super.at,
    required super.isRead,
    super.subscriptionId,
    super.activityEventId,
    super.actorSpaceUserId,
    required this.kind,
    required this.payload,
  });

  /// Whatever discriminator we found, or `'Unknown'`.
  final String kind;

  /// The row as it arrived, so a future decoder can be written from a bug report.
  final Map<String, Object?> payload;

  @override
  ActivityItem markedRead() => UnknownActivity(
        id: id,
        at: at,
        isRead: true,
        subscriptionId: subscriptionId,
        activityEventId: activityEventId,
        actorSpaceUserId: actorSpaceUserId,
        kind: kind,
        payload: payload,
      );
}

/// The feed as one list, newest first.
class ActivityFeedPage {
  const ActivityFeedPage({required this.items, required this.fetchedAt});

  final List<ActivityItem> items;
  final DateTime fetchedAt;

  int get unreadCount => items.where((item) => !item.isRead).length;

  static final empty = ActivityFeedPage(
    items: const [],
    fetchedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );
}

class ActivityFeedException implements Exception {
  const ActivityFeedException(this.message, {this.status});

  final String message;
  final int? status;

  @override
  String toString() => 'ActivityFeedException($message${status == null ? '' : ', status: $status'})';
}

/// Reads (and, where Gather lets us, writes) the activity feed.
class ActivityFeed {
  // Assigned the long way round because a named parameter cannot be a private
  // initializing formal.
  ActivityFeed({
    required GatherAuth auth,
    GatherHttp http = const IoGatherHttp(),
    String apiBase = gatherApiBase,
  })  :
        // ignore: prefer_initializing_formals
        _auth = auth,
        // ignore: prefer_initializing_formals
        _http = http,
        // ignore: prefer_initializing_formals
        _apiBase = apiBase;

  final GatherAuth _auth;
  final GatherHttp _http;
  final String _apiBase;

  Future<ActivityFeedPage> fetch(String spaceId) async {
    final token = await _auth.idToken();
    final uri = Uri.parse('$_apiBase/spaces/$spaceId/chat/activity-feed');
    final response = await _http.getBytes(uri, token);
    if (response.status != 200) {
      throw ActivityFeedException('activity feed refused', status: response.status);
    }

    final decoded = msgpackDecode(response.body);
    if (decoded is! Map<String, Object?>) {
      throw const ActivityFeedException('activity feed was not a msgpack map');
    }
    return ActivityFeedPage(
      items: parseActivityFeed(decoded),
      fetchedAt: DateTime.now().toUtc(),
    );
  }

  /// Flips the read status of activity events.
  ///
  /// Captured off the desktop client 2026-08-13, because every part of this was
  /// worth getting from observation rather than from a guess:
  ///
  /// ```http
  /// POST /spaces/:spaceId/chat/activity-feed/toggle-read-status
  /// Content-Type: application/json
  ///
  /// {"activityEventId": "<ActivityEvent id>"}
  /// ```
  ///
  /// → `200`, and a **msgpack** body holding the updated row:
  /// `{"ActivityEventSubscription": [{… "readAt": "2026-08-13T17:52:15.417Z"}]}`.
  ///
  /// Four things that are not what you would assume:
  ///
  /// - **The body is JSON**, while the response is msgpack. Not symmetric.
  /// - **It names the event, not the subscription.** `readAt` lives on the
  ///   subscription, so the subscription id is the one that looks like the handle.
  ///   It is not.
  /// - **One event per request.** The desktop client sends a separate call per
  ///   item and no batch form was observed, so this loops rather than inventing a
  ///   plural field. Sequentially, because a burst of writes on somebody's real
  ///   account is not the place to save a few milliseconds.
  /// - **It is a *toggle*, and the name means it.** There is no "read: true" — the
  ///   server flips whatever it finds and stamps its own timestamp. Sending an
  ///   already-read id therefore marks it *unread*, which is why filtering on
  ///   [ActivityItem.isRead] below is correctness rather than an optimisation.
  ///
  /// Read state for a wave, mention, reaction or reply is not here at all: it is a
  /// `ChatReadCursor`, posted per channel to
  /// `/chat/channels/:channelId/read-cursors`. Those items report as read already
  /// and are filtered out by [ActivityItem.canMarkRead].
  Future<void> markRead(String spaceId, Iterable<ActivityItem> items) async {
    final ids = <String>{
      for (final item in items)
        if (!item.isRead) ?item.activityEventId,
    };
    if (ids.isEmpty) return;

    final uri = Uri.parse('$_apiBase/spaces/$spaceId/chat/activity-feed/toggle-read-status');
    for (final id in ids) {
      final token = await _auth.idToken();
      final response = await _http.postJson(uri, token, {'activityEventId': id});
      if (response.status != 200 && response.status != 204) {
        throw ActivityFeedException(
          'toggle-read-status refused for $id',
          status: response.status,
        );
      }
    }
  }
}

/// Resolves a decoded activity-feed body into a sorted list.
///
/// Separate from [ActivityFeed] so a fixture can drive it without a fake HTTP
/// layer, and so a probe script can reuse it.
List<ActivityItem> parseActivityFeed(Map<String, Object?> body) {
  final feed = _map(body['activityFeed']) ?? const {};
  final models = _map(body['serializedModels']) ?? const {};

  final messages = _index(models['ChatMessage']);
  final events = _index(models['ActivityEvent']);
  final subscriptions = _index(models['ActivityEventSubscription']);
  final mentions = _index(models['ChatMention']);
  final reactions = _index(models['ChatMessageReaction']);

  // ChatMessageMetadata is keyed by its own id, but every lookup wants it by the
  // message it annotates.
  final metadataByMessage = <String, Map<String, Object?>>{};
  for (final row in _rows(models['ChatMessageMetadata'])) {
    final messageId = _string(row['chatMessageId']);
    if (messageId != null) metadataByMessage[messageId] = row;
  }

  final items = <ActivityItem>[];

  for (final id in _ids(feed['chatMessageIdsForActivityFeedWaveItems'])) {
    final message = messages[id];
    if (message == null) continue;
    final metadata = _map(metadataByMessage[id]?['metadata']) ?? const {};
    items.add(WaveActivity(
      id: 'wave:$id',
      at: _time(message['createdAt']),
      // The wave's sender is on the metadata, not on the message: the message row
      // carries the channel's author, which for a System row is not the waver.
      actorSpaceUserId:
          _string(metadata['actorSpaceUserId']) ?? _string(message['spaceUserId']),
      channelId: _string(message['chatChannelId']),
    ));
  }

  for (final id in _ids(feed['chatMentionIdsForActivityFeedMentionItems'])) {
    final mention = mentions[id];
    final message = mention == null
        ? messages[id]
        : messages[_string(mention['chatMessageId']) ?? ''];
    if (message == null) {
      items.add(_unresolved('mention', id, mention));
      continue;
    }
    items.add(MentionActivity(
      id: 'mention:$id',
      at: _time(message['createdAt']),
      actorSpaceUserId: _string(message['spaceUserId']),
      message: _text(message['message']),
      channelId: _string(message['chatChannelId']),
    ));
  }

  for (final id in _ids(feed['chatMessageIdsForActivityFeedReactionItems'])) {
    final message = messages[id];
    if (message == null) {
      items.add(_unresolved('reaction', id, reactions[id]));
      continue;
    }
    items.add(ReactionActivity(
      id: 'reaction:$id',
      at: _time(message['createdAt']),
      actorSpaceUserId: _string(reactions[id]?['spaceUserId']),
      message: _text(message['message']),
      channelId: _string(message['chatChannelId']),
    ));
  }

  for (final id in _ids(feed['threadParentIdsForActivityFeedReplyItems'])) {
    final message = messages[id];
    if (message == null) {
      items.add(_unresolved('reply', id, null));
      continue;
    }
    items.add(ReplyActivity(
      id: 'reply:$id',
      at: _time(message['createdAt']),
      actorSpaceUserId: _string(message['spaceUserId']),
      message: _text(message['computedThreadPreview']) ?? _text(message['message']),
      channelId: _string(message['chatChannelId']),
    ));
  }

  for (final subscriptionId in _ids(feed['activityEventSubscriptionIds'])) {
    final subscription = subscriptions[subscriptionId];
    if (subscription == null) continue;
    final eventId = _string(subscription['activityEventId']);
    final event = events[eventId ?? ''];
    // Asked by *reading the timestamp*, not by testing against null. This body is
    // msgpack, and an unset optional column on this protocol arrives as ext-4
    // **undefined** rather than nil — every `undefined` in the observed state dump
    // (`clusterId`, `handRaisedAt`, `Connection.lastActiveAt`) is that same
    // encoding. `msgpackDecode` maps it to the `msgpackUndefined` sentinel, which
    // is not null, so `readAt != null` would call every unread item read: a badge
    // stuck at zero, and `markRead` with nothing left to send. The same trap
    // `_MeetingWatch` documents one file over.
    final isRead = _time(subscription['readAt']) != null;
    // The subscription is per-person and the event is shared, so the subscription
    // is what carries "when did this reach me" as well as whether it was read.
    final at = _time(event?['createdAt']) ?? _time(subscription['createdAt']);
    if (event == null) {
      items.add(UnknownActivity(
        id: 'activity:$subscriptionId',
        at: at,
        isRead: isRead,
        subscriptionId: subscriptionId,
        activityEventId: eventId,
        kind: 'Unknown',
        payload: subscription,
      ));
      continue;
    }

    final metadata = _map(event['metadata']) ?? const {};
    final kind = _string(metadata['type']) ?? 'Unknown';
    switch (kind) {
      case activityMeetingArtifactReady:
        items.add(MeetingArtifactActivity(
          id: 'activity:$subscriptionId',
          at: at,
          isRead: isRead,
          subscriptionId: subscriptionId,
          activityEventId: eventId,
          meetingId: _string(metadata['meetingId']),
          meetingTitle: _text(metadata['meetingTitle']),
          hasMeetingMemo: metadata['hasMeetingMemo'] == true,
          hasVideoRecording: metadata['hasVideoRecording'] == true,
          participantCount: _int(metadata['meetingParticipantCount']),
        ));
      case activityOnboardingChat:
      case activityOnboardingDesk:
        items.add(OnboardingActivity(
          id: 'activity:$subscriptionId',
          at: at,
          isRead: isRead,
          subscriptionId: subscriptionId,
          activityEventId: eventId,
          kind: kind,
        ));
      default:
        items.add(UnknownActivity(
          id: 'activity:$subscriptionId',
          at: at,
          isRead: isRead,
          subscriptionId: subscriptionId,
          activityEventId: eventId,
          kind: kind,
          payload: event,
        ));
    }
  }

  // Newest first; anything we could not time sorts last rather than jumping to
  // the top, which is what a null-as-zero comparison would do.
  items.sort((a, b) {
    final left = a.at;
    final right = b.at;
    if (left == null && right == null) return 0;
    if (left == null) return 1;
    if (right == null) return -1;
    return right.compareTo(left);
  });
  return List.unmodifiable(items);
}

UnknownActivity _unresolved(String kind, String id, Map<String, Object?>? row) =>
    UnknownActivity(
      id: '$kind:$id',
      at: _time(row?['createdAt']),
      isRead: true,
      kind: kind,
      payload: row ?? {'id': id},
    );

Map<String, Object?>? _map(Object? value) =>
    value is Map<String, Object?> ? value : (value is Map ? value.cast<String, Object?>() : null);

Iterable<Map<String, Object?>> _rows(Object? value) sync* {
  if (value is! List) return;
  for (final row in value) {
    final map = _map(row);
    if (map != null) yield map;
  }
}

Map<String, Map<String, Object?>> _index(Object? value) {
  final out = <String, Map<String, Object?>>{};
  for (final row in _rows(value)) {
    final id = _string(row['id']);
    if (id != null) out[id] = row;
  }
  return out;
}

List<String> _ids(Object? value) =>
    value is List ? value.whereType<String>().toList(growable: false) : const [];

String? _string(Object? value) => value is String && value.isNotEmpty ? value : null;

/// Free text, where empty means absent — a wave is a `ChatMessage` with `''` in
/// its body, and rendering that as a blank quote would be worse than nothing.
String? _text(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int? _int(Object? value) => value is int ? value : (value is num ? value.toInt() : null);

/// `createdAt` arrives as a msgpack ext-1 DateTime, but sibling fields on this
/// protocol are plain ISO strings, so both are accepted.
DateTime? _time(Object? value) {
  if (value is DateTime) return value.toUtc();
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  if (value is String) return DateTime.tryParse(value)?.toUtc();
  return null;
}
