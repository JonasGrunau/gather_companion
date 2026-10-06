/// A [Collector] a script drives, reaching no socket and no Gather.
///
/// The presence-plane sibling of `ScriptedCall`: it stands exactly where
/// `DirectCollector` stands, so `AppState._attach` runs for real — `Walk`,
/// `PartyMode` and the whole office come up live — with the roster, the map and
/// the event bus all coming from here instead of a WebSocket.
///
/// The one thing that makes the office *interactive* rather than a picture: it
/// closes the loop the real server would. When the D-pad's [move] (or party
/// mode's [teleport]) comes in, it advances my tile and **re-emits [rosters]** —
/// which is exactly how a real position frame confirms a step. `Walk` adopts the
/// new tile off that roster and the avatar travels; nothing here fakes the
/// movement, it just plays the server's half of the exchange.
///
/// A scenario moves the other people with [placePerson] then [publish], and sends
/// a wave with [wave]. Everything a real collector writes to the socket is a
/// recorded no-op that returns success.
library;

import 'dart:async';

import 'package:gather_client/gather_client.dart';

import 'harness_data.dart';

/// One colleague standing on the schematic floor.
class _Standing {
  _Standing({required this.person, required this.x, required this.y});
  final CallPerson person;
  int x;
  int y;
  String direction = 'Down';
  bool speaking = false;
}

class FakeCollector implements Collector {
  FakeCollector({int participants = 4}) {
    for (final p in seated(participants)) {
      final at = kCastStartTiles[p.spaceId] ?? kSelfStartTile;
      _people[p.spaceId] = _Standing(person: p, x: at.x, y: at.y);
    }
  }

  final _rosters = StreamController<Roster>.broadcast();
  final _interactions = StreamController<BusEvent>.broadcast();
  final _statuses = StreamController<CollectorStatus>.broadcast();
  final _refusals = StreamController<ActionRefused>.broadcast();

  ({int x, int y}) _me = kSelfStartTile;
  String _myDirection = 'Down';
  bool _mySpeaking = false;
  final Map<String, _Standing> _people = {};

  /// What the write side was asked to do, kept so a harness can show it and a
  /// test can assert it.
  final List<String> moves = [];
  final List<({num x, num y})> teleports = [];

  // ---- streams ---------------------------------------------------------------

  @override
  Stream<Roster> get rosters => _rosters.stream;
  @override
  Stream<BusEvent> get interactions => _interactions.stream;
  @override
  Stream<CollectorStatus> get statuses => _statuses.stream;
  @override
  Stream<ActionRefused> get refusals => _refusals.stream;

  // ---- reads -----------------------------------------------------------------

  @override
  String? get selfId => kSelfId;
  @override
  String? get selfAccountId => kSelfAccountId;
  @override
  bool get healthy => true;
  @override
  bool get hasState => true;

  @override
  SpaceMap? mapFor(String? floorId) => schematicOffice();
  @override
  SpaceArt? artFor(String? floorId, {bool dark = true}) => null;
  @override
  String? avatarUrlFor(String spaceUserId) => null;

  // ---- lifecycle -------------------------------------------------------------

  @override
  void start() {
    if (!_statuses.isClosed) {
      _statuses.add(const CollectorStatus(healthy: true, detail: 'simulator'));
    }
    publish();
  }

  @override
  Future<void> dispose() async {
    await _rosters.close();
    await _interactions.close();
    await _statuses.close();
    await _refusals.close();
  }

  // ---- what a scenario drives ------------------------------------------------

  /// Builds the current roster — me plus everyone seated — and pushes it out.
  /// The map, the people and the walk all ride on this.
  void publish() {
    if (_rosters.isClosed) return;
    _rosters.add(_roster());
  }

  /// Moves a colleague, or lights their speaking ring. Call [publish] after.
  void placePerson(String spaceId, {int? x, int? y, String? direction, bool? speaking}) {
    final who = _people[spaceId];
    if (who == null) return;
    if (x != null) who.x = x;
    if (y != null) who.y = y;
    if (direction != null) who.direction = direction;
    if (speaking != null) who.speaking = speaking;
  }

  /// Steps a colleague one tile in [direction], clamped to the floor. Call
  /// [publish] after. The scenario's equivalent of a person pressing their own
  /// D-pad.
  void stepPerson(String spaceId, String direction) {
    final who = _people[spaceId];
    final step = stepOf(direction);
    if (who == null || step == null) return;
    who.x = (who.x + step.dx).clamp(0, kOfficeWidth - 1);
    who.y = (who.y + step.dy).clamp(0, kOfficeHeight - 1);
    who.direction = direction;
  }

  /// Everyone currently on the floor, by `spaceId`.
  Iterable<String> get peopleIds => _people.keys;

  /// Sends a wave from [fromSpaceId] to me, on the event bus. Surfaces in the
  /// Activity feed as a live item through `AppState._noteActivity`.
  void wave(String fromSpaceId) {
    if (_interactions.isClosed) return;
    _interactions.add(BusEvent(
      name: 'WaveEvent',
      senderId: fromSpaceId,
      sentTime: DateTime.now().toUtc().toIso8601String(),
      targetUserIds: const [kSelfId],
      payload: const {},
    ));
  }

  Roster _roster() => Roster(
        selfId: kSelfId,
        rows: [
          selfOfficeRow(_me, direction: _myDirection, speaking: _mySpeaking),
          for (final s in _people.values)
            officeRow(
              s.person,
              (x: s.x, y: s.y),
              direction: s.direction,
              speaking: s.speaking,
            ),
        ],
      );

  // ---- the write side: the server's half of each action ----------------------

  @override
  ({bool ok, String? detail}) move({required String direction}) {
    moves.add(direction);
    final step = stepOf(direction);
    if (step == null) return (ok: false, detail: '$direction is not a direction');
    _myDirection = direction;
    _me = (
      x: (_me.x + step.dx).clamp(0, kOfficeWidth - 1),
      y: (_me.y + step.dy).clamp(0, kOfficeHeight - 1),
    );
    publish();
    return (ok: true, detail: null);
  }

  @override
  ({bool ok, String? detail}) teleport({required num x, required num y, String direction = 'Down'}) {
    teleports.add((x: x, y: y));
    _myDirection = direction;
    _me = (
      x: x.round().clamp(0, kOfficeWidth - 1),
      y: y.round().clamp(0, kOfficeHeight - 1),
    );
    publish();
    return (ok: true, detail: null);
  }

  @override
  ({bool ok, String? detail}) setSpeaking(bool speaking) {
    _mySpeaking = speaking;
    publish();
    return (ok: true, detail: null);
  }

  // The rest write nothing a sim can show — recorded no-ops that succeed, so the
  // callers (status sheet, control bar) resolve instead of throwing.
  @override
  ({bool ok, String? detail}) setGait(Gait gait) => (ok: true, detail: null);
  @override
  ({bool ok, String? detail}) setAvailability(String availability) => (ok: true, detail: null);
  @override
  ({bool ok, String? detail}) setCustomStatus({required String text, String? emoji, DateTime? clearAt}) => (ok: true, detail: null);
  @override
  ({bool ok, String? detail}) clearCustomStatus() => (ok: true, detail: null);
  @override
  ({bool ok, String? detail}) broadcastEmote(String emote, {int count = 1}) => (ok: true, detail: null);
  @override
  ({bool ok, String? detail}) leaveCluster() => (ok: true, detail: null);
  @override
  ({bool ok, String? detail}) setActive(bool active) => (ok: true, detail: null);

  @override
  Future<({bool ok, String detail})> resync() async {
    publish();
    return (ok: true, detail: 'simulator; a fresh roster follows');
  }
}
