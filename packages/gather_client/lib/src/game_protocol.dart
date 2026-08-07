/// Interprets Gather V2's game-server protocol.
///
/// A port of `bridge/lib/game-protocol.js`. One binary WebSocket to
/// `wss://game-router.v2.gather.town/gather-game-v2?spaceId=<uuid>&authUserId=<firebaseUid>`
/// carrying msgpack frames. [DirectCollector] opens it and authenticates as the
/// user, then stops at `loadSpaceUser` — it never sends `enterSpace`, so it reads
/// the whole space without showing up as a presence in it.
///
/// ## Wire format
///
/// State arrives as patches against model rows, in two envelopes:
///   - `FullStateChunk.fullStatePatches[]` — the initial dump, sent once per
///     connection, ~1500 patches per chunk across ~49 models.
///   - `DeltaState.patches[]` — everything after that.
///
/// Three patch ops exist, and they are *not* JSON-Patch:
///   - `{op:'addmodel',    model, data}`            whole row; the id is inside `data`
///   - `{op:'deletemodel', model, id}`              row removed
///   - `{op:'replace',     model, id, path, data}`  one field, e.g. `/position/x`
///
/// ## The signal
///
/// **Someone is following me** — `SpaceUser.followTargetId` pointing at my own
/// row. It is an optional column, so it arrives as msgpack `undefined` rather than
/// null when nobody is being followed, and shows up as a `replace` on
/// `/followTargetId`.
///
/// ## The event bus
///
/// `DeltaState` carries a **third** array beside `patches`: `events[]`. It is news
/// rather than state:
///
///   {type:'DeltaState', patches:[], events:[
///      {payload:{eventName:'WaveEvent', senderId:'…', sentTime:'…'},
///       options:{targetUserIds:['…']}}]}
///
/// Measured 2026-08-07: `WaveEvent` and `ChatBroadcastNewMessage`, on an
/// **observer** connection — so `enterSpace` is not required to hear them. A frame
/// carrying only `events[]` has an empty `patches` array, which is exactly how the
/// bus went unread in the bridge for weeks.
///
/// ## Identity
///
/// Which row is *me* is answered by the `Connection` model, which carries both
/// halves: `{authUserId: <firebase uid>, spaceUserId: <my SpaceUser id>}`. The
/// firebase uid comes from our own ID token. `UserAccount` (`{id, firebaseAuthId}`)
/// plus `SpaceUser.userAccountId` gives a second, slower route.
library;

/// Only these models matter; a full state dump is mostly calendars and catalogs.
const _models = {'SpaceUser', 'Connection', 'UserAccount', 'Space'};

/// SpaceUser fields worth tracking, for field-level `replace` patches.
///
/// `speaking` earns its place: measured over three minutes on a 111-person space
/// it was the most frequent delta of any kind. It is live voice activity — who is
/// actually talking.
const _trackedFields = {
  'followTargetId',
  'position',
  'floorId',
  'name',
  'connected',
  'isIdle',
  'speaking',
  'userAccountId',
};

/// One interaction off `DeltaState.events[]`.
///
/// The two things a caller always needs sit in different halves of the envelope:
/// who did it is `payload.senderId`, and who they did it *at* is
/// `options.targetUserIds`. Normalised here so callers do not have to know that.
class BusEvent {
  const BusEvent({
    required this.name,
    required this.senderId,
    required this.sentTime,
    required this.targetUserIds,
    required this.payload,
  });

  /// `WaveEvent`, `ChatBroadcastNewMessage`, … — Gather's own `eventName`.
  final String name;
  final String? senderId;

  /// The sender's own clock, as an ISO-8601 string. Gather sends a plain string
  /// today, but `createdAt`-style fields on this protocol are msgpack ext-1
  /// DateTimes, so both are accepted and normalised.
  final String? sentTime;
  final List<String> targetUserIds;

  /// The payload untouched, so a new `eventName` is readable without a change here.
  final Map<String, Object?> payload;

  /// Whether this was aimed at [spaceUserId].
  bool isFor(String? spaceUserId) =>
      spaceUserId != null && targetUserIds.contains(spaceUserId);

  @override
  String toString() => 'BusEvent($name from $senderId -> $targetUserIds)';
}

/// One person in the space, as far as a state dump plus deltas can tell.
class RosterRow {
  const RosterRow({
    required this.id,
    this.name,
    this.x,
    this.y,
    this.floorId,
    this.connected,
    this.speaking,
    this.followTargetKnown = false,
    this.followTargetId,
  });

  final String id;
  final String? name;

  /// Kept for party mode's walkable-tile pool, not for judging adjacency.
  final num? x;
  final num? y;
  final String? floorId;
  final bool? connected;
  final bool? speaking;

  /// Whether `followTargetId` was present on the row at all.
  ///
  /// The distinction the JS carried by omitting the key entirely: without it,
  /// "nobody is following me" and "I cannot tell" look identical, and the app
  /// would render a confident empty state out of missing data.
  final bool followTargetKnown;
  final String? followTargetId;
}

/// A whole roster, as [PresenceTracker] consumes it.
class Roster {
  const Roster({required this.selfId, required this.rows, this.spaceName});

  final String? selfId;
  final List<RosterRow> rows;
  final String? spaceName;
}

/// Mutable accumulator for one SpaceUser as patches arrive.
class _Row {
  _Row(this.id);

  final String id;
  String? name;
  num? x;
  num? y;
  String? floorId;
  bool? connected;
  bool? isIdle;
  bool? speaking;
  bool? isBot;
  String? kind;
  String? userAccountId;
  bool followTargetKnown = false;
  String? followTargetId;
  bool gone = false;
}

class GameProtocolReader {
  GameProtocolReader({void Function(String)? log}) : _log = log ?? _noop;

  static void _noop(String _) {}

  final void Function(String) _log;

  /// SpaceUser id -> row we have assembled.
  final Map<String, _Row> _users = {};

  /// My own SpaceUser id, once identified.
  String? selfId;

  /// Firebase uid, from our own ID token.
  String? authUserId;
  String? spaceId;

  /// The space's display name, from the single `Space` row in the dump.
  String? spaceName;

  /// UserAccount id belonging to me, the slower route to [selfId].
  String? _myUserAccountId;

  /// Interaction events waiting to be drained.
  ///
  /// Queued rather than delivered inline, so [ingest]'s "did the roster change"
  /// answer keeps its meaning — a wave changes no state at all.
  final List<BusEvent> _pending = [];

  final Map<String, int> _frameTypes = {};
  int _unknownFrames = 0;
  int _patchCount = 0;
  int _busEvents = 0;

  int get userCount => _users.length;

  /// Hands over the queued interaction events and forgets them.
  List<BusEvent> takePending() {
    if (_pending.isEmpty) return const [];
    final out = List<BusEvent>.of(_pending);
    _pending.clear();
    return out;
  }

  /// Learns identity hints from the WebSocket URL we opened.
  void noteSocketUrl(String url) {
    final parsed = Uri.tryParse(url);
    if (parsed == null) return;
    authUserId = parsed.queryParameters['authUserId'] ?? authUserId;
    spaceId = parsed.queryParameters['spaceId'] ?? spaceId;
  }

  Map<String, Object?> stats() => {
        'users': _users.length,
        'selfId': selfId,
        'spaceId': spaceId,
        'patches': _patchCount,
        'busEvents': _busEvents,
        'unknownFrames': _unknownFrames,
        'frameTypes': (_frameTypes.entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value)))
            .take(12)
            .map((e) => '${e.key}:${e.value}')
            .toList(),
      };

  /// Feed one decoded frame. Returns true when the roster changed in a way worth
  /// republishing.
  bool ingest(Object? frame) {
    if (frame is! Map<String, Object?>) return false;

    final type = frame['type'] is String ? frame['type'] as String : '(untyped)';
    _frameTypes[type] = (_frameTypes[type] ?? 0) + 1;

    // Heartbeats are the bulk of the traffic and carry nothing.
    if (type == 'Heartbeat') return false;

    // Before the patches, because a wave arrives in a frame whose `patches` array
    // is empty — which is exactly how it went unnoticed for so long.
    final bus = _collectBusEvents(frame);
    for (final event in bus) {
      _pending.add(event);
      _busEvents++;
    }

    final patches = _collectPatches(frame);
    if (patches.isEmpty) {
      // Frames that legitimately carry no model state (Authenticate, Subscribe,
      // SpaceStatus, …) — but a frame we *did* understand as an interaction is not
      // unrecognised.
      if (bus.isEmpty) _unknownFrames++;
      return false;
    }

    var changed = false;
    for (final patch in patches) {
      if (_applyPatch(patch)) changed = true;
    }
    if (changed || selfId == null) _identifySelf();
    return changed;
  }

  bool _applyPatch(Map<String, Object?> patch) {
    final model = patch['model'];
    if (model is! String || !_models.contains(model)) return false;
    _patchCount++;

    switch (patch['op']) {
      case 'addmodel':
        return _addModel(model, patch['data']);
      case 'deletemodel':
        return _deleteModel(model, patch['id']);
      case 'replace':
        return _replaceField(model, patch);
      default:
        return false;
    }
  }

  bool _addModel(String model, Object? raw) {
    if (raw is! Map<String, Object?>) return false;
    final id = raw['id'];
    if (id is! String) return false;

    if (model == 'SpaceUser') return _merge(_row(id), raw);

    if (model == 'Connection') {
      // The direct answer to "which SpaceUser am I".
      final spaceUserId = raw['spaceUserId'];
      if (authUserId != null && raw['authUserId'] == authUserId && spaceUserId is String) {
        if (selfId != spaceUserId) {
          selfId = spaceUserId;
          _log('game protocol: own space user $spaceUserId (via Connection)');
          return true;
        }
      }
      return false;
    }

    if (model == 'UserAccount') {
      if (authUserId != null && raw['firebaseAuthId'] == authUserId) {
        _myUserAccountId = id;
        return true;
      }
      return false;
    }

    if (model == 'Space') {
      // Exactly one row, and it is the space we asked for.
      final name = raw['name'];
      if (name is String && name != spaceName) {
        spaceName = name;
        return true;
      }
      return false;
    }

    return false;
  }

  bool _deleteModel(String model, Object? id) {
    if (model != 'SpaceUser' || id is! String) return false;
    final row = _users[id];
    if (row == null) return false;
    row.connected = false;
    row.gone = true;
    return true;
  }

  bool _replaceField(String model, Map<String, Object?> patch) {
    if (model != 'SpaceUser') return false;

    final id = patch['id'];
    if (id is! String) return false;
    final segments =
        (patch['path'] as String? ?? '').split('/').where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return false;

    // Paths are addressed to the row, so the field is the first segment. Position
    // mutates component-wise, giving `/position/x` — reading only the last segment
    // would silently drop every walking patch.
    final field = segments.first;
    if (!_trackedFields.contains(field)) return false;

    final row = _row(id);
    final sub = segments.skip(1).toList();

    if (sub.isEmpty) return _merge(row, {field: patch['data']});

    if (field == 'position' && (sub.first == 'x' || sub.first == 'y')) {
      final value = patch['data'];
      if (value is! num) return false;
      return _merge(row, {'position__${sub.first}': value});
    }

    return false;
  }

  _Row _row(String id) => _users.putIfAbsent(id, () => _Row(id));

  bool _merge(_Row row, Map<String, Object?> data) {
    var changed = false;

    void setIf(bool condition, void Function() apply) {
      if (condition) apply();
    }

    void set<T>(T current, T next, void Function(T) assign) {
      if (current == next) return;
      assign(next);
      changed = true;
    }

    if (data.containsKey('name')) {
      set(row.name, _nullableString(data['name']), (v) => row.name = v);
    }
    if (data.containsKey('userAccountId')) {
      set(row.userAccountId, _nullableString(data['userAccountId']),
          (v) => row.userAccountId = v);
    }
    if (data.containsKey('floorId')) {
      set(row.floorId, _nullableString(data['floorId']), (v) => row.floorId = v);
    }
    if (data.containsKey('connected')) {
      set(row.connected, _asBool(data['connected']), (v) => row.connected = v);
    }
    if (data.containsKey('isIdle')) {
      set(row.isIdle, _asBool(data['isIdle']), (v) => row.isIdle = v);
    }
    if (data.containsKey('speaking')) {
      set(row.speaking, _asBool(data['speaking']), (v) => row.speaking = v);
    }
    if (data.containsKey('isBot')) {
      set(row.isBot, _asBool(data['isBot']), (v) => row.isBot = v);
    }
    if (data.containsKey('type')) {
      set(row.kind, _nullableString(data['type']), (v) => row.kind = v);
    }

    // An optional column: only touch it when the key is actually present, and
    // remember that it *was* present. `PresenceTracker` tells absent from null to
    // decide whether following is answerable at all.
    if (data.containsKey('followTargetId')) {
      setIf(!row.followTargetKnown, () {
        row.followTargetKnown = true;
        changed = true;
      });
      set(row.followTargetId, _nullableString(data['followTargetId']),
          (v) => row.followTargetId = v);
    }

    // Position arrives as a value object: {'$type': 'Position', 'x': …, 'y': …}.
    final position = data['position'];
    if (position is Map<String, Object?>) {
      final px = position['x'];
      final py = position['y'];
      if (px is num) set(row.x, px, (v) => row.x = v);
      if (py is num) set(row.y, py, (v) => row.y = v);
    }
    final flatX = data['position__x'];
    final flatY = data['position__y'];
    if (flatX is num) set(row.x, flatX, (v) => row.x = v);
    if (flatY is num) set(row.y, flatY, (v) => row.y = v);

    return changed;
  }

  /// Fallback route to identity when no Connection row named us.
  void _identifySelf() {
    if (selfId != null || _myUserAccountId == null) return;
    for (final row in _users.values) {
      if (row.userAccountId != null && row.userAccountId == _myUserAccountId) {
        selfId = row.id;
        _log('game protocol: own space user ${row.id} (via UserAccount)');
        return;
      }
    }
  }

  /// The roster in the shape [PresenceTracker] consumes.
  Roster roster() {
    final rows = <RosterRow>[];
    for (final row in _users.values) {
      // Recording clients and bots are not people who can follow you.
      if (row.isBot == true || row.kind == 'RecordingClient') continue;
      rows.add(RosterRow(
        id: row.id,
        name: row.name,
        x: row.x,
        y: row.y,
        floorId: row.floorId,
        connected: row.gone ? false : row.connected,
        speaking: row.speaking,
        followTargetKnown: row.followTargetKnown,
        followTargetId: row.followTargetId,
      ));
    }
    return Roster(selfId: selfId, rows: rows, spaceName: spaceName);
  }
}

/// Pulls the patch arrays out of a frame.
///
/// `FullStateChunk` uses `fullStatePatches`, `DeltaState` uses `patches`. Both are
/// read explicitly; anything else is left alone rather than guessed at.
List<Map<String, Object?>> _collectPatches(Map<String, Object?> frame) {
  final out = <Map<String, Object?>>[];
  for (final key in const ['fullStatePatches', 'patches']) {
    final list = frame[key];
    if (list is! List) continue;
    for (final patch in list) {
      if (patch is Map<String, Object?> && patch['op'] is String) out.add(patch);
    }
  }
  return out;
}

/// Pulls interaction events out of `DeltaState.events[]`.
List<BusEvent> _collectBusEvents(Map<String, Object?> frame) {
  final list = frame['events'];
  if (list is! List) return const [];

  final out = <BusEvent>[];
  for (final entry in list) {
    if (entry is! Map<String, Object?>) continue;
    final payload = entry['payload'];
    if (payload is! Map<String, Object?>) continue;
    final name = payload['eventName'];
    if (name is! String) continue;

    final options = entry['options'];
    final targets = options is Map<String, Object?> ? options['targetUserIds'] : null;

    out.add(BusEvent(
      name: name,
      senderId: _nullableString(payload['senderId']),
      sentTime: _asIsoString(payload['sentTime']),
      targetUserIds: targets is List ? targets.whereType<String>().toList() : const [],
      payload: payload,
    ));
  }
  return out;
}

String? _asIsoString(Object? value) {
  if (value is DateTime) return value.toIso8601String();
  if (value is String && value.isNotEmpty) return value;
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true).toIso8601String();
  }
  return null;
}

String? _nullableString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

bool? _asBool(Object? value) => value is bool ? value : null;
