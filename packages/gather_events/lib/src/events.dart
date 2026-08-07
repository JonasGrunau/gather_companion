/// Wire format for everything the bridge observes in a live Gather V2 client.
///
/// Events are transported as JSON objects with a `type` discriminator so the
/// Flutter side can decode them into a sealed hierarchy and switch
/// exhaustively over them.
library;

/// Where an event was observed. Different collectors have different fidelity,
/// so the app can tell the user *how* it knows something.
enum EventSource {
  /// Read from Gather's own game socket, which the bridge connects to as the
  /// user. Names, coordinates, clusters, follow state, voice activity.
  gather,

  /// Parsed out of the desktop client's log file. Now only Gather's own
  /// notifications — waves, meeting invites, event reminders — which exist in no
  /// Gather model and can be read nowhere else.
  log,

  /// Was: read out of the live renderer over the Chrome DevTools Protocol. That
  /// collector is gone, replaced by [gather]. Kept so events recorded by an older
  /// bridge still decode.
  cdp,

  /// Emitted by the bridge itself (status, derived/inferred events).
  bridge;

  static EventSource parse(String? raw) => EventSource.values.firstWhere(
        (s) => s.name == raw,
        orElse: () => EventSource.bridge,
      );
}

/// How confident the bridge is that a derived event is real.
enum Confidence {
  /// Read directly from authoritative state or an explicit protocol signal.
  observed,

  /// Derived from a proxy signal (e.g. audio range standing in for adjacency).
  inferred;

  static Confidence parse(String? raw) => Confidence.values.firstWhere(
        (c) => c.name == raw,
        orElse: () => Confidence.observed,
      );
}

/// Base class for every observed event.
sealed class GatherEvent {
  GatherEvent({
    required this.at,
    required this.source,
    this.confidence = Confidence.observed,
  });

  /// When the event happened (as reported by the client, not when we parsed it).
  final DateTime at;
  final EventSource source;
  final Confidence confidence;

  /// Stable discriminator used on the wire.
  String get type;

  /// A short line suitable for an event feed. Names are resolved by the app
  /// where possible, so this falls back to ids.
  String get summary;

  /// The other player this event is about, if any.
  String? get playerId => null;

  Map<String, Object?> payload();

  Map<String, Object?> toJson() => {
        'type': type,
        'at': at.toIso8601String(),
        'source': source.name,
        'confidence': confidence.name,
        ...payload(),
      };

  static GatherEvent fromJson(Map<String, Object?> json) {
    final at = DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now();
    final source = EventSource.parse(json['source'] as String?);
    final confidence = Confidence.parse(json['confidence'] as String?);
    final type = json['type'] as String? ?? '';

    String pid() => json['playerId'] as String? ?? '';

    return switch (type) {
      'space.changed' => SpaceChangedEvent(
          at: at,
          source: source,
          spaceId: json['spaceId'] as String?,
          spaceName: json['spaceName'] as String?,
        ),
      'self.changed' => SelfChangedEvent(
          at: at,
          source: source,
          userId: json['userId'] as String?,
          audioEnabled: json['audioEnabled'] as bool?,
          videoEnabled: json['videoEnabled'] as bool?,
          inOffice: json['inOffice'] as bool?,
          screensharing: json['screensharing'] as bool?,
        ),
      'player.joinedSpace' => PlayerSpaceEvent(
          at: at,
          source: source,
          playerId: pid(),
          joined: true,
        ),
      'player.leftSpace' => PlayerSpaceEvent(
          at: at,
          source: source,
          playerId: pid(),
          joined: false,
        ),
      'proximity.entered' => ProximityEvent(
          at: at,
          source: source,
          confidence: confidence,
          playerId: pid(),
          near: true,
          distance: (json['distance'] as num?)?.toDouble(),
        ),
      'proximity.left' => ProximityEvent(
          at: at,
          source: source,
          confidence: confidence,
          playerId: pid(),
          near: false,
          distance: (json['distance'] as num?)?.toDouble(),
        ),
      'audio.range' => AudioRangeEvent(
          at: at,
          source: source,
          playerId: pid(),
          inRange: json['inRange'] as bool? ?? false,
          volume: (json['volume'] as num?)?.toDouble(),
        ),
      'media.changed' => MediaChangedEvent(
          at: at,
          source: source,
          playerId: pid(),
          track: MediaTrack.parse(json['track'] as String?),
          paused: json['paused'] as bool? ?? false,
        ),
      'media.connection' => MediaConnectionEvent(
          at: at,
          source: source,
          playerId: pid(),
          state: json['state'] as String? ?? 'unknown',
        ),
      'follow.started' => FollowEvent(
          at: at,
          source: source,
          confidence: confidence,
          followerId: json['followerId'] as String? ?? '',
          targetId: json['targetId'] as String? ?? '',
          started: true,
          targetIsSelf: json['targetIsSelf'] as bool? ?? false,
        ),
      'follow.stopped' => FollowEvent(
          at: at,
          source: source,
          confidence: confidence,
          followerId: json['followerId'] as String? ?? '',
          targetId: json['targetId'] as String? ?? '',
          started: false,
          targetIsSelf: json['targetIsSelf'] as bool? ?? false,
        ),
      'player.moved' => PlayerMovedEvent(
          at: at,
          source: source,
          playerId: pid(),
          x: (json['x'] as num?)?.toDouble() ?? 0,
          y: (json['y'] as num?)?.toDouble() ?? 0,
          distance: (json['distance'] as num?)?.toDouble(),
        ),
      'chat.message' => ChatMessageEvent(
          at: at,
          source: source,
          playerId: pid(),
          text: json['text'] as String? ?? '',
          channel: json['channel'] as String?,
        ),
      'notification.shown' => NotificationShownEvent(
          at: at,
          source: source,
          notificationType: json['notificationType'] as String? ?? 'unknown',
          title: json['title'] as String?,
          body: json['body'] as String?,
        ),
      'bridge.status' => BridgeStatusEvent(
          at: at,
          source: source,
          collector: json['collector'] as String? ?? 'bridge',
          healthy: json['healthy'] as bool? ?? false,
          detail: json['detail'] as String?,
        ),
      _ => RawEvent(
          at: at,
          source: source,
          rawType: type.isEmpty ? 'unknown' : type,
          text: json['text'] as String? ?? '',
        ),
    };
  }
}

/// The client moved to a different space (or reported which space it is in).
class SpaceChangedEvent extends GatherEvent {
  SpaceChangedEvent({
    required super.at,
    required super.source,
    this.spaceId,
    this.spaceName,
  });

  final String? spaceId;
  final String? spaceName;

  @override
  String get type => 'space.changed';

  @override
  String get summary => 'Space: ${spaceName ?? spaceId ?? 'unknown'}';

  @override
  Map<String, Object?> payload() => {
        'spaceId': spaceId,
        'spaceName': spaceName,
      };
}

/// Something about *my own* client state changed.
class SelfChangedEvent extends GatherEvent {
  SelfChangedEvent({
    required super.at,
    required super.source,
    this.userId,
    this.audioEnabled,
    this.videoEnabled,
    this.inOffice,
    this.screensharing,
  });

  final String? userId;
  final bool? audioEnabled;
  final bool? videoEnabled;
  final bool? inOffice;
  final bool? screensharing;

  @override
  String get type => 'self.changed';

  @override
  String get summary {
    final bits = <String>[
      if (audioEnabled != null) 'mic ${audioEnabled! ? 'on' : 'off'}',
      if (videoEnabled != null) 'cam ${videoEnabled! ? 'on' : 'off'}',
      if (screensharing != null && screensharing!) 'screensharing',
      if (inOffice != null) inOffice! ? 'in office' : 'left office',
    ];
    return bits.isEmpty ? 'Own state changed' : 'You: ${bits.join(', ')}';
  }

  @override
  Map<String, Object?> payload() => {
        'userId': userId,
        'audioEnabled': audioEnabled,
        'videoEnabled': videoEnabled,
        'inOffice': inOffice,
        'screensharing': screensharing,
      };
}

/// A player joined or left the space entirely.
class PlayerSpaceEvent extends GatherEvent {
  PlayerSpaceEvent({
    required super.at,
    required super.source,
    required this.playerId,
    required this.joined,
  });

  @override
  final String playerId;
  final bool joined;

  @override
  String get type => joined ? 'player.joinedSpace' : 'player.leftSpace';

  @override
  String get summary =>
      joined ? 'Joined the space' : 'Left the space';

  @override
  Map<String, Object?> payload() => {'playerId': playerId};
}

/// Someone came into — or dropped out of — my immediate surroundings.
///
/// This is the "standing next to me" signal. From the log collector it is
/// [Confidence.inferred] (derived from Gather's own proximity-gated media
/// connections); from the CDP collector it is [Confidence.observed] and
/// carries a real tile [distance].
class ProximityEvent extends GatherEvent {
  ProximityEvent({
    required super.at,
    required super.source,
    required this.playerId,
    required this.near,
    super.confidence,
    this.distance,
  });

  @override
  final String playerId;

  /// True when entering proximity, false when leaving.
  final bool near;

  /// Distance in tiles, when known.
  final double? distance;

  @override
  String get type => near ? 'proximity.entered' : 'proximity.left';

  @override
  String get summary {
    final d = distance == null ? '' : ' (${distance!.toStringAsFixed(1)} tiles)';
    return near ? 'Is next to you$d' : 'Moved away$d';
  }

  @override
  Map<String, Object?> payload() => {
        'playerId': playerId,
        'distance': distance,
      };
}

/// A remote player's audio came in or out of range.
class AudioRangeEvent extends GatherEvent {
  AudioRangeEvent({
    required super.at,
    required super.source,
    required this.playerId,
    required this.inRange,
    this.volume,
  });

  @override
  final String playerId;
  final bool inRange;
  final double? volume;

  @override
  String get type => 'audio.range';

  @override
  String get summary =>
      inRange ? 'Came into audio range' : 'Left audio range';

  @override
  Map<String, Object?> payload() => {
        'playerId': playerId,
        'inRange': inRange,
        'volume': volume,
      };
}

enum MediaTrack {
  audio,
  video,
  screen;

  static MediaTrack parse(String? raw) => MediaTrack.values.firstWhere(
        (t) => t.name == raw,
        orElse: () => MediaTrack.audio,
      );
}

/// A nearby player muted/unmuted, turned their camera on/off, or started or
/// stopped sharing their screen.
class MediaChangedEvent extends GatherEvent {
  MediaChangedEvent({
    required super.at,
    required super.source,
    required this.playerId,
    required this.track,
    required this.paused,
  });

  @override
  final String playerId;
  final MediaTrack track;

  /// True when the track went away (muted / camera off / share stopped).
  final bool paused;

  @override
  String get type => 'media.changed';

  @override
  String get summary => switch (track) {
        MediaTrack.audio => paused ? 'Muted' : 'Unmuted',
        MediaTrack.video => paused ? 'Camera off' : 'Camera on',
        MediaTrack.screen =>
          paused ? 'Stopped sharing screen' : 'Started sharing screen',
      };

  @override
  Map<String, Object?> payload() => {
        'playerId': playerId,
        'track': track.name,
        'paused': paused,
      };
}

/// Low-level media transport state for a nearby player.
class MediaConnectionEvent extends GatherEvent {
  MediaConnectionEvent({
    required super.at,
    required super.source,
    required this.playerId,
    required this.state,
  });

  @override
  final String playerId;
  final String state;

  @override
  String get type => 'media.connection';

  @override
  String get summary => 'Media $state';

  @override
  Map<String, Object?> payload() => {
        'playerId': playerId,
        'state': state,
      };
}

/// Somebody started or stopped following somebody.
///
/// [targetIsSelf] is the one the app cares about most: it means *you* are being
/// followed.
class FollowEvent extends GatherEvent {
  FollowEvent({
    required super.at,
    required super.source,
    required this.followerId,
    required this.targetId,
    required this.started,
    required this.targetIsSelf,
    super.confidence,
  });

  final String followerId;
  final String targetId;
  final bool started;
  final bool targetIsSelf;

  @override
  String get type => started ? 'follow.started' : 'follow.stopped';

  /// The interesting counterpart: the follower when we are the target,
  /// otherwise whoever is being followed.
  @override
  String get playerId => targetIsSelf ? followerId : targetId;

  @override
  String get summary {
    if (targetIsSelf) {
      return started ? 'Started following you' : 'Stopped following you';
    }
    return started ? 'You started following them' : 'You stopped following';
  }

  @override
  Map<String, Object?> payload() => {
        'followerId': followerId,
        'targetId': targetId,
        'targetIsSelf': targetIsSelf,
      };
}

/// A player moved. Only available from the CDP collector.
class PlayerMovedEvent extends GatherEvent {
  PlayerMovedEvent({
    required super.at,
    required super.source,
    required this.playerId,
    required this.x,
    required this.y,
    this.distance,
  });

  @override
  final String playerId;
  final double x;
  final double y;

  /// Distance to me in tiles at the time of the move.
  final double? distance;

  @override
  String get type => 'player.moved';

  @override
  String get summary =>
      'Moved to (${x.toStringAsFixed(0)}, ${y.toStringAsFixed(0)})';

  @override
  Map<String, Object?> payload() => {
        'playerId': playerId,
        'x': x,
        'y': y,
        'distance': distance,
      };
}

/// A chat message. Only available from the CDP collector.
class ChatMessageEvent extends GatherEvent {
  ChatMessageEvent({
    required super.at,
    required super.source,
    required this.playerId,
    required this.text,
    this.channel,
  });

  @override
  final String playerId;
  final String text;
  final String? channel;

  @override
  String get type => 'chat.message';

  @override
  String get summary => text;

  @override
  Map<String, Object?> payload() => {
        'playerId': playerId,
        'text': text,
        'channel': channel,
      };
}

/// The desktop client raised a native notification. The type is always
/// available; title and body only when read over CDP.
class NotificationShownEvent extends GatherEvent {
  NotificationShownEvent({
    required super.at,
    required super.source,
    required this.notificationType,
    this.title,
    this.body,
  });

  final String notificationType;
  final String? title;
  final String? body;

  @override
  String get type => 'notification.shown';

  @override
  String get summary => title == null
      ? 'Notification: $notificationType'
      : '$title${body == null ? '' : ' — $body'}';

  @override
  Map<String, Object?> payload() => {
        'notificationType': notificationType,
        'title': title,
        'body': body,
      };
}

/// Health of one of the bridge's collectors.
class BridgeStatusEvent extends GatherEvent {
  BridgeStatusEvent({
    required super.at,
    required super.source,
    required this.collector,
    required this.healthy,
    this.detail,
  });

  final String collector;
  final bool healthy;
  final String? detail;

  @override
  String get type => 'bridge.status';

  @override
  String get summary =>
      '$collector ${healthy ? 'connected' : 'disconnected'}'
      '${detail == null ? '' : ' — $detail'}';

  @override
  Map<String, Object?> payload() => {
        'collector': collector,
        'healthy': healthy,
        'detail': detail,
      };
}

/// Anything recognised as interesting but not modelled yet. Keeps the pipeline
/// lossless while the protocol is still being mapped.
class RawEvent extends GatherEvent {
  RawEvent({
    required super.at,
    required super.source,
    required this.rawType,
    required this.text,
  });

  final String rawType;
  final String text;

  @override
  String get type => rawType;

  @override
  String get summary => text;

  @override
  Map<String, Object?> payload() => {'text': text};
}
