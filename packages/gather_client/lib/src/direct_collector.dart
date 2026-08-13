/// Reads presence by connecting to Gather ourselves, from the phone.
///
/// A port of `bridge/lib/direct.js`. The bridge opens this connection on the Mac;
/// this opens the same one from the app, which is what lets the app stop depending
/// on the bridge being reachable at all.
///
/// ## Entering, and what it costs
///
/// `loadSpaceUser` materialises our SpaceUser and starts the state dump.
/// `enterSpace` is a *separate* action, and it is what actually puts an avatar in
/// the room. **This collector sends it**, because the app is no longer only
/// watching: a phone that publishes audio and video is a participant, and a
/// participant is present. `Connection.entered` goes true, and `reportActivity`
/// follows so we do not sit there looking idle to colleagues.
///
/// The bridge's copy of this collector (`bridge/lib/direct.js`) does **not** enter
/// and must never start. It exists to wake a sleeping phone and has no reason to
/// be in a room. That divergence is deliberate — see `AGENTS.md` — and is the one
/// place these two implementations of the same wire format are allowed to differ.
///
/// Two connections of your own do not fight: `Connection` is per-connection but
/// `SpaceUser` is per-person-per-space, so the desktop client and this one drive
/// the same avatar. Measured 2026-08-06: neither an observer connection nor an
/// entered one disturbed the desktop client's socket, `enterSpace` returned
/// `{type:'Success'}`, and our position was unchanged either side of it.
///
/// What entering costs is real and worth knowing: **`numTimesEnteredSpace`
/// increments per entering connection**, and it is a permanent counter on the
/// user's own profile. That makes reconnect frequency a thing with a price, which
/// is why `AppState.verifyLink()` does not reconnect a socket that is already
/// healthy. Do not "simplify" that into an unconditional resync.
///
/// ## No resync
///
/// The full state dump is sent once per *connection*. So there is nothing to ask
/// for: [resync] reconnects, and the dump follows immediately. On a phone this is
/// the behaviour that matters most — iOS suspends the app, the socket dies
/// unannounced, and on resume a fresh connection is both the repair and the
/// refresh.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'game_protocol.dart';
import 'gather_auth.dart';
import 'msgpack.dart';
import 'space_art.dart';
import 'space_map.dart';

const _gameSocket = 'wss://game-router.v2.gather.town/gather-game-v2';

/// Rosters are coalesced over this window rather than published per patch. A busy
/// space moves several people a second, and the screen wants the result, not the
/// frames.
const _publishInterval = Duration(milliseconds: 250);

/// The desktop client heartbeats roughly once a second. We are far less chatty
/// because nothing depends on our liveness being noticed quickly; an
/// unauthenticated probe survived 25s sending none at all.
const _heartbeatInterval = Duration(seconds: 10);

/// How long after the handshake we stay quiet about holding no state.
///
/// A server heartbeat usually lands before the first `FullStateChunk`, so without
/// this the collector would announce failure on every connect and immediately
/// retract it.
const _handshakeGrace = Duration(seconds: 5);

const _maxBackoff = Duration(seconds: 30);

/// What we tell Gather we are. Mirrors the desktop client.
const _connectionTarget = 'OfficeView';
const _clientPlatform = 'Desktop';

/// Whether the collector is holding state, and what to say if not.
class CollectorStatus {
  const CollectorStatus({required this.healthy, this.detail, this.needsPairing = false});

  final bool healthy;
  final String? detail;

  /// The credential is dead and only re-pairing will fix it. The one status the UI
  /// must turn into an instruction rather than a spinner.
  final bool needsPairing;

  @override
  String toString() => 'CollectorStatus($healthy, $detail)';
}

class DirectCollector {
  DirectCollector({
    required GatherAuth auth,
    String? spaceId,
    String socketUrl = _gameSocket,
    Future<WebSocket> Function(String url)? connect,
    void Function(String)? log,
        // A named parameter cannot be a private initializing formal, so these are
        // assigned the long way round — same as `BridgeClient` and `AppState`.
        // ignore: prefer_initializing_formals
  })  : _auth = auth,
        _configuredSpaceId = spaceId,
        spaceId = spaceId,
        // ignore: prefer_initializing_formals
        _socketUrl = socketUrl,
        _connect = connect ?? WebSocket.connect,
        _log = log ?? _noop;

  static void _noop(String _) {}

  final GatherAuth _auth;
  final String _socketUrl;

  /// Overridable so tests can point at a fake game server instead of Gather.
  final Future<WebSocket> Function(String url) _connect;
  final void Function(String) _log;

  /// Explicitly configured space, if any; otherwise resolved per connect.
  final String? _configuredSpaceId;
  String? spaceId;

  GameProtocolReader reader = GameProtocolReader();

  WebSocket? _ws;
  Timer? _retryTimer;
  Timer? _publishTimer;
  Timer? _heartbeatTimer;
  Duration _backoff = const Duration(seconds: 1);
  bool _stopped = false;
  bool _healthy = false;
  String? _lastDetail;
  bool _dirty = false;
  int _frames = 0;
  int _connects = 0;

  /// Whether `enterSpace` has gone out on the current socket. Reset per connect.
  bool _entered = false;
  DateTime? _handshakeAt;

  final _rosters = StreamController<Roster>.broadcast();
  final _interactions = StreamController<BusEvent>.broadcast();
  final _statuses = StreamController<CollectorStatus>.broadcast();

  /// The roster, coalesced. One event per change worth rendering.
  Stream<Roster> get rosters => _rosters.stream;

  /// Waves and the rest of Gather's event bus, published the moment they arrive.
  Stream<BusEvent> get interactions => _interactions.stream;
  Stream<CollectorStatus> get statuses => _statuses.stream;

  bool get healthy => _healthy;
  String? get detail => _lastDetail;

  /// Whether we hold state, as opposed to merely being connected. The distinction
  /// matters: an empty roster reported as healthy would let the app render a
  /// confident "nobody is following you" out of nothing.
  bool get hasState => reader.userCount > 0;

  /// Our own `SpaceUser` id, once the dump has told us which row is us.
  String? get selfId => reader.selfId;

  /// The floor plan for a floor, or null until the dump has carried enough of it.
  ///
  /// Read through rather than cached: the builder rebuilds only when a map model
  /// actually changed, so asking repeatedly is cheap and asking early is correct —
  /// it starts returning a map the moment one can be built.
  SpaceMap? mapFor(String? floorId) => reader.mapBuilder.forFloor(floorId);

  /// The same floor, drawn: floor tiles, wall pieces and furniture sprites, with the
  /// URLs to fetch them from. Read through for the same reason as [mapFor].
  SpaceArt? artFor(String? floorId, {bool dark = true}) =>
      reader.mapBuilder.artFor(floorId, dark: dark);

  /// Somebody's avatar spritesheet, or null when their outfit is not known.
  String? avatarUrlFor(String spaceUserId) => reader.avatarUrlFor(spaceUserId);

  Map<String, Object?> stats() => {
        ...reader.stats(),
        'frames': _frames,
        'connects': _connects,
        'spaceId': spaceId,
        'authUserId': reader.authUserId,
        'entered': _entered,
      };

  void start() {
    _stopped = false;
    _connectNow();
  }

  Future<void> stop() async {
    _stopped = true;
    _clearTimers();
    await _closeSocket();
  }

  Future<void> dispose() async {
    await stop();
    await _rosters.close();
    await _interactions.close();
    await _statuses.close();
  }

  /// Reconnects, which is all a resync is here: the server replays the full state
  /// dump on every new connection.
  Future<({bool ok, String detail})> resync() async {
    if (_stopped) return (ok: false, detail: 'collector stopped');
    _log('direct: reconnecting to force a fresh state dump');
    _clearTimers();
    await _closeSocket();
    _backoff = const Duration(seconds: 1);
    _connectNow();
    return (ok: true, detail: 'reconnecting; a full state dump follows immediately');
  }

  /// Takes one step. What the D-pad sends.
  ///
  /// `move` is the action Gather's own client sends for a keypress, and its whole body
  /// is a delta and a turn:
  ///
  /// ```js
  /// fn: () => A => {
  ///   const e = new Direction(A.direction).toPositionDelta();
  ///   const g = new Position({x: this.x + e.x, y: this.y + e.y});
  ///   this.direction = new Direction(A.direction);
  ///   this.setPosition(g, {map: ..., prevPosition: this.position})
  /// }
  /// ```
  ///
  /// **There is no collision check in it.** Whether the step is legal is decided
  /// entirely on the client, before this is sent — see [SpaceMap.canStep], which is
  /// the rule, and `walk.dart`, which is the caller that applies it. Sending this
  /// blind walks the user's avatar through the office wall and out into the void.
  ///
  /// One tile per call, and it turns whether or not it moves: [direction] is written
  /// to `SpaceUser.direction` before the position is touched.
  ///
  /// Fire-and-forget for the same reason [teleport] is.
  ({bool ok, String? detail}) move({required String direction}) {
    if (!moveDirections.contains(direction)) {
      return (ok: false, detail: '$direction is not a direction');
    }
    return _act('move', {'direction': direction});
  }

  /// Moves our avatar to a tile. The one thing this collector writes.
  ///
  /// `SpaceUser` is per-person-per-space rather than per-connection, so this moves
  /// the *same* avatar the desktop client is driving — there is no second body to
  /// fight with. Verified 2026-08-07 that it works from an observer connection:
  /// `teleport` returns `{type:'Success'}` without `enterSpace` having been sent.
  ///
  /// Fire-and-forget by design. Replies come back asynchronously in
  /// `DeltaState.actionReturns[]` keyed by `txnId`, and the only failures a caller
  /// could act on are already answerable here. The authoritative confirmation is
  /// the position patch that follows, through the normal roster path.
  ///
  /// The server does **not** validate walkability: every tile on the grid is
  /// accepted, walls and void included. Picking somewhere sensible is the caller's
  /// job.
  ({bool ok, String? detail}) teleport({
    required num x,
    required num y,
    String direction = 'Down',
  }) {
    if (!x.isFinite || !y.isFinite) {
      return (ok: false, detail: 'teleport needs finite coordinates');
    }
    // Flat x/y — `{position:{x,y}}` is rejected — and `direction` is required even
    // though teleporting does not pass through any tiles.
    return _act('teleport', {'x': x, 'y': y, 'direction': direction});
  }

  /// One action against our own `SpaceUser` row, on the socket we already hold.
  ({bool ok, String? detail}) _act(String action, Map<String, Object?> args) {
    final ws = _ws;
    if (ws == null || ws.readyState != WebSocket.open) {
      return (ok: false, detail: 'not connected to Gather');
    }
    final self = reader.selfId;
    if (self == null) {
      return (ok: false, detail: 'do not know which avatar is ours yet');
    }

    try {
      ws.add(msgpackEncode({
        'type': 'Action',
        'txnId': _txnId(),
        'action': action,
        'args': ['SpaceUser', self, args],
      }));
      return (ok: true, detail: null);
    } on Object catch (error) {
      return (ok: false, detail: '$error');
    }
  }

  void _clearTimers() {
    _retryTimer?.cancel();
    _publishTimer?.cancel();
    _heartbeatTimer?.cancel();
    _retryTimer = null;
    _publishTimer = null;
    _heartbeatTimer = null;
  }

  Future<void> _closeSocket() async {
    final ws = _ws;
    _ws = null;
    if (ws == null) return;
    try {
      await ws.close();
    } on Object {
      /* already gone */
    }
  }

  void _setHealth(bool healthy, String? detail, {bool needsPairing = false}) {
    final changed = healthy != _healthy || detail != _lastDetail;
    _healthy = healthy;
    _lastDetail = detail;
    if (!changed) return;
    if (_statuses.isClosed) return;
    _statuses.add(
      CollectorStatus(healthy: healthy, detail: detail, needsPairing: needsPairing),
    );
  }

  void _scheduleRetry() {
    if (_stopped || _retryTimer != null) return;
    final wait = _backoff;
    final next = _backoff * 2;
    _backoff = next > _maxBackoff ? _maxBackoff : next;
    _retryTimer = Timer(wait, () {
      _retryTimer = null;
      _connectNow();
    });
  }

  /// Which space to join, and who we are in it.
  ///
  /// Prefers configuration — the id handed over at pairing — then asks the API.
  /// The bridge can also read the space the desktop client last opened off disk;
  /// the phone has no such shortcut, so the REST call is the fallback rather than
  /// the last resort.
  ///
  /// `/users/me/recent-spaces` hands over `spaceUserId` as well, which is what
  /// `enterSpace` addresses. Getting it here means entering in the same breath as
  /// the rest of the handshake rather than waiting for the `Connection` row to
  /// come back and name us. A configured space id carries no such hint, so that
  /// path enters late instead — see [_maybeEnter].
  Future<({String id, String? spaceUserId})?> _resolveSpace() async {
    if (_configuredSpaceId != null && _configuredSpaceId.isNotEmpty) {
      return (id: _configuredSpaceId, spaceUserId: null);
    }
    final spaces = await _auth.recentSpaces();
    if (spaces.isEmpty) return null;
    return (id: spaces.first.id, spaceUserId: spaces.first.spaceUserId);
  }

  void _connectNow() {
    unawaited(_openConnection());
  }

  Future<void> _openConnection() async {
    if (_stopped) return;
    _clearTimers();
    await _closeSocket();
    if (_stopped) return;

    final String token;
    final ({String id, String? spaceUserId})? resolved;
    try {
      token = await _auth.idToken();
      resolved = await _resolveSpace();
    } on GatherAuthException catch (error) {
      // The one failure the user has to act on, kept distinct from every other:
      // a dead refresh token cannot be retried into working.
      _setHealth(false, 'Gather sign-in failed: ${error.message}',
          needsPairing: error.permanent);
      if (!error.permanent) _scheduleRetry();
      return;
    } on Object catch (error) {
      _setHealth(false, 'Gather sign-in failed: $error');
      _scheduleRetry();
      return;
    }
    if (_stopped) return;

    if (resolved == null) {
      _setHealth(false, 'no space to join — open a space in Gather once');
      _scheduleRetry();
      return;
    }
    final resolvedSpace = resolved.id;
    spaceId = resolvedSpace;

    // The token is the identity; a stored uid is only a cache of it. Reading the
    // token first means stale config cannot silently point us at the wrong
    // account — which would leave `selfId` unresolved and make "following me"
    // unanswerable.
    final authUserId = uidFromIdToken(token) ?? _auth.uid;

    // A fresh reader per connection: the dump we are about to receive is complete,
    // so carrying rows over would only keep ghosts of people who have since left.
    reader = GameProtocolReader(log: _log)..authUserId = authUserId;
    _frames = 0;

    final url = '$_socketUrl?spaceId=${Uri.encodeQueryComponent(resolvedSpace)}'
        '&authUserId=${Uri.encodeQueryComponent(authUserId ?? '')}';
    reader.noteSocketUrl(url);

    final WebSocket ws;
    try {
      ws = await _connect(url);
    } on Object catch (error) {
      _setHealth(false, 'game socket connect failed: $error');
      _scheduleRetry();
      return;
    }
    if (_stopped) {
      await ws.close();
      return;
    }

    _ws = ws;
    _connects++;
    _backoff = const Duration(seconds: 1);
    _entered = false;
    _log('direct: connected to space $resolvedSpace');

    try {
      for (final frame in _handshake(token, resolvedSpace, resolved.spaceUserId)) {
        ws.add(msgpackEncode(frame));
      }
      if (resolved.spaceUserId != null) _entered = true;
    } on Object catch (error) {
      // The encoder refuses rather than sending something Gather would ignore.
      _setHealth(false, 'handshake encode failed: $error');
      await _closeSocket();
      _scheduleRetry();
      return;
    }

    _handshakeAt = DateTime.now();
    _setHealth(false, 'handshake sent; waiting for state');

    _publishTimer = Timer.periodic(_publishInterval, (_) => _flush());
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) => _heartbeat());

    ws.listen(
      (data) {
        if (_ws != ws) return;
        _onFrame(data);
      },
      onError: (Object _) {
        // `onDone` always follows and carries the code; retry from there.
        if (_ws == ws) _log('direct: game socket error');
      },
      onDone: () {
        if (_ws != ws) return;
        _clearTimers();
        _ws = null;
        final code = ws.closeCode ?? 0;
        // 4031 is the duplicate-connection code the gateway was long believed to
        // use. Neither an observer connection nor an entered one triggers it —
        // both were measured — so seeing it here would mean Gather's rules
        // changed and is worth saying out loud.
        final suffix = code == 4031 ? ' — duplicate connection rejected' : '';
        _setHealth(false, 'game socket closed ($code)$suffix');
        _scheduleRetry();
      },
      cancelOnError: false,
    );
  }

  /// The frames that get us subscribed, and then into the room.
  ///
  /// The first four are the subscription. `enterSpace` is the fifth and is what
  /// makes us present; it needs our own `SpaceUser` id, so it is only included
  /// when [spaceUserId] is already known. Otherwise [_maybeEnter] sends it once
  /// the `Connection` row names us.
  ///
  /// A wrong-shaped `Authenticate` is the trap: Gather does not reject it, it simply
  /// never replies and keeps heartbeating, so the failure looks like a network
  /// problem rather than an auth one. These shapes were captured off the desktop
  /// client's own outbound frames, and `msgpack_test.dart` pins the bytes.
  List<Map<String, Object?>> _handshake(
    String token,
    String space,
    String? spaceUserId,
  ) =>
      [
        {
          'type': 'Authenticate',
          'credential': {'type': 'JWT', 'jwt': token},
        },
        {'type': 'ConnectToSpace', 'spaceId': space},
        {'type': 'Subscribe'},
        {
          'type': 'Action',
          'txnId': _txnId(),
          'action': 'loadSpaceUser',
          'args': [
            'SpaceUser',
            null,
            {'connectionTarget': _connectionTarget, 'clientPlatform': _clientPlatform},
          ],
        },
        if (spaceUserId != null) ..._enterFrames(spaceUserId),
      ];

  /// Entering, and saying we are awake while we are here.
  ///
  /// `reportActivity` earns its place only now: an observer had no business
  /// claiming to be active, but a participant that never reports goes idle and
  /// stops looking present to the people it is talking to.
  List<Map<String, Object?>> _enterFrames(String spaceUserId) => [
        {
          'type': 'Action',
          'txnId': _txnId(),
          'action': 'enterSpace',
          'args': ['SpaceUser', spaceUserId],
        },
        {
          'type': 'Action',
          'txnId': _txnId(),
          'action': 'reportActivity',
          'args': [
            'Connection',
            null,
            {'isActive': true},
          ],
        },
      ];

  /// Enters late, when the handshake could not.
  ///
  /// A configured space id carries no `spaceUserId`, so on that path the first
  /// thing that can tell us who we are is the `Connection` row inside the state
  /// dump. Sent once per connection — `_entered` is reset on every connect, and
  /// entering twice on one socket would increment `numTimesEnteredSpace` twice
  /// for no benefit.
  void _maybeEnter() {
    if (_entered) return;
    final self = reader.selfId;
    if (self == null) return;
    final ws = _ws;
    if (ws == null || ws.readyState != WebSocket.open) return;

    _entered = true;
    try {
      for (final frame in _enterFrames(self)) {
        ws.add(msgpackEncode(frame));
      }
      _log('direct: entered space as $self');
    } on Object catch (error) {
      // Not fatal: we are subscribed and reading either way, and the next
      // connection gets another go.
      _entered = false;
      _log('direct: could not enter the space: $error');
    }
  }

  void _heartbeat() {
    final ws = _ws;
    if (ws == null || ws.readyState != WebSocket.open) return;
    try {
      ws.add(msgpackEncode({
        'type': 'Heartbeat',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'origin': 'Client',
      }));
    } on Object {
      // A failed heartbeat means the socket is going; `onDone` handles it.
    }
  }

  void _onFrame(Object? data) {
    if (data is! List<int>) return; // Text on this socket would not be ours.
    Object? frame;
    try {
      frame = msgpackDecode(data is Uint8List ? data : Uint8List.fromList(data));
    } on Object {
      // Not msgpack. Should not happen here, but never throw in a message handler.
      return;
    }
    if (frame is! Map<String, Object?>) return;
    _frames++;
    if (reader.ingest(frame)) _dirty = true;

    // The state dump is what names us, so this is the first moment the late path
    // can enter. Cheap to ask: it returns immediately once done.
    _maybeEnter();

    // Interactions go out at once rather than waiting for the publish window.
    // Coalescing exists because nobody needs every intermediate position; a wave is
    // a single deliberate act and there is nothing to coalesce it with.
    if (_interactions.isClosed) return;
    for (final event in reader.takePending()) {
      _interactions.add(event);
    }
  }

  void _flush() {
    if (_frames > 0) {
      if (hasState) {
        // Deliberately *not* the frame count. A status whose detail changes four
        // times a second would fill the UI's own history with noise; the user count
        // changes rarely and means something.
        _setHealth(true, '${reader.userCount} space users');
      } else if (_handshakeAt != null &&
          DateTime.now().difference(_handshakeAt!) >= _handshakeGrace) {
        // Frames arriving but still no state means the handshake was not accepted —
        // Gather stays silent rather than rejecting, so say so.
        _setHealth(
          false,
          'connected but holding no state ($_frames frames, heartbeats only) — '
          'the handshake was not accepted',
        );
      }
      // Inside the grace window we leave the status alone: a server heartbeat
      // routinely arrives before the first FullStateChunk.
    }
    if (!_dirty) return;
    _dirty = false;
    if (!_rosters.isClosed) _rosters.add(reader.roster());
  }
}

final _random = Random();

/// A v4-shaped transaction id.
///
/// Only has to be unique within one connection — Gather keys `actionReturns` by it
/// and we never read them back — so `Random` is plenty and avoids a dependency.
String _txnId() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}'
      '-${hex.substring(16, 20)}-${hex.substring(20)}';
}
