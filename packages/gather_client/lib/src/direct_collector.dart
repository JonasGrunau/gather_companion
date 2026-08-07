/// Reads presence by connecting to Gather ourselves, from the phone.
///
/// A port of `bridge/lib/direct.js`. The bridge opens this connection on the Mac;
/// this opens the same one from the app, which is what lets the app stop depending
/// on the bridge being reachable at all.
///
/// ## Observer mode, and why this is safe
///
/// `loadSpaceUser` materialises our SpaceUser and starts the state dump.
/// `enterSpace` is a *separate* action, and it is what actually puts an avatar in
/// the room. **We never send it.** The result is a connection with
/// `Connection.entered: false` that receives the complete roster while being
/// invisible to everyone in the space.
///
/// Two connections of your own do not fight: `Connection` is per-connection but
/// `SpaceUser` is per-person-per-space, so the bridge's observer, the desktop
/// client and this one all drive the same avatar. Measured 2026-08-06: neither an
/// observer connection nor an entered one disturbed the desktop client's socket.
///
/// `enterSpace` is omitted because it is **unnecessary and not free**, not because
/// it is dangerous: entering increments `numTimesEnteredSpace` on every reconnect
/// and marks the user present for idle and availability purposes. A collector that
/// only reads should touch neither.
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

  Map<String, Object?> stats() => {
        ...reader.stats(),
        'frames': _frames,
        'connects': _connects,
        'spaceId': spaceId,
        'authUserId': reader.authUserId,
        'entered': false,
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
    final ws = _ws;
    if (ws == null || ws.readyState != WebSocket.open) {
      return (ok: false, detail: 'not connected to Gather');
    }
    final self = reader.selfId;
    if (self == null) {
      return (ok: false, detail: 'do not know which avatar is ours yet');
    }
    if (!x.isFinite || !y.isFinite) {
      return (ok: false, detail: 'teleport needs finite coordinates');
    }

    try {
      ws.add(msgpackEncode({
        'type': 'Action',
        'txnId': _txnId(),
        'action': 'teleport',
        // Flat x/y — `{position:{x,y}}` is rejected — and `direction` is required
        // even though teleporting does not pass through any tiles.
        'args': [
          'SpaceUser',
          self,
          {'x': x, 'y': y, 'direction': direction},
        ],
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

  /// Which space to watch.
  ///
  /// Prefers configuration — the id handed over at pairing — then asks the API.
  /// The bridge can also read the space the desktop client last opened off disk;
  /// the phone has no such shortcut, so the REST call is the fallback rather than
  /// the last resort.
  Future<String?> _resolveSpaceId() async {
    if (_configuredSpaceId != null && _configuredSpaceId.isNotEmpty) {
      return _configuredSpaceId;
    }
    final spaces = await _auth.recentSpaces();
    return spaces.isEmpty ? null : spaces.first.id;
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
    final String? resolvedSpace;
    try {
      token = await _auth.idToken();
      resolvedSpace = await _resolveSpaceId();
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

    if (resolvedSpace == null) {
      _setHealth(false, 'no space to watch — open a space in Gather once');
      _scheduleRetry();
      return;
    }
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
    _log('direct: connected to space $resolvedSpace as observer');

    try {
      for (final frame in _handshake(token, resolvedSpace)) {
        ws.add(msgpackEncode(frame));
      }
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
        // use. Observer connections do not trigger it, so seeing it here would mean
        // Gather's rules changed and is worth saying out loud.
        final suffix = code == 4031 ? ' — duplicate connection rejected' : '';
        _setHealth(false, 'game socket closed ($code)$suffix');
        _scheduleRetry();
      },
      cancelOnError: false,
    );
  }

  /// The frames that get us subscribed as an observer.
  ///
  /// Deliberately does not include `enterSpace`. That is the line between watching
  /// a space and being in it, and this collector only ever watches.
  ///
  /// A wrong-shaped `Authenticate` is the trap: Gather does not reject it, it simply
  /// never replies and keeps heartbeating, so the failure looks like a network
  /// problem rather than an auth one. These shapes were captured off the desktop
  /// client's own outbound frames, and `msgpack_test.dart` pins the bytes.
  List<Map<String, Object?>> _handshake(String token, String space) => [
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
      ];

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
        _setHealth(true, '${reader.userCount} space users (observer)');
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
