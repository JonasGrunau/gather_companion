import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:gather_events/gather_events.dart';

import 'bridge_client.dart';
import 'notifications.dart';
import 'pairing.dart';
import 'push.dart';
import 'relevance.dart';
import 'settings.dart';

/// Everything the UI reads. One object, so the whole app is a single
/// `ListenableBuilder` away from being correct.
class AppState extends ChangeNotifier {
  // A named parameter cannot be a private initializing formal, so the field is
  // assigned the long way round — same as `BridgeClient`.
  AppState({Notifier? notifier, PushRegistrar? push})
      : _notifier = notifier ?? Notifier(),
        // ignore: prefer_initializing_formals
        _push = push;

  final Notifier _notifier;
  Notifier get notifier => _notifier;

  /// Built lazily and never eagerly: `FirebaseMessaging.instance` throws when
  /// Firebase was not initialised, which is the normal state in widget tests and
  /// on a build without a `GoogleService-Info.plist`. Push is an enhancement, so
  /// its absence has to be survivable rather than fatal.
  PushRegistrar? _push;
  StreamSubscription<String>? _pushRefresh;

  PushRegistrar? _pushRegistrar() {
    try {
      return _push ??= PushRegistrar();
    } catch (_) {
      return null;
    }
  }

  BridgeClient? _client;
  final _subs = <StreamSubscription<dynamic>>[];

  /// Newest first, so the list view needs no reversing.
  final List<GatherEvent> _log = [];
  static const _logLimit = 1000;

  BridgeSettings _settings = BridgeSettings.empty;
  PresenceSnapshot _snapshot = PresenceSnapshot.empty;
  LinkStatus _link = const LinkStatus(LinkState.idle);
  bool _loaded = false;

  /// Whether the first history fetch is still outstanding.
  ///
  /// Starts true — a state that never attaches (tests, an unpaired app) has
  /// nothing to wait for. [_attach] clears it, and priming sets it again, so the
  /// feed can hold back its "nothing here" card for the moment between opening
  /// the app and the backlog landing. Without that, opening onto a busy room
  /// showed "No activity yet" and then yanked it away.
  bool _primed = true;

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

  /// True while the backlog is still on its way and there is nothing to show yet.
  bool get isPriming => !_primed && _log.isEmpty;
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

  /// Party mode as the bridge last reported it.
  PartyState get party => _snapshot.party;

  /// What the button should show: what we asked for while that is still in
  /// flight, and the truth the rest of the time.
  ///
  /// A round trip to the computer takes long enough that a button waiting for it
  /// feels broken, and party mode is a toy — it has to answer the tap instantly.
  /// [_partyWanted] is cleared by the snapshot that agrees with it rather than by
  /// the HTTP response, because the two race and the snapshot is the one that is
  /// actually true.
  bool get partyMode => _partyWanted ?? _snapshot.party.active;

  /// Whether a toggle is still on its way to the bridge.
  bool get partyPending => _partyWanted != null;

  bool? _partyWanted;

  /// Gives up on waiting for a snapshot to confirm the toggle.
  ///
  /// [_partyWanted] is normally cleared by the snapshot that agrees with it, which
  /// arrives in well under a second. If the socket dies in the gap between the
  /// command landing and that snapshot, no such snapshot is ever coming — and the
  /// switch would sit there lit, pending for ever, asserting a state nothing has
  /// confirmed. Falling back to the truth is better than showing a wish.
  Timer? _partyWantedTimer;

  /// The classified feed, rebuilt only when something it depends on changes.
  ///
  /// This used to classify every event in the log — up to [_logLimit] of them —
  /// on *every* rebuild, and [hiddenCount] then did a second full pass. Since the
  /// whole app hangs off one `ListenableBuilder`, that ran again for every socket
  /// frame, every status tick and every frame of the refresh indicator, which is
  /// what made a busy room stutter. The cache is invalidated by anything that can
  /// change the outcome, including a new snapshot: names are resolved during
  /// classification, so an event logged before its player was known still gets
  /// its label filled in the moment the roster arrives.
  List<({GatherEvent event, EventLook look})>? _feed;
  int _hidden = 0;

  void _invalidateFeed() => _feed = null;

  void _classify() {
    final out = <({GatherEvent event, EventLook look})>[];
    var hidden = 0;
    for (final event in _log) {
      final look = lookOf(event, nameFor);
      if (look.relevance == Relevance.ambient) {
        hidden++;
        if (!_showEverything) continue;
      }
      out.add((event: event, look: look));
    }
    _feed = out;
    _hidden = _showEverything ? 0 : hidden;
  }

  List<({GatherEvent event, EventLook look})> get feed {
    if (_feed == null) _classify();
    return _feed!;
  }

  /// How many ambient events are being held back, so the toggle can say so.
  int get hiddenCount {
    if (_feed == null) _classify();
    return _hidden;
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
        _invalidateFeed();
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
    _partyWantedTimer?.cancel();
    _partyWantedTimer = null;
    _partyWanted = null;
    _log.clear();
    _invalidateFeed();
    _detach();
    notifyListeners();
  }

  /// Asks the bridge to start or stop teleporting me around the map.
  ///
  /// Returns null when it took, or a sentence to put in front of the user. The
  /// bridge refuses rather than pretending when it has no Gather connection, so
  /// the failure is worth showing rather than swallowing.
  Future<String?> setPartyMode(bool on) async {
    final client = _client;
    if (client == null) return 'Not connected to the bridge.';

    _partyWanted = on;
    _partyWantedTimer?.cancel();
    _partyWantedTimer = Timer(const Duration(seconds: 6), () {
      if (_partyWanted == null) return;
      _partyWanted = null;
      notifyListeners();
    });
    notifyListeners();

    final error = await client.setParty(on);
    if (error != null) {
      // Snap back: nothing changed on the other end, so the button must not go
      // on claiming otherwise while it waits for a snapshot that will not come.
      _clearPartyWanted();
    }
    return error;
  }

  void _clearPartyWanted() {
    _partyWantedTimer?.cancel();
    _partyWantedTimer = null;
    if (_partyWanted == null) return;
    _partyWanted = null;
    notifyListeners();
  }

  /// Confirms the link is really up, and reconnects only if it is not.
  ///
  /// What iOS resume calls. See [BridgeClient.verify] for why this is not just a
  /// reconnect.
  Future<void> verifyLink() async {
    await _client?.verify();
  }

  void setShowEverything(bool value) {
    _showEverything = value;
    _invalidateFeed();
    notifyListeners();
  }

  /// Reconnects, and resolves only once there is something to show for it.
  ///
  /// The floor is what makes pull-to-refresh feel like an action rather than a
  /// twitch: a local bridge answers in ~50ms, and an indicator that appears and
  /// vanishes inside two frames reads as a rendering fault. The ceiling lives in
  /// [BridgeClient.whenLive], so an unreachable computer releases the spinner instead
  /// of pinning it open.
  Future<void> reconnect() async {
    // The floor is outside the null check on purpose: the gesture should feel
    // the same whether or not there is a socket behind it.
    final floor = Future<void>.delayed(const Duration(milliseconds: 450));
    final client = _client;
    if (client == null) return floor;
    client.reconnect();
    await Future.wait([client.whenLive(), floor]);
  }

  void clearLog() {
    _log.clear();
    _invalidateFeed();
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
      ..add(client.parties.listen(_onParty))
      ..add(client.events.listen(_onEvent))
      ..add(client.status.listen(_onStatus));
    _primed = false;
    client.connect();
    _primeHistory(client);
    unawaited(_registerForPush());
  }

  /// Hands this phone's push token to the bridge, and keeps it current.
  ///
  /// Done on every attach rather than once at pairing: registration is
  /// idempotent, tokens rotate, and the bridge forgets a device it was told is
  /// dead — so the only way to be reliably reachable is to say so regularly.
  Future<void> _registerForPush() async {
    final registrar = _pushRegistrar();
    if (registrar == null) return;
    await registrar.register(_settings);
    _pushRefresh ??= registrar.tokenRefreshes.listen((_) {
      unawaited(registrar.register(_settings));
    });
  }

  /// Fills the feed with recent history on a first connection, so the app does
  /// not open on an empty screen when the bridge has been running for hours.
  Future<void> _primeHistory(BridgeClient client) async {
    if (_log.isNotEmpty) return;
    final history = await client.recentHistory();
    if (_client != client) return;
    _primed = true;
    if (history.isEmpty) {
      // Nothing to add, but the feed still has to be told to stop waiting.
      notifyListeners();
      return;
    }
    // Oldest last, matching the newest-first order the list view expects.
    for (final event in history) {
      _log.add(event);
    }
    _invalidateFeed();
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
  /// screens can be exercised without a computer on the other end.
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
    _confirmParty(snapshot.party);
    // Names live in the snapshot and are resolved during classification, so a
    // new roster can relabel events that are already in the log.
    _invalidateFeed();
    notifyListeners();
  }

  /// Party mode's own frame: the hop counter, without the roster around it.
  void _onParty(PartyState party) {
    _snapshot = _snapshot.withParty(party);
    _confirmParty(party);
    // Deliberately no `_invalidateFeed()`: nothing here can relabel an event, and
    // reclassifying the whole log once a second is exactly the cost this frame
    // exists to avoid.
    notifyListeners();
  }

  /// Stops overriding the button once the bridge agrees with what we asked for.
  ///
  /// From here on the bridge is the only thing the button reads — which is what
  /// lets it go dark on its own when party mode times out or the bridge loses
  /// Gather. Does not notify: both callers do that themselves.
  void _confirmParty(PartyState party) {
    if (_partyWanted != party.active) return;
    _partyWantedTimer?.cancel();
    _partyWantedTimer = null;
    _partyWanted = null;
  }

  void _onStatus(LinkStatus status) {
    _link = status;
    notifyListeners();
  }

  void _onEvent(GatherEvent event) {
    _log.insert(0, event);
    if (_log.length > _logLimit) _log.removeRange(_logLimit, _log.length);
    _invalidateFeed();
    // Fire and forget: a failed notification must never break the log.
    _notifier.consider(event, nameFor);
    notifyListeners();
  }

  @override
  void dispose() {
    _detach();
    _partyWantedTimer?.cancel();
    _partyWantedTimer = null;
    // Outside _detach on purpose: token rotation is about this device, not about
    // any one socket, so it must survive a reconnect and only end with the app.
    _pushRefresh?.cancel();
    _pushRefresh = null;
    super.dispose();
  }
}
