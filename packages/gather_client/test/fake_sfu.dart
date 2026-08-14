/// A Socket.IO v4 server, just enough of one to test [SfuSignalling] against.
///
/// The counterpart of `fake_gather.dart`, and built on the same principle stated
/// in its header: a real `HttpServer` doing a real WebSocket upgrade, so the
/// client runs its production socket path. Mocking `io.Socket` would leave the
/// framing — the reverse-engineered part, the part most likely to be wrong —
/// untested.
///
/// It speaks the wire format directly rather than importing a server library,
/// because the format *is* what is under test. Frames captured off Gather
/// 2026-08-13 look exactly like the ones below; see `docs/gather-api.md`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Engine.IO handshake. `pingInterval`/`pingTimeout` are the server's own clock;
/// generous here so a slow test machine never trips them.
const _open = '0{"sid":"fake-eio","upgrades":[],"pingInterval":25000,"pingTimeout":20000}';

class FakeSfuConnection {
  FakeSfuConnection(this.socket, this.uri);

  final WebSocket socket;
  final Uri uri;

  /// The CONNECT auth payload — `{spaceId, token}` — once it arrives.
  Map<String, Object?>? auth;

  /// Every event the client emitted, in order: `(name, ackId, data)`.
  final List<({String name, int? ackId, Object? data})> received = [];

  final _frames = StreamController<({String name, int? ackId, Object? data})>.broadcast();

  /// Each event as it arrives.
  ///
  /// Tests await this rather than polling [received]. Polling with a periodic
  /// timer leaks timers across tests and turns a real failure into a confusing
  /// one somewhere else — which is exactly what it did here before.
  Stream<({String name, int? ackId, Object? data})> get frames => _frames.stream;

  /// Waits until [count] events have arrived, then hands back all of them.
  Future<List<({String name, int? ackId, Object? data})>> waitForFrames(
    int count, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (received.length >= count) return received;
    await frames
        .take(count - received.length)
        .drain<void>()
        .timeout(timeout, onTimeout: () => throw StateError('only got $received'));
    return received;
  }

  void send(String frame) {
    if (socket.readyState == WebSocket.open) socket.add(frame);
  }

  /// `43<ackId>[payload]` — answer a request.
  void ack(int ackId, Object? payload) => send('43$ackId${jsonEncode([payload])}');

  /// `42["name",data]` — say something unprompted, as `consume-try` arrives.
  void push(String name, Object? data) => send('42${jsonEncode([name, data])}');

  /// `2` — Engine.IO ping, which the client must answer with `3`.
  void ping() => send('2');
}

class FakeSfuServer {
  FakeSfuServer._(this._server);

  final HttpServer _server;
  final _connected = StreamController<FakeSfuConnection>.broadcast();

  /// Fires as each client completes the Socket.IO CONNECT handshake.
  Stream<FakeSfuConnection> get onConnected => _connected.stream;

  final List<FakeSfuConnection> connections = [];

  /// When set, CONNECT is refused with this reason instead of accepted.
  String? refuseWith;

  /// When true, CONNECT is neither accepted nor refused — the socket stays open
  /// and silent. This is the half-open case a refusal does not cover: the TCP
  /// connection succeeds, so nothing errors, and a client that mistakes "the
  /// socket opened" for "the socket works" hangs here rather than failing.
  bool stallConnect = false;

  String get url => 'http://127.0.0.1:${_server.port}';

  /// The address shaped like one the **router** hands out, rather than a bare
  /// origin: `wss://…:443/ip-<dashed-ip>`.
  ///
  /// Both halves are the parts that broke in the field — the explicit default
  /// port and the `/ip-…` prefix — so anything testing a media node should use
  /// this and not [url]. The port here is the real one, because the fake is not
  /// on 443; the prefix and the `wss` scheme are what matter.
  String get nodeUrl => 'ws://127.0.0.1:${_server.port}/ip-127-0-0-1';

  static Future<FakeSfuServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeSfuServer._(server);
    unawaited(fake._listen());
    return fake;
  }

  Future<void> _listen() async {
    await for (final request in _server) {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        continue;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      final conn = FakeSfuConnection(socket, request.uri);
      connections.add(conn);
      conn.send(_open);

      socket.listen(
        (Object? data) => _onFrame(conn, data),
        onDone: () {},
        onError: (Object _) {},
        cancelOnError: false,
      );
    }
  }

  void _onFrame(FakeSfuConnection conn, Object? data) {
    if (data is! String || data.isEmpty) return;

    // `3` — the client answering our ping. Nothing to do but notice it.
    if (data == '3') return;
    // `2` — a client-initiated ping wants a pong.
    if (data == '2') return conn.send('3');
    if (!data.startsWith('4')) return;

    final rest = data.substring(1);
    if (rest.isEmpty) return;

    // CONNECT: `40{auth}`.
    if (rest[0] == '0') {
      final body = rest.substring(1);
      conn.auth = body.isEmpty
          ? const {}
          : (jsonDecode(body) as Map).cast<String, Object?>();
      if (stallConnect) return;
      final refusal = refuseWith;
      if (refusal != null) {
        conn.send('44${jsonEncode({'message': refusal})}');
        return;
      }
      conn.send('40${jsonEncode({'sid': 'fake-sid'})}');
      if (!_connected.isClosed) _connected.add(conn);
      return;
    }

    // EVENT: `42<ackId>["name",data]`.
    if (rest[0] != '2') return;
    var cursor = 1;
    final digits = RegExp(r'^\d+').firstMatch(rest.substring(cursor));
    int? ackId;
    if (digits != null) {
      ackId = int.parse(digits.group(0)!);
      cursor += digits.group(0)!.length;
    }
    final payload = jsonDecode(rest.substring(cursor));
    if (payload is! List || payload.isEmpty) return;
    final frame = (
      name: payload.first as String,
      ackId: ackId,
      data: payload.length > 1 ? payload[1] : null,
    );
    conn.received.add(frame);
    if (!conn._frames.isClosed) conn._frames.add(frame);
  }

  Future<void> close() async {
    await _connected.close();
    for (final c in connections) {
      await c._frames.close();
      await c.socket.close();
    }
    await _server.close(force: true);
  }
}
