/// Talking to Gather's media plane.
///
/// The game socket carries presence. Media is a **separate protocol on separate
/// sockets**: Socket.IO rather than msgpack, at
/// `wss://router.v2.gather.town` for SFU assignment and at a per-node
/// `wss://sfu-v2.<region>.prod.aws.gather.town/ip-<addr>` for the media itself.
/// Captured off the desktop client 2026-08-13 with `tool/probe-sfu.mjs`; the
/// message tables are in `docs/gather-api.md`.
///
/// This class is the transport and nothing more. It knows how to authenticate,
/// how to ask a question and match the answer, and how to hand on the things the
/// server says unprompted. It does not know what a producer is. That keeps the
/// reverse-engineered half — the half most likely to be wrong — in a package
/// `dart test` can exercise in seconds with no device and no camera.
///
/// ## Three things that are not guesses
///
/// **Auth is the Socket.IO CONNECT packet.** `{spaceId, token}`, where `token` is
/// the same Firebase ID token the game socket uses. Not a header, not a query
/// parameter, and there is no separate "video token" to fetch — which is why
/// [GatherAuth] is enough to get in.
///
/// **The correlation key is the Socket.IO ack id.** Gather's `sendWithResponse`
/// is not a bespoke mechanism layered on a socket; it is `emit(name, args, cb)`.
/// So [sendWithResponse] is a thin wrapper over `emitWithAckAsync` rather than the
/// hand-rolled pending-completer map the game socket would have needed.
///
/// **Most calls carry a sequence number, but not all.** The envelope is
/// `{wsSequenceNumber, zodData}` — except for [_bareMethods], which send their
/// arguments unwrapped. Wrapping an exempt call, or failing to wrap a normal one,
/// is the kind of mistake Gather answers with silence rather than an error.
///
/// ## Reconnection is ours, not the library's
///
/// `reconnection` is disabled deliberately, mirroring the desktop client. An ID
/// token lives about an hour, so a socket that silently reconnected would
/// eventually re-present a dead credential and fail in a way that looks like a
/// network fault. Every connection here mints a fresh token first.
library;

import 'dart:async';
import 'dart:math';

import 'package:socket_io_client/socket_io_client.dart' as io;

import 'gather_auth.dart';

/// The assignment service. Answers "which node carries this person's media?".
const gatherSfuRouter = 'wss://router.v2.gather.town';

/// Socket.IO's own path. Gather does not customise it.
const _socketIoPath = '/socket.io/';

/// Calls whose arguments are sent bare, with no `{wsSequenceNumber, zodData}`.
///
/// Measured, not assumed: `get-addr` and `unsubscribe` went out as plain
/// `{srcId, srcStreamId}` while everything else on the same socket was wrapped.
/// `addrs` and `reassign` are on the bundle's exemption list too.
const _bareMethods = {'get-addr', 'unsubscribe', 'reassign', 'addrs'};

const _defaultTimeout = Duration(seconds: 15);
const _maxBackoff = Duration(seconds: 30);

/// Something the server said without being asked.
///
/// `consume-try` is the important one — it carries a peer's entire
/// `producerIdMap`, so it is a full-state announcement rather than a delta and
/// callers should reconcile against it rather than treat it as an event.
class SfuNotification {
  const SfuNotification(this.name, this.data);

  final String name;
  final Map<String, Object?> data;

  @override
  String toString() => 'SfuNotification($name, $data)';
}

/// Whether the socket is usable, and what to say if not.
///
/// Mirrors `CollectorStatus` deliberately: the app already knows how to render
/// one of these, and the honesty rule is the same — report unhealthy while
/// connected-but-not-joined rather than implying media is flowing.
class SfuStatus {
  const SfuStatus({required this.healthy, this.detail, this.needsPairing = false});

  final bool healthy;
  final String? detail;

  /// The credential is dead and only re-pairing will fix it.
  final bool needsPairing;

  @override
  String toString() => 'SfuStatus($healthy, $detail)';
}

class SfuException implements Exception {
  const SfuException(this.message);
  final String message;

  @override
  String toString() => 'SfuException($message)';
}

/// One Socket.IO connection to a router or an SFU node.
///
/// A call spans several of these — one router plus one per media node, since
/// peers can be spread across nodes — so this is deliberately per-socket and
/// holds no opinion about how many exist.
class SfuSignalling {
  SfuSignalling({
    required GatherAuth auth,
    required String url,
    required String spaceId,
    String? sessionId,
    io.Socket Function(String uri, Map<String, dynamic> options)? connect,
    void Function(String)? log,
    // A named parameter cannot be a private initializing formal — `this._url`
    // would make the argument label private too — so these are assigned the long
    // way round, same as `DirectCollector`.
  })  :
        // ignore: prefer_initializing_formals
        _auth = auth,
        // ignore: prefer_initializing_formals
        _url = url,
        // ignore: prefer_initializing_formals
        _spaceId = spaceId,
        // ignore: prefer_initializing_formals
        _sessionId = sessionId,
        _connect = connect ?? _defaultConnect,
        _log = log ?? _noop;

  static void _noop(String _) {}

  static io.Socket _defaultConnect(String uri, Map<String, dynamic> options) =>
      io.io(uri, options);

  final GatherAuth _auth;
  final String _url;
  final String _spaceId;

  /// Overridable so tests can point at a fake Socket.IO server.
  final io.Socket Function(String uri, Map<String, dynamic> options) _connect;
  final void Function(String) _log;

  /// A per-connection nonce the SFU URL carries as `?sessionId=`.
  ///
  /// Client-generated: it appears nowhere in any inbound frame, and two captured
  /// connections produced two unrelated UUIDs. Minted here when not supplied.
  final String? _sessionId;

  io.Socket? _socket;
  Timer? _retryTimer;
  Duration _backoff = const Duration(seconds: 1);
  bool _stopped = false;
  bool _connected = false;
  int _sequence = 0;

  /// Frames the server sent that this client does not recognise.
  ///
  /// Counted rather than dropped, for the same reason `GameProtocolReader.stats()`
  /// counts unknown frames: a protocol change should show up as a number going up,
  /// not as a feature quietly not working.
  int unknownEvents = 0;

  final _notifications = StreamController<SfuNotification>.broadcast();
  final _statuses = StreamController<SfuStatus>.broadcast();

  /// Server-pushed messages, published immediately rather than coalesced.
  Stream<SfuNotification> get notifications => _notifications.stream;
  Stream<SfuStatus> get statuses => _statuses.stream;

  bool get connected => _connected;
  String get url => _url;

  /// Opens the socket and authenticates. Safe to call again after a failure.
  Future<void> start() async {
    _stopped = false;
    await _open();
  }

  Future<void> stop() async {
    _stopped = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    _teardown();
  }

  Future<void> dispose() async {
    await stop();
    await _notifications.close();
    await _statuses.close();
  }

  /// Asks a question and waits for the ack that answers it.
  ///
  /// [args] is the `zodData` payload; the envelope is added here unless [method]
  /// is exempt. The reply is the ack's first argument, which for every measured
  /// call is either a map (`consume` → `{id, producerId, …}`) or an empty list
  /// (`consume-resume` → `[]`).
  Future<Map<String, Object?>> sendWithResponse(
    String method, [
    Map<String, Object?> args = const {},
    Duration timeout = _defaultTimeout,
  ]) async {
    final socket = _socket;
    if (socket == null || !_connected) {
      throw SfuException('not connected to $_url');
    }

    // NOT `emitWithAckAsync`, and this is not a style choice.
    //
    // `Socket.onack` dispatches with `Function.apply(ack, args)`, so an ack whose
    // payload is `[]` calls the callback with **zero** arguments — and
    // `emitWithAckAsync`'s internal callback requires one. It throws, the
    // completer is never completed, and the call hangs until it times out.
    //
    // That is not an edge case here. Measured against Gather, six of the twelve
    // client calls answer with an empty array: `consume-request`,
    // `consume-created`, `consume-pause`, `consume-resume`, `consume-set-spatial`
    // and `set-player-conversation-metadata`. Half the protocol would hang.
    //
    // A callback whose parameters are all optional survives every arity the
    // library can produce: none, one value, or one list when the ack carried
    // several.
    final completer = Completer<Map<String, Object?>>();
    try {
      socket.emitWithAck(
        method,
        _envelope(method, args),
        ack: ([Object? first, Object? second]) {
          if (!completer.isCompleted) completer.complete(_asMap(first));
        },
      );
    } on Object catch (error) {
      throw SfuException('$method failed: $error');
    }

    return completer.future.timeout(
      timeout,
      // Distinguished from a refusal on purpose: Gather's failure mode is silence,
      // so a caller that cannot tell "no" from "nothing" will hang a call forever.
      onTimeout: () =>
          throw SfuException('$method timed out after ${timeout.inSeconds}s'),
    );
  }

  /// Says something without expecting an answer — `consume-allow`, `produce-close`.
  void emit(String method, [Map<String, Object?> args = const {}]) {
    final socket = _socket;
    if (socket == null || !_connected) return;
    socket.emit(method, _envelope(method, args));
  }

  /// `{wsSequenceNumber, zodData}`, or the bare payload for an exempt method.
  Object _envelope(String method, Map<String, Object?> args) {
    if (_bareMethods.contains(method)) return args;
    return {'wsSequenceNumber': ++_sequence, 'zodData': args};
  }

  Future<void> _open() async {
    if (_stopped) return;
    _teardown();

    final String token;
    try {
      token = await _auth.idToken();
    } on GatherAuthException catch (error) {
      _setStatus(false, 'Gather sign-in failed: ${error.message}',
          needsPairing: error.permanent);
      if (!error.permanent) _scheduleRetry();
      return;
    }
    if (_stopped) return;

    final options = io.OptionBuilder()
        .setPath(_socketIoPath)
        // Websocket only. Gather never polls, and allowing the polling fallback
        // would send the credential over a series of HTTP requests instead.
        .setTransports(['websocket'])
        .disableAutoConnect()
        .disableReconnection()
        .setAuth({'spaceId': _spaceId, 'token': token})
        .setQuery({'sessionId': _sessionId ?? _newSessionId()})
        .build();

    final io.Socket socket;
    try {
      socket = _connect(_url, options);
    } on Object catch (error) {
      _setStatus(false, 'could not build the SFU socket: $error');
      _scheduleRetry();
      return;
    }
    _socket = socket;

    socket.onConnect((_) {
      if (_socket != socket) return;
      _connected = true;
      _backoff = const Duration(seconds: 1);
      _setStatus(true, 'connected');
      _log('sfu: connected to $_url');
    });

    socket.onConnectError((Object? error) {
      if (_socket != socket) return;
      // A rejected credential arrives here rather than as a close code.
      _setStatus(false, 'SFU refused the connection: $error');
      _connected = false;
      _scheduleRetry();
    });

    socket.onDisconnect((_) {
      if (_socket != socket) return;
      _connected = false;
      _setStatus(false, 'SFU socket closed');
      _scheduleRetry();
    });

    // Everything the server says unprompted. Registering one catch-all rather
    // than a handler per message means a new server-side event shows up in
    // `unknownEvents` instead of vanishing.
    socket.onAny((String event, Object? data) {
      if (_socket != socket) return;
      if (_notifications.isClosed) return;
      _notifications.add(SfuNotification(event, _asMap(data)));
    });

    socket.connect();
    _setStatus(false, 'connecting');
  }

  void _teardown() {
    final socket = _socket;
    _socket = null;
    _connected = false;
    if (socket == null) return;
    try {
      socket
        ..clearListeners()
        ..dispose();
    } on Object {
      /* already gone */
    }
  }

  void _scheduleRetry() {
    if (_stopped || _retryTimer != null) return;
    final wait = _backoff;
    final next = _backoff * 2;
    _backoff = next > _maxBackoff ? _maxBackoff : next;
    _retryTimer = Timer(wait, () {
      _retryTimer = null;
      unawaited(_open());
    });
  }

  void _setStatus(bool healthy, String? detail, {bool needsPairing = false}) {
    if (_statuses.isClosed) return;
    _statuses.add(
      SfuStatus(healthy: healthy, detail: detail, needsPairing: needsPairing),
    );
  }
}

/// Server payloads arrive as `[{…}]` or `{…}` depending on the emitter.
Map<String, Object?> _asMap(Object? data) {
  if (data is Map) return data.cast<String, Object?>();
  if (data is List && data.isNotEmpty && data.first is Map) {
    return (data.first as Map).cast<String, Object?>();
  }
  return const {};
}

final _random = Random();

/// A v4-shaped id, for the SFU URL's `sessionId`.
///
/// The same shape and reasoning as `direct_collector.dart`'s `_txnId`: it only
/// has to be unique per connection, so `Random` avoids a dependency.
String _newSessionId() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}'
      '-${hex.substring(16, 20)}-${hex.substring(20)}';
}
