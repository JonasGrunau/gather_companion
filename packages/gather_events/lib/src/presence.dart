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
    this.isFollowingMe = false,
    this.speaking = false,
    this.micOn,
    this.cameraOn,
    this.screensharing = false,
    this.followingMeSince,
  });

  /// Gather's player uuid. Stable for the duration of a session.
  final String id;

  /// Display name, straight from Gather's `SpaceUser.name`.
  final String? name;

  final bool inSpace;

  /// This person is following me around — the one thing worth knowing about
  /// somebody else in the space, and the reason this app exists.
  final bool isFollowingMe;

  /// Talking right now — Gather's own `SpaceUser.speaking`, and the most
  /// frequently updated field on the whole game socket. The bridge only reports
  /// changes for people who are following you, because they are the only ones
  /// the app draws.
  final bool speaking;

  /// Always null. Mic, camera and screenshare were only ever readable by
  /// scraping the desktop client's log and are in no Gather model; [speaking]
  /// is the signal that replaced them. Kept so older snapshots still decode.
  final bool? micOn;
  final bool? cameraOn;
  final bool screensharing;

  final DateTime? followingMeSince;

  /// What to show in a list: the name if we have it, else a short id.
  String get label => name ?? id.substring(0, id.length.clamp(0, 8));

  PlayerRef copyWith({
    String? name,
    bool? inSpace,
    bool? isFollowingMe,
    bool? speaking,
    bool? micOn,
    bool? cameraOn,
    bool? screensharing,
    DateTime? followingMeSince,
    bool clearFollowingMeSince = false,
  }) {
    return PlayerRef(
      id: id,
      name: name ?? this.name,
      inSpace: inSpace ?? this.inSpace,
      isFollowingMe: isFollowingMe ?? this.isFollowingMe,
      speaking: speaking ?? this.speaking,
      micOn: micOn ?? this.micOn,
      cameraOn: cameraOn ?? this.cameraOn,
      screensharing: screensharing ?? this.screensharing,
      followingMeSince: clearFollowingMeSince
          ? null
          : (followingMeSince ?? this.followingMeSince),
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'inSpace': inSpace,
        'isFollowingMe': isFollowingMe,
        'speaking': speaking,
        'micOn': micOn,
        'cameraOn': cameraOn,
        'screensharing': screensharing,
        'followingMeSince': followingMeSince?.toIso8601String(),
      };

  static PlayerRef fromJson(Map<String, Object?> json) => PlayerRef(
        id: json['id'] as String? ?? '',
        name: json['name'] as String?,
        inSpace: json['inSpace'] as bool? ?? true,
        isFollowingMe: json['isFollowingMe'] as bool? ?? false,
        speaking: json['speaking'] as bool? ?? false,
        micOn: json['micOn'] as bool?,
        cameraOn: json['cameraOn'] as bool?,
        screensharing: json['screensharing'] as bool? ?? false,
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

/// What the bridge is currently connected to, so the app can show honestly how
/// good its information is.
class CollectorHealth {
  const CollectorHealth({
    this.gather = false,
    this.logTail = false,
    this.cdp = false,
    this.detail,
  });

  /// The connection to Gather's own game socket. Everything about people —
  /// names, following, voice activity — comes from here.
  final bool gather;

  /// The tail of the desktop client's log, which now carries exactly one thing:
  /// Gather's own notifications (waves, meeting invites, event reminders). Down
  /// simply means the desktop app is not running; presence is unaffected.
  final bool logTail;

  /// Was the CDP collector, which no longer exists. Still read because a bridge
  /// older than this app build sets it and nothing else, and because the current
  /// bridge mirrors [gather] onto it for app builds older than *it*.
  final bool cdp;

  final String? detail;

  /// Whether we have names, coordinates and explicit follow state.
  bool get hasRichData => gather || cdp;

  Map<String, Object?> toJson() => {
        'gather': gather,
        'logTail': logTail,
        'cdp': cdp,
        'detail': detail,
      };

  static CollectorHealth fromJson(Map<String, Object?> json) => CollectorHealth(
        gather: json['gather'] as bool? ?? false,
        logTail: json['logTail'] as bool? ?? false,
        cdp: json['cdp'] as bool? ?? false,
        detail: json['detail'] as String?,
      );
}

/// Party mode: whether the bridge is currently teleporting me around the map.
///
/// Comes back on the snapshot rather than being tracked in the app, because the
/// app is not the only thing that can change it — the bridge stops on its own
/// after fifteen minutes, when it loses Gather, and when the daemon shuts down.
/// A toggle that only remembers what it was last told would keep glowing through
/// all three.
class PartyState {
  const PartyState({
    this.active = false,
    this.hops = 0,
    this.safeTiles = 0,
    this.detail,
  });

  final bool active;

  /// Teleports made this session.
  final int hops;

  /// How many tiles were far enough from everyone at the last hop.
  final int safeTiles;

  /// Why it is not hopping, when it is not. Also carries the reason it stopped.
  final String? detail;

  Map<String, Object?> toJson() => {
        'active': active,
        'hops': hops,
        'safeTiles': safeTiles,
        'detail': detail,
      };

  static PartyState fromJson(Map<String, Object?> json) => PartyState(
        active: json['active'] as bool? ?? false,
        hops: (json['hops'] as num?)?.toInt() ?? 0,
        safeTiles: (json['safeTiles'] as num?)?.toInt() ?? 0,
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
    this.party = const PartyState(),
  });

  final SelfState self;
  final List<PlayerRef> players;
  final CollectorHealth health;
  final DateTime at;

  /// Defaulted rather than required: a bridge older than this app build sends no
  /// `party` key at all, and "off" is the right reading of its silence.
  final PartyState party;

  List<PlayerRef> get followers =>
      players.where((p) => p.isFollowingMe).toList();

  /// The same world, with party mode's counters moved on.
  ///
  /// The bridge sends the hop counter on its own small frame rather than
  /// republishing the roster for it — see `BridgeServer._publishParty`. This is
  /// how that frame is folded in.
  PresenceSnapshot withParty(PartyState party) => PresenceSnapshot(
        self: self,
        players: players,
        health: health,
        at: at,
        party: party,
      );

  Map<String, Object?> toJson() => {
        'type': 'presence.snapshot',
        'at': at.toIso8601String(),
        'self': self.toJson(),
        'players': players.map((p) => p.toJson()).toList(),
        'health': health.toJson(),
        'party': party.toJson(),
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
        party: PartyState.fromJson(
            (json['party'] as Map?)?.cast<String, Object?>() ?? const {}),
      );

  /// A blank snapshot for first paint, before the bridge has answered.
  static PresenceSnapshot get empty => PresenceSnapshot(
        self: const SelfState(),
        players: const [],
        health: const CollectorHealth(),
        at: DateTime.fromMillisecondsSinceEpoch(0),
      );
}
