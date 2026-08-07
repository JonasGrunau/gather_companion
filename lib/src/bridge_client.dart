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

/// Talks to the computer-side bridge over a single WebSocket.
///
/// Two things make this more than a socket wrapper:
///
///  * **Catch-up by sequence.** Every event the bridge publishes carries a
///    monotonic `seq`, and reconnecting with `?since=<lastSeq>` replays exactly
///    what was missed. A phone drops the socket every time it is locked, so
///    without this the event log would quietly lose whatever happened while the
///    screen was off.
///  * **Ping-driven liveness.** A WebSocket to a sleeping computer does not error, it
///    just goes silent. `pingInterval` makes the socket fail fast so the retry
///    loop can do its job.
///  * **One socket, enforced by generation.** Resuming, pulling to refresh and a
///    firing retry timer all want to reconnect, and on a phone they routinely
///    want it at the same moment. [_generation] is what makes the last one win;
///    see [_abandon] for what goes wrong without it.
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

  /// Bumped every time a socket is given up on. A socket only speaks for the
  /// client while its generation is still the current one.
  int _generation = 0;

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

  /// Opens a socket, replacing whatever was there.
  ///
  /// Deliberately synchronous all the way to `_sub`. It used to `await` the
  /// teardown of the old socket first, which opened a window: a second
  /// `connect()` arriving inside that window found `_channel` already nulled,
  /// tore down nothing, and both calls then went on to open a socket. The
  /// second one won the fields and the first was orphaned — still open, still
  /// subscribed, invisible to `dispose()`. It cost nothing until it died, at
  /// which point its `onDone` reached back through these very callbacks and
  /// tore down the *healthy* socket, which is what "reopen the app and it can't
  /// connect" actually was. Two overlapping resumes are ordinary on iOS, so the
  /// window was hit routinely and the orphans accumulated one per launch.
  void connect() {
    if (_disposed || !_settings.isComplete) return;
    _retry?.cancel();
    _retry = null;
    _abandon();
    final generation = _generation;

    _emitStatus(const LinkStatus(LinkState.connecting));

    try {
      final channel = IOWebSocketChannel.connect(
        _settings.wsUri(since: lastSeq),
        pingInterval: const Duration(seconds: 20),
        connectTimeout: const Duration(seconds: 8),
      );
      _channel = channel;
      _sub = channel.stream.listen(
        (raw) {
          if (generation == _generation) _onFrame(raw);
        },
        onError: (Object error) {
          if (generation == _generation) _scheduleRetry(error.toString());
        },
        onDone: () {
          if (generation == _generation) _scheduleRetry('bridge closed the connection');
        },
        cancelOnError: true,
      );
    } catch (error) {
      if (generation == _generation) _scheduleRetry(error.toString());
    }
  }

  void reconnect() {
    _backoff = const Duration(seconds: 1);
    connect();
  }

  /// Resolves when the link is live again, or when [timeout] runs out.
  ///
  /// Pull-to-refresh needs something real to await. Without this the refresh
  /// future completed on the next microtask and the indicator snapped shut
  /// before the socket had even opened, which reads as a stutter rather than as
  /// a refresh.
  Future<void> whenLive({Duration timeout = const Duration(seconds: 6)}) async {
    if (_current.isLive || _disposed) return;
    try {
      await status.firstWhere((s) => s.isLive).timeout(timeout);
    } catch (_) {
      // Timed out, or the client was disposed mid-wait. Either way the caller
      // only wanted to know when to stop spinning.
    }
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

  /// Switches party mode on or off.
  ///
  /// Returns null on success, or a sentence explaining the refusal. The bridge
  /// declines rather than pretending when it cannot hop — no Gather connection,
  /// or it does not yet know which avatar is yours — and that reason is worth
  /// putting in front of whoever pressed the button.
  ///
  /// The resulting state is not read from here: it arrives on the next snapshot,
  /// which is the same path used when the bridge stops party mode by itself.
  Future<String?> setParty(bool on) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.postUrl(
        _settings.httpUri('/party', {'on': on ? '1' : '0'}),
      );
      final response = await request.close().timeout(const Duration(seconds: 6));
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode == 200) return null;

      final body = jsonDecode(text);
      final detail = body is Map ? body['detail'] as String? : null;
      return detail ?? 'The bridge said no (${response.statusCode}).';
    } on TimeoutException {
      return 'The bridge did not answer.';
    } catch (_) {
      return 'Could not reach the bridge.';
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
    _abandon();
    _emitStatus(LinkStatus(LinkState.retrying, detail));

    _retry?.cancel();
    _retry = Timer(_backoff, connect);
    // Cap the backoff: the computer waking up should be picked up quickly, and the
    // socket is cheap.
    _backoff = Duration(
      milliseconds: (_backoff.inMilliseconds * 2).clamp(1000, 15000),
    );
  }

  /// Gives up on the current socket and makes it stop counting.
  ///
  /// The generation bump is the load-bearing part: it fires before anything
  /// asynchronous, so a socket that is already mid-failure cannot report the
  /// failure against its replacement. Closing is not awaited on purpose — a
  /// socket we have stopped listening to must not be able to delay, or fail,
  /// the one taking its place. On a phone this is usually a socket the OS
  /// suspended, and how long its close takes is not our business.
  void _abandon() {
    _generation++;
    final sub = _sub;
    final channel = _channel;
    _sub = null;
    _channel = null;
    if (sub != null) unawaited(sub.cancel());
    if (channel != null) unawaited(_closeQuietly(channel));
  }

  static Future<void> _closeQuietly(IOWebSocketChannel channel) async {
    try {
      await channel.sink.close();
    } catch (_) {
      // Already gone. There is nobody left to tell.
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _retry?.cancel();
    _abandon();
    await _events.close();
    await _snapshots.close();
    await _status.close();
  }
}
