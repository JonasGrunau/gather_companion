/// Current-state models: what the bridge believes the world looks like right
/// now. Sent as a snapshot when a client connects, so the app does not have to
/// replay history to render a first frame.
library;

/// One other person in the space, as far as the bridge can tell.
class PlayerRef {
  const PlayerRef({
    required this.id,
    this.name,
    this.inSpace = true,
    this.isNear = false,
    this.inAudioRange = false,
    this.isFollowingMe = false,
    this.micOn,
    this.cameraOn,
    this.screensharing = false,
    this.distance,
    this.x,
    this.y,
    this.nearSince,
    this.followingMeSince,
  });

  /// Gather's player uuid. Stable for the duration of a session.
  final String id;

  /// Display name, only known when the CDP collector is attached.
  final String? name;

  final bool inSpace;

  /// Standing next to me — Gather considers us close enough to connect media.
  final bool isNear;
  final bool inAudioRange;

  /// This person is following me around.
  final bool isFollowingMe;

  final bool? micOn;
  final bool? cameraOn;
  final bool screensharing;

  /// Distance in tiles, when known (CDP only).
  final double? distance;
  final double? x;
  final double? y;

  final DateTime? nearSince;
  final DateTime? followingMeSince;

  /// What to show in a list: the name if we have it, else a short id.
  String get label => name ?? id.substring(0, id.length.clamp(0, 8));

  PlayerRef copyWith({
    String? name,
    bool? inSpace,
    bool? isNear,
    bool? inAudioRange,
    bool? isFollowingMe,
    bool? micOn,
    bool? cameraOn,
    bool? screensharing,
    double? distance,
    double? x,
    double? y,
    DateTime? nearSince,
    DateTime? followingMeSince,
    bool clearNearSince = false,
    bool clearFollowingMeSince = false,
  }) {
    return PlayerRef(
      id: id,
      name: name ?? this.name,
      inSpace: inSpace ?? this.inSpace,
      isNear: isNear ?? this.isNear,
      inAudioRange: inAudioRange ?? this.inAudioRange,
      isFollowingMe: isFollowingMe ?? this.isFollowingMe,
      micOn: micOn ?? this.micOn,
      cameraOn: cameraOn ?? this.cameraOn,
      screensharing: screensharing ?? this.screensharing,
      distance: distance ?? this.distance,
      x: x ?? this.x,
      y: y ?? this.y,
      nearSince: clearNearSince ? null : (nearSince ?? this.nearSince),
      followingMeSince: clearFollowingMeSince
          ? null
          : (followingMeSince ?? this.followingMeSince),
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'inSpace': inSpace,
        'isNear': isNear,
        'inAudioRange': inAudioRange,
        'isFollowingMe': isFollowingMe,
        'micOn': micOn,
        'cameraOn': cameraOn,
        'screensharing': screensharing,
        'distance': distance,
        'x': x,
        'y': y,
        'nearSince': nearSince?.toIso8601String(),
        'followingMeSince': followingMeSince?.toIso8601String(),
      };

  static PlayerRef fromJson(Map<String, Object?> json) => PlayerRef(
        id: json['id'] as String? ?? '',
        name: json['name'] as String?,
        inSpace: json['inSpace'] as bool? ?? true,
        isNear: json['isNear'] as bool? ?? false,
        inAudioRange: json['inAudioRange'] as bool? ?? false,
        isFollowingMe: json['isFollowingMe'] as bool? ?? false,
        micOn: json['micOn'] as bool?,
        cameraOn: json['cameraOn'] as bool?,
        screensharing: json['screensharing'] as bool? ?? false,
        distance: (json['distance'] as num?)?.toDouble(),
        x: (json['x'] as num?)?.toDouble(),
        y: (json['y'] as num?)?.toDouble(),
        nearSince: DateTime.tryParse(json['nearSince'] as String? ?? ''),
        followingMeSince:
            DateTime.tryParse(json['followingMeSince'] as String? ?? ''),
      );
}

/// My own state in the space.
class SelfState {
  const SelfState({
    this.userId,
    this.spaceId,
    this.spaceName,
    this.micOn,
    this.cameraOn,
    this.screensharing = false,
    this.inOffice,
    this.followingPlayerId,
  });

  final String? userId;
  final String? spaceId;
  final String? spaceName;
  final bool? micOn;
  final bool? cameraOn;
  final bool screensharing;
  final bool? inOffice;

  /// Who I am currently following, if anyone.
  final String? followingPlayerId;

  SelfState copyWith({
    String? userId,
    String? spaceId,
    String? spaceName,
    bool? micOn,
    bool? cameraOn,
    bool? screensharing,
    bool? inOffice,
    String? followingPlayerId,
    bool clearFollowing = false,
  }) {
    return SelfState(
      userId: userId ?? this.userId,
      spaceId: spaceId ?? this.spaceId,
      spaceName: spaceName ?? this.spaceName,
      micOn: micOn ?? this.micOn,
      cameraOn: cameraOn ?? this.cameraOn,
      screensharing: screensharing ?? this.screensharing,
      inOffice: inOffice ?? this.inOffice,
      followingPlayerId:
          clearFollowing ? null : (followingPlayerId ?? this.followingPlayerId),
    );
  }

  Map<String, Object?> toJson() => {
        'userId': userId,
        'spaceId': spaceId,
        'spaceName': spaceName,
        'micOn': micOn,
        'cameraOn': cameraOn,
        'screensharing': screensharing,
        'inOffice': inOffice,
        'followingPlayerId': followingPlayerId,
      };

  static SelfState fromJson(Map<String, Object?> json) => SelfState(
        userId: json['userId'] as String?,
        spaceId: json['spaceId'] as String?,
        spaceName: json['spaceName'] as String?,
        micOn: json['micOn'] as bool?,
        cameraOn: json['cameraOn'] as bool?,
        screensharing: json['screensharing'] as bool? ?? false,
        inOffice: json['inOffice'] as bool?,
        followingPlayerId: json['followingPlayerId'] as String?,
      );
}

/// Which collectors are currently feeding the bridge, so the app can show
/// honestly how good its information is.
class CollectorHealth {
  const CollectorHealth({
    this.logTail = false,
    this.cdp = false,
    this.detail,
  });

  final bool logTail;
  final bool cdp;
  final String? detail;

  /// Names, coordinates and explicit follow state need the CDP collector.
  bool get hasRichData => cdp;

  Map<String, Object?> toJson() => {
        'logTail': logTail,
        'cdp': cdp,
        'detail': detail,
      };

  static CollectorHealth fromJson(Map<String, Object?> json) => CollectorHealth(
        logTail: json['logTail'] as bool? ?? false,
        cdp: json['cdp'] as bool? ?? false,
        detail: json['detail'] as String?,
      );
}

/// Full snapshot pushed on connect and whenever state changes materially.
class PresenceSnapshot {
  const PresenceSnapshot({
    required this.self,
    required this.players,
    required this.health,
    required this.at,
  });

  final SelfState self;
  final List<PlayerRef> players;
  final CollectorHealth health;
  final DateTime at;

  List<PlayerRef> get nearby => players.where((p) => p.isNear).toList();
  List<PlayerRef> get followers =>
      players.where((p) => p.isFollowingMe).toList();

  Map<String, Object?> toJson() => {
        'type': 'presence.snapshot',
        'at': at.toIso8601String(),
        'self': self.toJson(),
        'players': players.map((p) => p.toJson()).toList(),
        'health': health.toJson(),
      };

  static PresenceSnapshot fromJson(Map<String, Object?> json) =>
      PresenceSnapshot(
        at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now(),
        self: SelfState.fromJson(
            (json['self'] as Map?)?.cast<String, Object?>() ?? const {}),
        players: ((json['players'] as List?) ?? const [])
            .map((p) => PlayerRef.fromJson((p as Map).cast<String, Object?>()))
            .toList(),
        health: CollectorHealth.fromJson(
            (json['health'] as Map?)?.cast<String, Object?>() ?? const {}),
      );

  /// A blank snapshot for first paint, before the bridge has answered.
  static PresenceSnapshot get empty => PresenceSnapshot(
        self: const SelfState(),
        players: const [],
        health: const CollectorHealth(),
        at: DateTime.fromMillisecondsSinceEpoch(0),
      );
}
