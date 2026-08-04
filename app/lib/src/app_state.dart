import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:gather_events/gather_events.dart';

import 'bridge_client.dart';
import 'notifications.dart';
import 'pairing.dart';
import 'relevance.dart';
import 'settings.dart';

/// Everything the UI reads. One object, so the whole app is a single
/// `ListenableBuilder` away from being correct.
class AppState extends ChangeNotifier {
  AppState({Notifier? notifier}) : _notifier = notifier ?? Notifier();

  final Notifier _notifier;
  Notifier get notifier => _notifier;

  BridgeClient? _client;
  final _subs = <StreamSubscription<dynamic>>[];

  /// Newest first, so the list view needs no reversing.
  final List<GatherEvent> _log = [];
  static const _logLimit = 1000;

  BridgeSettings _settings = BridgeSettings.empty;
  PresenceSnapshot _snapshot = PresenceSnapshot.empty;
  LinkStatus _link = const LinkStatus(LinkState.idle);
  bool _loaded = false;

  /// Whether the ambient tier is on screen. Off by default: the point of the feed
  /// is the handful of things worth reading.
  bool _showEverything = false;

  String? _bridgeName;

  BridgeSettings get settings => _settings;
  PresenceSnapshot get snapshot => _snapshot;
  LinkStatus get link => _link;
  bool get isConfigured => _settings.isComplete;
  bool get isLoaded => _loaded;
  bool get showEverything => _showEverything;
  String? get bridgeName => _bridgeName;

  List<PlayerRef> get nearby {
    final list = _snapshot.players.where((p) => p.isNear).toList()
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return list;
  }

  List<PlayerRef> get followers =>
      _snapshot.players.where((p) => p.isFollowingMe).toList(growable: false);

  /// Whether the bridge currently has the high-fidelity collector attached. Shown
  /// in the UI, because it changes what a quiet screen means.
  bool get hasRichData => _snapshot.health.hasRichData;

  /// The feed, already classified and filtered.
  List<({GatherEvent event, EventLook look})> get feed {
    final out = <({GatherEvent event, EventLook look})>[];
    for (final event in _log) {
      final look = lookOf(event, nameFor);
      if (!_showEverything && look.relevance == Relevance.ambient) continue;
      out.add((event: event, look: look));
    }
    return out;
  }

  /// How many ambient events are being held back, so the toggle can say so.
  int get hiddenCount {
    if (_showEverything) return 0;
    return _log.where((e) => lookOf(e, nameFor).relevance == Relevance.ambient).length;
  }

  /// Development shortcut past the scanner: `--dart-define=GATHER_PAIR=host:port:token`.
  ///
  /// The simulator has no camera, so without this there is no way to reach the
  /// feed while working on it. Empty in any normal build.
  static const _devPair = String.fromEnvironment('GATHER_PAIR');

  Future<void> boot() async {
    _settings = await BridgeSettings.load();
    _bridgeName = await BridgeSettings.loadName();

    if (!_settings.isComplete && _devPair.isNotEmpty) {
      final parts = _devPair.split(':');
      if (parts.length == 3) {
        _settings = BridgeSettings(
          host: parts[0],
          port: int.tryParse(parts[1]) ?? BridgeSettings.defaultPort,
          token: parts[2],
        );
        _bridgeName = 'dev · ${parts[0]}';
      }
    }

    _loaded = true;
    await _notifier.init();
    notifyListeners();
    if (_settings.isComplete) _attach();
  }

  /// Trades a scanned or typed pairing code for the bridge's token.
  Future<String?> pair({required String host, required int port, required String code}) async {
    final result = await claimPairing(host: host, port: port, code: code);
    switch (result) {
      case PairFailure(:final message):
        return message;
      case PairSuccess(:final settings, :final name):
        _settings = settings;
        _bridgeName = name;
        await settings.save();
        await BridgeSettings.saveName(name);
        await _notifier.requestPermission();
        _log.clear();
        _snapshot = PresenceSnapshot.empty;
        notifyListeners();
        _attach();
        return null;
    }
  }

  Future<void> unpair() async {
    await BridgeSettings.clear();
    _settings = BridgeSettings.empty;
    _bridgeName = null;
    _snapshot = PresenceSnapshot.empty;
    _log.clear();
    _detach();
    notifyListeners();
  }

  void setShowEverything(bool value) {
    _showEverything = value;
    notifyListeners();
  }

  void reconnect() => _client?.reconnect();

  void clearLog() {
    _log.clear();
    notifyListeners();
  }

  /// Best available name for a player id, falling back to a short id.
  String nameFor(String id) {
    for (final player in _snapshot.players) {
      if (player.id == id) return player.label;
    }
    return id.length <= 8 ? id : id.substring(0, 8);
  }

  void _attach() {
    _detach();
    final client = BridgeClient(settings: _settings);
    _client = client;
    _subs
      ..add(client.snapshots.listen(_onSnapshot))
      ..add(client.events.listen(_onEvent))
      ..add(client.status.listen(_onStatus));
    client.connect();
    _primeHistory(client);
  }

  /// Fills the feed with recent history on a first connection, so the app does
  /// not open on an empty screen when the bridge has been running for hours.
  Future<void> _primeHistory(BridgeClient client) async {
    if (_log.isNotEmpty) return;
    final history = await client.recentHistory();
    if (_client != client || history.isEmpty) return;
    // Oldest last, matching the newest-first order the list view expects.
    for (final event in history) {
      _log.add(event);
    }
    notifyListeners();
  }

  /// Drops the current client, clearing the fields *synchronously*.
  ///
  /// The synchronous part matters. This used to be `async` with `_client = null`
  /// after an await, which meant the null landed a microtask *after* [_attach]
  /// had already installed the replacement — quietly wiping it. Everything that
  /// then checked `_client` broke without failing: history priming bailed out on
  /// its identity check, and the reconnect button became a no-op. Disposal itself
  /// can finish in the background; the bookkeeping cannot.
  void _detach() {
    final subs = List.of(_subs);
    final client = _client;
    _subs.clear();
    _client = null;

    for (final sub in subs) {
      sub.cancel();
    }
    client?.dispose();
  }

  /// Test seam: feeds a snapshot in as though the bridge had sent it, so the
  /// screens can be exercised without a Mac on the other end.
  @visibleForTesting
  void debugApplySnapshot(PresenceSnapshot snapshot) {
    _loaded = true;
    _onSnapshot(snapshot);
  }

  /// Test seam for a single event. Notifications no-op until [Notifier.init].
  @visibleForTesting
  void debugApplyEvent(GatherEvent event) => _onEvent(event);

  /// Test seam for the link state, which changes what an empty feed means: with
  /// no connection the screen says so rather than claiming all is quiet.
  @visibleForTesting
  void debugApplyLink(LinkStatus status) => _onStatus(status);

  void _onSnapshot(PresenceSnapshot snapshot) {
    _snapshot = snapshot;
    notifyListeners();
  }

  void _onStatus(LinkStatus status) {
    _link = status;
    notifyListeners();
  }

  void _onEvent(GatherEvent event) {
    _log.insert(0, event);
    if (_log.length > _logLimit) _log.removeRange(_logLimit, _log.length);
    // Fire and forget: a failed notification must never break the log.
    _notifier.consider(event, nameFor);
    notifyListeners();
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }
}
