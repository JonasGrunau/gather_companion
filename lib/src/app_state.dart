import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_events/gather_events.dart';

import 'credentials.dart';
import 'link_status.dart';
import 'map_person.dart';
import 'notifications.dart';
import 'pairing.dart';
import 'push.dart';
import 'settings.dart';

/// Everything the UI reads. One object, so the whole app is a single
/// `ListenableBuilder` away from being correct.
///
/// ## What changed, and why it is simpler
///
/// This used to hold a `BridgeClient` — a WebSocket to a computer on the same wifi,
/// with sequence-based catch-up, ping-driven liveness and a generation counter to
/// stop overlapping resumes from orphaning sockets. All of that existed because the
/// phone could not talk to Gather.
///
/// It can. So the socket is now to Gather itself, and the bridge is left with two
/// jobs: handing over the credential at pairing, and pushing when this app is not
/// running. Three consequences worth knowing:
///
///  * **The computer can be asleep.** Presence works on cellular, from anywhere.
///  * **Party mode is instant.** It runs here, against a socket we already hold, so
///    the optimistic-UI dance that hid a LAN round trip is gone entirely.
///  * **Nothing is remembered.** There is no 500-event ring on the bridge to
///    replay, and the phone does not keep one either: a log that can only record
///    what happened while the app was open is empty exactly when it would be worth
///    reading. Events exist to be notified about. `_onFold` hands each one to
///    [Notifier] and lets it go.
class AppState extends ChangeNotifier {
  // A named parameter cannot be a private initializing formal, so the fields are
  // assigned the long way round.
  AppState({
    Notifier? notifier,
    PushRegistrar? push,
    GatherCredentialStore? credentials,
    // Test seam: lets a suite drive a fake Gather without a network.
    DirectCollector Function(GatherAuth auth, String? spaceId)? buildCollector,
  })  : _notifier = notifier ?? Notifier(),
        // ignore: prefer_initializing_formals
        _push = push,
        _credentialStore = credentials ?? GatherCredentialStore(),
        _buildCollector = buildCollector ?? _realCollector;

  static DirectCollector _realCollector(GatherAuth auth, String? spaceId) =>
      DirectCollector(auth: auth, spaceId: spaceId);

  final Notifier _notifier;
  Notifier get notifier => _notifier;

  final GatherCredentialStore _credentialStore;
  final DirectCollector Function(GatherAuth auth, String? spaceId) _buildCollector;

  /// Built lazily and never eagerly: `FirebaseMessaging.instance` throws when
  /// Firebase was not initialised, which is the normal state in widget tests and on a
  /// build without a `GoogleService-Info.plist`.
  PushRegistrar? _push;
  StreamSubscription<String>? _pushRefresh;

  PushRegistrar? _pushRegistrar() {
    try {
      return _push ??= PushRegistrar();
    } catch (_) {
      return null;
    }
  }

  // ---- the Gather connection -------------------------------------------------

  DirectCollector? _collector;
  PartyMode? _party;
  final PresenceTracker _tracker = PresenceTracker();
  final _subs = <StreamSubscription<dynamic>>[];

  /// Where the bridge is, for push registration only. Nothing renders from it.
  BridgeSettings _settings = BridgeSettings.empty;
  GatherCredentials _credentials = GatherCredentials.empty;
  String? _spaceId;

  PresenceSnapshot _snapshot = PresenceSnapshot.empty;
  LinkStatus _link = const LinkStatus(LinkState.idle);
  bool _loaded = false;
  String? _bridgeName;

  BridgeSettings get settings => _settings;
  PresenceSnapshot get snapshot => _snapshot;
  LinkStatus get link => _link;
  bool get isLoaded => _loaded;
  String? get bridgeName => _bridgeName;

  /// Whether this phone can read Gather on its own.
  ///
  /// The Gather credential, not the bridge token: reading presence is what the screen
  /// is for. A pairing that produced no session leaves the app here, which is correct:
  /// the fix is one command on the Mac, and pretending otherwise would show a screen
  /// that can never answer anything.
  bool get isConfigured => _credentials.isComplete;

  /// Whether the bridge can wake this phone while the app is closed.
  ///
  /// Independent of [isConfigured] on purpose: presence works without it, and losing
  /// push is a degradation rather than a failure.
  bool get canBeWoken => _settings.isComplete;

  /// Who is following me — the only thing this app claims to know about anyone.
  ///
  /// Sorted by name so the chips keep their places between snapshots. Roster order is
  /// Gather's own map iteration and shuffles for reasons that have nothing to do with
  /// people, which reads as flicker.
  List<PlayerRef> get followers {
    final list = _snapshot.players.where((p) => p.isFollowingMe).toList()
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return list;
  }

  // ---- the map ---------------------------------------------------------------

  /// The last roster, kept whole.
  ///
  /// [PresenceSnapshot] deliberately drops positions — knowing who is *near* you
  /// says nothing about whether they want you, which is the mistake this app was
  /// built to stop making. The map screen is the one place where a coordinate is
  /// the point rather than a proxy for something else, so it reads the roster
  /// directly instead of widening `PlayerRef` for everybody.
  Roster? _roster;

  /// Ticks whenever a roster lands, which is up to four times a second.
  ///
  /// Separate from [notifyListeners] on purpose. Movement is not a presence event:
  /// [PresenceTracker] does not look at coordinates at all, so a roster where
  /// everybody walked leaves `stateChanged` false and never reaches the UI — which
  /// is right for every screen except the one that draws positions, where it meant
  /// the map froze until somebody happened to follow you or disconnect.
  ///
  /// Waking the whole tree at 4Hz to fix that would be the other mistake: the feed
  /// would rebuild on a stranger's footstep. So this is its own [Listenable] and
  /// only the map listens. With the map closed it has no listeners and a tick costs
  /// nothing.
  Listenable get positions => _positions;
  final _positions = _Ticker();

  /// The floor plan, or null until enough of it has arrived.
  SpaceMap? get map => debugMap ?? _collector?.mapFor(_myRow()?.floorId);

  /// Test seam. The real map is assembled from ~1700 patches inside a live state
  /// dump, which is not a thing a widget test can arrange.
  @visibleForTesting
  SpaceMap? debugMap;

  RosterRow? _myRow() {
    final roster = _roster;
    if (roster == null) return null;
    for (final row in roster.rows) {
      if (row.id == roster.selfId) return row;
    }
    return null;
  }

  /// Where I am, in tiles, or null before the first roster.
  ({int x, int y})? get myTile {
    final me = _myRow();
    final x = me?.x, y = me?.y;
    if (x == null || y == null || !x.isFinite || !y.isFinite) return null;
    return (x: x.round(), y: y.round());
  }

  /// Everyone else who is actually here, with somewhere to draw them.
  ///
  /// Offline rows are excluded: their coordinates are wherever somebody logged off,
  /// so drawing them would populate the map with people who are not in the building.
  List<MapPerson> get peopleOnMap {
    final roster = _roster;
    if (roster == null) return const [];
    final floorId = _myRow()?.floorId;
    final followers = {
      for (final p in _snapshot.players)
        if (p.isFollowingMe) p.id,
    };
    final speaking = {
      for (final p in _snapshot.players)
        if (p.speaking) p.id,
    };
    final out = <MapPerson>[];
    for (final row in roster.rows) {
      if (row.id == roster.selfId) continue;
      if (row.connected == false) continue;
      final x = row.x, y = row.y;
      if (x == null || y == null || !x.isFinite || !y.isFinite) continue;
      if (row.floorId != null && floorId != null && row.floorId != floorId) continue;
      out.add(MapPerson(
        id: row.id,
        label: row.name ?? row.id.substring(0, row.id.length.clamp(0, 6)),
        x: x.round(),
        y: y.round(),
        isFollowingMe: followers.contains(row.id),
        speaking: speaking.contains(row.id),
      ));
    }
    // Roster order is Gather's own map iteration and shuffles between snapshots.
    // The painter decides whether to repaint by comparing this list position by
    // position, so a stable order is what makes that comparison mean anything.
    out.sort((a, b) => a.id.compareTo(b.id));
    return out;
  }

  PartyState get party => _snapshot.party;

  /// Party mode runs in this process now, so what it says is what is true — no
  /// optimistic override, and nothing to reconcile against a later snapshot.
  bool get partyMode => _snapshot.party.active;
  bool get partyPending => false;

  /// Development shortcut past the scanner:
  /// `--dart-define=GATHER_PAIR=host:port:token:refreshToken`.
  ///
  /// The simulator has no camera, so without this there is no way to reach the main
  /// screen while working on it. Empty in any normal build.
  static const _devPair = String.fromEnvironment('GATHER_PAIR');

  Future<void> boot() async {
    _settings = await BridgeSettings.load();
    _bridgeName = await BridgeSettings.loadName();
    _credentials = await _credentialStore.load();
    _spaceId = await _credentialStore.loadSpaceId();

    if (!_credentials.isComplete && _devPair.isNotEmpty) {
      final parts = _devPair.split(':');
      if (parts.length >= 4) {
        _settings = BridgeSettings(
          host: parts[0],
          port: int.tryParse(parts[1]) ?? BridgeSettings.defaultPort,
          token: parts[2],
        );
        _credentials = GatherCredentials(refreshToken: parts[3]);
        _bridgeName = 'dev · ${parts[0]}';
      }
    }

    _loaded = true;
    await _notifier.init();
    notifyListeners();

    if (_credentials.isComplete) _attach();
  }

  /// Trades a scanned or typed pairing code for both credentials.
  ///
  /// Returns null when it took, or a sentence to put in front of the user.
  Future<String?> pair({required String host, required int port, required String code}) async {
    final result = await claimPairing(host: host, port: port, code: code);
    switch (result) {
      case PairFailure(:final message):
        return message;
      case PairSuccess(:final settings, :final name, :final gather, :final spaceId):
        _settings = settings;
        _bridgeName = name;
        await settings.save();
        await BridgeSettings.saveName(name);

        if (!gather.isComplete) {
          // Pairing worked; the bridge simply has no Gather session to give. Say so
          // rather than landing on a feed that can never fill.
          notifyListeners();
          return 'Paired with $name, but it has no Gather session yet. '
              'Run `npx gather-app-bridge adopt` on the computer, then pair again.';
        }

        _credentials = gather;
        _spaceId = spaceId;
        await _credentialStore.save(gather);
        await _credentialStore.saveSpaceId(spaceId);

        await _notifier.requestPermission();
        _snapshot = PresenceSnapshot.empty;
        notifyListeners();
        _attach();
        return null;
    }
  }

  Future<void> unpair() async {
    await BridgeSettings.clear();
    await _credentialStore.clear();
    _settings = BridgeSettings.empty;
    _credentials = GatherCredentials.empty;
    _spaceId = null;
    _bridgeName = null;
    _snapshot = PresenceSnapshot.empty;
    await _detach();
    _link = const LinkStatus(LinkState.idle);
    notifyListeners();
  }

  /// Starts or stops teleporting my avatar around the map.
  ///
  /// Synchronous in everything but signature: party mode runs in this process against
  /// a socket already open, so there is nothing to wait for and nothing to be
  /// optimistic about. The `Future` stays so the call sites do not have to change.
  Future<String?> setPartyMode(bool on) async {
    final party = _party;
    if (party == null) return 'Not connected to Gather.';

    if (!on) {
      _onPartyChanged(party.stop('switched off'));
      return null;
    }
    final result = party.start();
    _onPartyChanged(result.state);
    return result.ok ? null : (result.state.detail ?? 'Party mode could not start.');
  }

  /// Confirms the connection is really up, and reconnects only if it is not.
  ///
  /// What iOS resume calls. A suspended app's socket dies without an error, so the
  /// held connection may be a corpse — but tearing down a healthy one on every resume
  /// would mean a fresh state dump every time the user glances at their phone.
  Future<void> verifyLink() async {
    final collector = _collector;
    if (collector == null) return;
    if (collector.healthy && collector.hasState) return;
    await collector.resync();
  }

  /// Reconnects, and resolves only once there is something to show for it.
  ///
  /// The floor is what makes pull-to-refresh feel like an action rather than a
  /// twitch: a reconnect can complete in well under a frame, and an indicator that
  /// appears and vanishes inside two frames reads as a rendering fault.
  Future<void> reconnect() async {
    final floor = Future<void>.delayed(const Duration(milliseconds: 450));
    final collector = _collector;
    if (collector == null) return floor;
    await Future.wait([collector.resync(), floor]);
  }

  /// Best available name for a player id, falling back to a short id.
  String nameFor(String id) {
    for (final player in _snapshot.players) {
      if (player.id == id) return player.label;
    }
    return id.length <= 8 ? id : id.substring(0, 8);
  }

  // ---- wiring ----------------------------------------------------------------

  void _attach() {
    unawaited(_detach());

    final auth = GatherAuth(
      credentials: _credentials,
      // Google may rotate the refresh token. Persisting the new one immediately is
      // what keeps a phone working across the rotation instead of silently holding a
      // credential that has been superseded.
      onRotated: (next) async {
        _credentials = next;
        await _credentialStore.save(next);
      },
    );

    final collector = _collector = _buildCollector(auth, _spaceId);
    final party = _party = PartyMode(collector: () => _collector);

    _subs
      ..add(collector.rosters.listen((roster) {
        // Party mode first, so a hop fired from this same roster is judged against the
        // freshest positions we hold rather than the previous ones.
        party.noteRoster(roster);
        _roster = roster;
        // The collector already coalesces and only publishes when something in the
        // state actually moved, so this is "the map changed", not a clock.
        _positions.tick();
        final out = _tracker.applyRoster(roster);
        _onFold(out);
      }))
      ..add(collector.interactions.listen((event) {
        _onFold(_tracker.applyInteraction(event));
      }))
      ..add(collector.statuses.listen(_onCollectorStatus))
      ..add(party.changes.listen(_onPartyChanged))
      ..add(party.progress.listen(_onPartyProgress));

    collector.start();
    unawaited(_registerForPush());
  }

  Future<void> _detach() async {
    final subs = List.of(_subs);
    final collector = _collector;
    final party = _party;
    _subs.clear();
    _collector = null;
    _party = null;


    for (final sub in subs) {
      await sub.cancel();
    }
    await party?.dispose();
    await collector?.dispose();
  }

  /// Hands this phone's push token to the bridge, if it happens to be reachable.
  ///
  /// Opportunistic on purpose, and the only thing that still needs the computer at
  /// all. FCM tokens rotate — a reinstall, a restore from backup, Firebase's own
  /// schedule — so registering once at pairing would let push die silently months
  /// later. Registering on every attach is idempotent and costs one request.
  ///
  /// A failure is not reported: the phone is frequently on a different network from
  /// the computer, and that is a normal state, not a fault.
  Future<void> _registerForPush() async {
    if (!_settings.isComplete) return;
    final registrar = _pushRegistrar();
    if (registrar == null) return;
    await registrar.register(_settings);
    _pushRefresh ??= registrar.tokenRefreshes.listen((_) {
      unawaited(registrar.register(_settings));
    });
  }

  void _onFold(FoldResult out) {
    // Events are no longer kept — the screen has nowhere to put them. They exist to
    // be notified about, and nothing else, so this is the only thing left to do with
    // one. Fire and forget: a failed notification must never break the fold.
    for (final event in out.emit) {
      _notifier.consider(event, nameFor);
    }
    if (out.emit.isNotEmpty || out.stateChanged) {
      _snapshot = _tracker.snapshot();
      notifyListeners();
    }
  }

  void _onCollectorStatus(CollectorStatus status) {
    _tracker.setHealth(CollectorHealth(
      gather: status.healthy,
      // `cdp` is a compatibility alias, not a second collector: `hasRichData` reads
      // `gather || cdp`, and mirroring keeps a build that predates the rename honest.
      cdp: status.healthy,
      detail: status.detail,
    ));

    _link = switch (status) {
      CollectorStatus(needsPairing: true) =>
        LinkStatus(LinkState.idle, status.detail, true),
      CollectorStatus(healthy: true) => LinkStatus(LinkState.live, status.detail),
      _ => LinkStatus(LinkState.retrying, status.detail),
    };

    // A party cannot run without Gather, and a switch left glowing through a dropped
    // connection would be asserting something untrue.
    if (!status.healthy) _party?.stop(status.detail ?? 'lost the connection to Gather');

    _snapshot = _tracker.snapshot();
    notifyListeners();
  }

  void _onPartyChanged(PartyState party) {
    _tracker.setParty(party);
    _snapshot = _tracker.snapshot();
    notifyListeners();
  }

  /// Party mode's counter, without the roster around it.
  ///
  /// Deliberately no `_invalidateFeed()`: nothing here can relabel an event, and
  /// reclassifying the whole log once a second is exactly the cost this exists to
  /// avoid.
  void _onPartyProgress(PartyState party) {
    _tracker.setParty(party);
    _snapshot = _snapshot.withParty(party);
    notifyListeners();
  }

  // ---- test seams ------------------------------------------------------------

  /// Feeds a roster in as though Gather had sent it, for the screens that draw
  /// positions rather than the presence digest.
  ///
  /// Deliberately the same path as the live subscription, including *not* calling
  /// [notifyListeners] for a roster the tracker finds nothing in. A seam that woke
  /// the whole tree unconditionally would make a screen wired to the wrong
  /// [Listenable] look live in tests and freeze in the office, which is exactly the
  /// bug this shape exists to prevent.
  @visibleForTesting
  void debugApplyRoster(Roster roster) {
    _roster = roster;
    _positions.tick();
    _onFold(_tracker.applyRoster(roster));
  }

  /// Feeds a snapshot in as though Gather had sent it, so the screens can be
  /// exercised without a connection.
  @visibleForTesting
  void debugApplySnapshot(PresenceSnapshot snapshot) {
    _loaded = true;
    _snapshot = snapshot;
    notifyListeners();
  }

  /// Test seam for a single event. Notifications no-op until [Notifier.init].
  @visibleForTesting
  void debugApplyEvent(GatherEvent event) =>
      _onFold(FoldResult(emit: [event], stateChanged: false));

  /// Test seam for the link state, which changes what an empty feed means: with no
  /// connection the screen says so rather than claiming all is quiet.
  @visibleForTesting
  void debugApplyLink(LinkStatus status) {
    _link = status;
    notifyListeners();
  }

  @override
  void dispose() {
    _positions.dispose();
    unawaited(_detach());
    // Outside `_detach` on purpose: token rotation is about this device, not about any
    // one connection, so it must survive a reconnect and only end with the app.
    _pushRefresh?.cancel();
    _pushRefresh = null;
    super.dispose();
  }
}

/// A [Listenable] with nothing in it, for changes whose value is read from
/// somewhere else.
///
/// The disposed guard is not defensive programming: `_detach` cancels the roster
/// subscription asynchronously, so a roster already in flight can land after
/// `dispose`, and a [ChangeNotifier] used after disposal throws.
class _Ticker extends ChangeNotifier {
  bool _disposed = false;

  void tick() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
