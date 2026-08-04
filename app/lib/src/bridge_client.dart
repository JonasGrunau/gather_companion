import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gather_events/gather_events.dart';
import 'package:web_socket_channel/io.dart';

import 'settings.dart';

enum LinkState { idle, connecting, live, retrying }

class LinkStatus {
  const LinkStatus(this.state, [this.detail]);

  final LinkState state;
  final String? detail;

  bool get isLive => state == LinkState.live;
}

/// Talks to the Mac-side bridge over a single WebSocket.
///
/// Two things make this more than a socket wrapper:
///
///  * **Catch-up by sequence.** Every event the bridge publishes carries a
///    monotonic `seq`, and reconnecting with `?since=<lastSeq>` replays exactly
///    what was missed. An iPhone drops the socket every time it is locked, so
///    without this the event log would quietly lose whatever happened while the
///    screen was off.
///  * **Ping-driven liveness.** A WebSocket to a sleeping Mac does not error, it
///    just goes silent. `pingInterval` makes the socket fail fast so the retry
///    loop can do its job.
class BridgeClient {
  // A named parameter cannot be a private initializing formal, so the field is
  // assigned the long way round.
  // ignore: prefer_initializing_formals
  BridgeClient({required BridgeSettings settings}) : _settings = settings;

  BridgeSettings _settings;

  final _events = StreamController<GatherEvent>.broadcast();
  final _snapshots = StreamController<PresenceSnapshot>.broadcast();
  final _status = StreamController<LinkStatus>.broadcast();

  Stream<GatherEvent> get events => _events.stream;
  Stream<PresenceSnapshot> get snapshots => _snapshots.stream;
  Stream<LinkStatus> get status => _status.stream;

  IOWebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _retry;
  Duration _backoff = const Duration(seconds: 1);
  bool _disposed = false;

  /// Highest sequence number we have seen, so a reconnect can resume from it.
  int lastSeq = 0;

  LinkStatus _current = const LinkStatus(LinkState.idle);
  LinkStatus get currentStatus => _current;

  void updateSettings(BridgeSettings settings) {
    _settings = settings;
    lastSeq = 0;
    reconnect();
  }

  void _emitStatus(LinkStatus status) {
    _current = status;
    if (!_status.isClosed) _status.add(status);
  }

  Future<void> connect() async {
    if (_disposed || !_settings.isComplete) return;
    _retry?.cancel();
    await _teardown();

    _emitStatus(const LinkStatus(LinkState.connecting));

    try {
      final channel = IOWebSocketChannel.connect(
        _settings.wsUri(since: lastSeq),
        pingInterval: const Duration(seconds: 20),
        connectTimeout: const Duration(seconds: 8),
      );
      _channel = channel;
      _sub = channel.stream.listen(
        _onFrame,
        onError: (Object error) => _scheduleRetry(error.toString()),
        onDone: () => _scheduleRetry('bridge closed the connection'),
        cancelOnError: true,
      );
    } catch (error) {
      _scheduleRetry(error.toString());
    }
  }

  void reconnect() {
    _backoff = const Duration(seconds: 1);
    connect();
  }

  /// Recent history, for a client that has never connected before.
  ///
  /// The socket only replays from a sequence number, so a first connection would
  /// otherwise open on an empty feed even when the bridge has been watching all
  /// morning. Bounded on purpose: this is context, not an archive.
  Future<List<GatherEvent>> recentHistory({int limit = 40}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.getUrl(_settings.httpUri('/events'));
      final response = await request.close().timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) return const [];
      final body = jsonDecode(await response.transform(utf8.decoder).join());
      if (body is! Map) return const [];

      final rows = (body['events'] as List?) ?? const [];
      final out = <GatherEvent>[];
      for (final row in rows.reversed.take(limit)) {
        if (row is! Map) continue;
        final seq = (row['seq'] as num?)?.toInt() ?? 0;
        if (seq > lastSeq) lastSeq = seq;
        final event = (row['event'] as Map?)?.cast<String, Object?>();
        if (event != null) out.add(GatherEvent.fromJson(event));
      }
      return out;
    } catch (_) {
      // Priming is a nicety; failing it must not stop the socket from working.
      return const [];
    } finally {
      client.close(force: true);
    }
  }

  void _onFrame(dynamic raw) {
    if (raw is! String) return;
    Map<String, Object?> frame;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      frame = decoded.cast<String, Object?>();
    } catch (_) {
      return;
    }

    // The first frame after a successful handshake proves the token was accepted.
    if (!_current.isLive) {
      _backoff = const Duration(seconds: 1);
      _emitStatus(const LinkStatus(LinkState.live));
    }

    final seq = (frame['seq'] as num?)?.toInt() ?? 0;
    if (seq > lastSeq) lastSeq = seq;

    switch (frame['kind']) {
      case 'snapshot':
        final body = (frame['snapshot'] as Map?)?.cast<String, Object?>();
        if (body != null) _snapshots.add(PresenceSnapshot.fromJson(body));
      case 'event':
        final body = (frame['event'] as Map?)?.cast<String, Object?>();
        if (body != null) _events.add(GatherEvent.fromJson(body));
    }
  }

  void _scheduleRetry(String detail) {
    if (_disposed) return;
    _teardown();
    _emitStatus(LinkStatus(LinkState.retrying, detail));

    _retry?.cancel();
    _retry = Timer(_backoff, connect);
    // Cap the backoff: the Mac waking up should be picked up quickly, and the
    // socket is cheap.
    _backoff = Duration(
      milliseconds: (_backoff.inMilliseconds * 2).clamp(1000, 15000),
    );
  }

  Future<void> _teardown() async {
    final sub = _sub;
    final channel = _channel;
    _sub = null;
    _channel = null;
    await sub?.cancel();
    await channel?.sink.close();
  }

  Future<void> dispose() async {
    _disposed = true;
    _retry?.cancel();
    await _teardown();
    await _events.close();
    await _snapshots.close();
    await _status.close();
  }
}
