/// The floor plan, decoded the way Gather's own client decodes it.
///
/// Gather never serves the map over REST — `/spaces/<id>/maps`, `/floors` and
/// `/map` all 404. It does not need to: the whole map is in the state dump, in four
/// models, with counts from the 124×82 space this was built against.
///
///  - **`FloorMap`** ×1 — names the base `MapArea` and the floor.
///  - **`MapArea`** ×93 — rectangles. The base area is the grid; the rest are rooms,
///    desks and team zones, positioned against a parent.
///  - **`MapObject`** ×1140 — furniture, positioned against an area *or* another
///    object, each naming a variant.
///  - **`CatalogItemVariant`** ×477 / **`CatalogItem`** ×558 — the shapes.
///
/// ## This is transcribed, not inferred
///
/// The first version of this file reverse-engineered the rules by sweeping every
/// plausible rounding against the live roster and keeping whichever put nobody
/// inside a wall. That gave a self-consistent answer that was **wrong in 425 of
/// about 500 tiles**, and the test could not tell: only eleven people were connected
/// at the time, so four mutually contradictory rules all scored a perfect zero.
///
/// So the rules below are transcribed from the client bundle instead
/// (`app.v2.gather.town`, chunk `bundle.fcbc27cfb33c44ea.js`, class `Collisions` and
/// the `MapObject` getters). Where a comment cites a name like
/// `activeAbsoluteCollisionPositionHashes`, that is the real identifier and the
/// behaviour is copied, not guessed. Positions of live people remain a good
/// *regression* check — everybody is standing somewhere — but they are far too
/// sparse to derive anything from.
///
/// ## The rules
///
/// **Absolute position** is the plain sum of `relativeX`/`relativeY` up the parent
/// chain (`parentObjectId` first, then `parentAreaId`), with no rounding anywhere,
/// capped at `MAX_HIERARCHY_DEPTH` = 20.
///
/// **An object's collision tiles** are, per `MapObject`:
///
/// ```js
/// get topLeftAbsolutePosition() {
///   const A = this.absolutePosition;
///   return {x: A.x - variant.originX/TILE_SIZE, y: A.y - variant.originY/TILE_SIZE};
/// }
/// get absoluteCollisionPositionHashes() {
///   const A = this.topLeftAbsolutePosition;
///   return variant.collisionPositions.map(e =>
///     hashOf({x: Math.round(A.x + e.x), y: Math.round(A.y + e.y)}));
/// }
/// ```
///
/// `TILE_SIZE` is 32. The origin subtraction is the part no amount of staring at
/// coordinates would have produced: `relativeX` positions a *sprite*, and the sprite
/// has its own anchor in pixels.
///
/// **Not every object collides.** `activeAbsoluteCollisionPositionHashes` returns
/// nothing unless `isSpecialEffectActive`, which is
/// `!parentObjectId && !isSnappedToWall` — so anything sitting on top of something
/// else contributes no collision at all, and neither does anything flush against a
/// wall. On the measured space that is 28 nested and 50 wall-snapped objects, and
/// leaving them in was most of the error.
///
/// **Walls do not block tiles.** This is the part that matters most and is easiest
/// to get backwards. `Collisions.addArea` does not mark a room's perimeter
/// impassable; it records *blocked directions* — pairs of adjacent tiles you may not
/// move between — via `addBlockedDirection(outsideTile, wallTile)`. `blockedAtPosition`
/// consults only the object map. So **a wall tile is a tile you can stand on**, and
/// 488 perimeter tiles this used to exclude are perfectly good floor.
///
/// Which of the two questions you are asking decides which rule applies. Party mode
/// teleports, so blocked directions never touch it — that is why [walkable] and
/// [open] are built from the object map alone. The D-pad walks, so they are the only
/// thing keeping it indoors, and [canStep] is where they are enforced.
///
/// **Doorways** are two tiles. `doorwayPositionHashes` expands each
/// `{origin, orientation}` into the origin plus one more — right for `Horizontal`,
/// down for `Vertical` — in coordinates relative to the area.
///
/// ## Standing somewhere you should not
///
/// Walkability is a physical question and this answers it physically. Where a party
/// *ought* to go is a different question, and [SpaceMap.open] answers it with two
/// rules that are deliberately kept out of [SpaceMap.walkable] so the physics and
/// the manners never get confused.
///
/// **Inside the building.** Walls block directions, not tiles — which is exactly
/// what keeps a walking avatar indoors, and exactly what a teleport ignores. So
/// everything outside the office is "walkable" too: nobody furnishes the void, so
/// no collision rule can ever object to it. On the measured space the grid is
/// 124×82 and the office occupies 96×52 of it, which left **5133 of 7315 party
/// tiles outside the building altogether** — and since the jump ladder in
/// `party.dart` favours distance, those were the tiles it kept choosing. The base
/// area is the grid and proves nothing; the other 92 areas are the office. A tile
/// has to be inside one of them.
///
/// **Not in a closed room.** This used to be "not in a walled area", following
/// Gather's own `get isPrivate() { return this.isWalled }`. That is right about
/// audio and wrong about buildings: the office's main floor is itself a walled
/// 44×34 `Public` area, and the Lobby is walled too. Between them they held **all
/// 112 people in the captured dump** — so the rule that was meant to keep a party
/// out of somebody's meeting was deleting the entire office, and the tiles it left
/// were the ones nobody can be. Walls only make an area private when it is a room
/// with a door: [_privateTypes].
///
/// Together those two turn 7315 party tiles into 1447, every one of them indoors,
/// and 94 of the 112 people were standing in that set.
library;

import 'space_art.dart';

/// Pixels per tile. `const l=32` in the bundle, exported as `TILE_SIZE`.
const _tileSize = 32;

/// The client's own cap on how far a parent chain may be followed.
const _maxHierarchyDepth = 20;

/// `wallsTexture` meaning "this area is a grouping, not a room".
const _noWall = 'NewStyleNoWall';

/// The `mapAreaType`s where walls mean "a room you can close yourself into".
///
/// Every other type — `Public`, `Lobby`, `Common`, `Team` — is a zone, and its
/// walls are the building's, not a door. On the measured space this is 14 meeting
/// rooms and 2 private desk booths; the walled areas it deliberately lets through
/// are the 44×34 main floor, the Lobby and one more `Public` zone, which is where
/// everybody actually is.
const _privateTypes = {'MeetingRoom', 'Desk'};

/// The four words `SpaceUser.direction` and the `move` action both use.
///
/// `move`'s schema is `z.object({direction: z.nativeEnum(MoveDirection)})`, and
/// `MoveDirection` is these — so anything else is rejected by the gateway before it
/// reaches the model.
const moveDirections = ['Up', 'Down', 'Left', 'Right'];

/// Which tile a step lands on, relative to the one you are standing on.
///
/// `new Direction(A.direction).toPositionDelta()` in the `move` action's body. Y grows
/// downwards, as it does everywhere in this space: `Up` is towards the top of the map.
/// Null for anything that is not one of [moveDirections].
({int dx, int dy})? stepOf(String direction) => switch (direction) {
      'Up' => (dx: 0, dy: -1),
      'Down' => (dx: 0, dy: 1),
      'Left' => (dx: -1, dy: 0),
      'Right' => (dx: 1, dy: 0),
      _ => null,
    };

/// One rectangle on the floor: a room, a desk, a team's corner.
///
/// Carried because a map of anonymous blocked tiles is a maze, and a map with
/// "Green Park" written across it is a place.
class SpaceRoom {
  const SpaceRoom({
    required this.id,
    required this.name,
    required this.type,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.walled,
  });

  final String id;

  /// Null for the 62 desks and the base area, which are unnamed.
  final String? name;

  /// `Desk`, `MeetingRoom`, `Team`, `Public`, `Common`, `Lobby`.
  final String type;

  final int x;
  final int y;
  final int width;
  final int height;

  /// Whether this area draws walls. Gather treats this as the definition of a
  /// private area, and so does party mode.
  final bool walled;

  bool contains(int tx, int ty) =>
      tx >= x && tx < x + width && ty >= y && ty < y + height;
}

/// One floor, as a grid of tiles.
class SpaceMap {
  SpaceMap({
    required this.floorId,
    required this.width,
    required this.height,
    required Set<int> blocked,
    required this.rooms,
    Set<int>? private,
    Set<int>? inside,
    Map<int, String?>? seats,
    Set<int>? edges,
  })  : _blocked = blocked,
        _edges = edges ?? const {},
        _private = private ?? const {},
        _inside = inside ?? const {},
        _seats = seats ?? const {},
        walkable = _select(width * height, (t) => !blocked.contains(t)),
        open = _select(width * height, (t) {
          if (blocked.contains(t)) return false;
          if ((private ?? const {}).contains(t)) return false;
          final building = inside ?? const <int>{};
          // A space that names no areas beyond the base one is all office — there is
          // no footprint to be outside of, and demanding one would leave a party with
          // nowhere at all to go.
          return building.isEmpty || building.contains(t);
        });

  static List<int> _select(int tiles, bool Function(int) keep) =>
      List.unmodifiable([for (var t = 0; t < tiles; t++) if (keep(t)) t]);

  final String floorId;
  final int width;
  final int height;
  final Set<int> _blocked;

  /// Every pair of adjacent tiles a wall stands between. See [canPassThrough].
  final Set<int> _edges;

  final Set<int> _private;

  /// Every tile covered by an area other than the base one: the office's footprint.
  ///
  /// The base area is the whole grid, so it says nothing about where the building
  /// is. Empty for a space that defines no other areas — see the constructor.
  final Set<int> _inside;

  /// Tiles you sit down on: a chair's `sittable` points, placed the same way its
  /// collision points are, against the way that chair is turned.
  ///
  /// Not a physical fact like [walkable] and not manners like [open] — it is what
  /// somebody standing here *looks* like. The client keeps `playerState` for this
  /// and never sends it, so a second client has to work it out the way Gather does:
  /// you are sitting when you are standing on a seat.
  ///
  /// The value is the chair's `CatalogItemVariant.orientation` — `Up`, `Down`,
  /// `Left` or `Right`, the same words `SpaceUser.direction` uses — and null for a
  /// variant that does not name one. All 115 sittable variants on the measured space
  /// do. See [seatFacing].
  final Map<int, String?> _seats;

  final List<SpaceRoom> rooms;

  /// Every tile a body physically fits on, as `y * width + x`. Furniture removed;
  /// walls are not furniture and do not appear here.
  final List<int> walkable;

  /// Where party mode is willing to go: [walkable], inside the building, and out of
  /// the rooms people close behind them. Materialised once per rebuild because it is
  /// read four times a second.
  final List<int> open;

  int get tiles => width * height;
  int get blockedCount => _blocked.length;

  bool isWalkable(int x, int y) =>
      x >= 0 && y >= 0 && x < width && y < height && !_blocked.contains(y * width + x);

  /// How many walls there are to walk into. Diagnostics.
  int get edgeCount => _edges.length;

  /// Whether a body may cross the line between two adjacent tiles.
  ///
  /// `Collisions.canPassThrough`, which asks its set both ways round:
  ///
  /// ```js
  /// canPassThrough(A, e) {
  ///   const g = A.hashPair(e); const t = e.hashPair(A);
  ///   return !this.blockedDirections.has(g) && !this.blockedDirections.has(t)
  /// }
  /// ```
  ///
  /// So a wall is a property of the line, not of a direction of travel: it stops you
  /// leaving a room exactly as firmly as it stops you walking in. [_edgeKey] gets the
  /// same answer by naming the line once instead of storing both orderings.
  ///
  /// Only meaningful for neighbours. Two tiles that are not adjacent have no line
  /// between them for a wall to stand on, and this says so by answering true.
  bool canPassThrough(int ax, int ay, int bx, int by) {
    final key = _edgeKey(ax, ay, bx, by);
    return key == null || !_edges.contains(key);
  }

  /// Whether somebody standing on a tile may take one step [direction].
  ///
  /// The three rules the client applies before it sends `move`, and the reason it has
  /// to: the `move` action's own body is `position += direction.toPositionDelta()`
  /// with no check of any kind, so a client that does not ask this walks through
  /// furniture and out of the building.
  ///
  /// Off the grid, into furniture, or through a wall. In that order, because the
  /// first two are cheap and the third is the only one that needs the edge set.
  bool canStep(int x, int y, String direction) {
    final step = stepOf(direction);
    if (step == null) return false;
    final tx = x + step.dx;
    final ty = y + step.dy;
    if (!isWalkable(tx, ty)) return false;
    return canPassThrough(x, y, tx, ty);
  }

  /// The line between two adjacent tiles, named once.
  ///
  /// Recorded against the further of the pair — its north side when they are stacked,
  /// its west side when they are side by side — so `(a, b)` and `(b, a)` are the same
  /// line and the set needs one entry rather than two. Null when the pair are not
  /// neighbours, or when the tile the line belongs to is off the grid, which is a line
  /// nobody can be standing on either side of.
  int? _edgeKey(int ax, int ay, int bx, int by) {
    final dx = bx - ax;
    final dy = by - ay;
    final horizontal = dy == 0 && (dx == 1 || dx == -1);
    final vertical = dx == 0 && (dy == 1 || dy == -1);
    if (!horizontal && !vertical) return null;

    final x = horizontal ? (ax > bx ? ax : bx) : ax;
    final y = horizontal ? ay : (ay > by ? ay : by);
    if (x < 0 || y < 0 || x >= width || y >= height) return null;
    return (y * width + x) * 2 + (horizontal ? 1 : 0);
  }

  /// Inside a closed room: standable, but not somewhere to teleport for fun.
  bool isPrivate(int x, int y) => _private.contains(y * width + x);

  /// Whether somebody standing here is sitting down. See [_seats].
  bool isSeat(int x, int y) => _seats.containsKey(y * width + x);

  /// Which way the chair on this tile is turned, if it says.
  ///
  /// A sitter faces their chair, not wherever they were walking when they reached it.
  /// `applySittingDirection` is the client turning them:
  ///
  /// ```js
  /// const seat = user.sittableAtPosition; if (!seat) return;
  /// const facing = CATALOG_ORIENTATION_TO_MOVE_DIRECTION[seat.orientation];
  /// if (facing === user.direction.value) return;
  /// user.faceDirection(facing);
  /// ```
  ///
  /// and that table is the identity — `Up→Up`, `Down→Down`, `Left→Left`,
  /// `Right→Right`. It runs on `currentSpaceUser` only, so the turn reaches the wire
  /// as a *separate* patch from the position, one that another client may not have
  /// yet — which is why somebody freshly sat down can be seen facing the way they
  /// walked in. The chair is the reliable answer, and it is the one Gather draws.
  String? seatFacing(int x, int y) => _seats[y * width + x];

  int get seatCount => _seats.length;

  /// Inside the office rather than the emptiness around it.
  bool isInside(int x, int y) =>
      _inside.isEmpty || _inside.contains(y * width + x);

  /// How many tiles the building covers. Diagnostics, and the thing to look at when
  /// a party says it has nowhere to go.
  int get insideCount => _inside.isEmpty ? walkable.length : _inside.length;

  int xOf(int tile) => tile % width;
  int yOf(int tile) => tile ~/ width;

  /// The smallest named room containing a tile, for labelling a position.
  SpaceRoom? roomAt(int x, int y) {
    SpaceRoom? best;
    for (final room in rooms) {
      if (room.name == null || !room.contains(x, y)) continue;
      if (best == null || room.width * room.height < best.width * best.height) {
        best = room;
      }
    }
    return best;
  }
}

/// Accumulates the map models as patches arrive, and rebuilds when they change.
///
/// Rebuilding is lazy: a full state dump applies ~2200 map patches, and rebuilding
/// on each would be 2200 sweeps of a 10168-tile grid to reach the same answer as
/// one.
class SpaceMapBuilder {
  final Map<String, Map<String, Object?>> _areas = {};
  final Map<String, Map<String, Object?>> _objects = {};
  final Map<String, Map<String, Object?>> _variants = {};
  final Map<String, Map<String, Object?>> _items = {};
  final Map<String, Map<String, Object?>> _floors = {};

  bool _dirty = true;
  Map<String, SpaceMap> _maps = const {};

  /// `'<floorId>/<dark>'` -> artwork. Thrown away whenever a patch lands, on the
  /// same reasoning as [_dirty]: a moved chair changes where it is drawn.
  final Map<String, SpaceArt> _art = {};

  /// Whether anything has arrived at all. False means "no map yet", which is a
  /// different thing from "a map with nothing in it".
  bool get hasData => _floors.isNotEmpty && _areas.isNotEmpty;

  /// floorId -> map. Rebuilt on demand.
  Map<String, SpaceMap> get maps {
    if (_dirty) {
      _maps = _build();
      _dirty = false;
    }
    return _maps;
  }

  SpaceMap? forFloor(String? floorId) {
    final all = maps;
    if (all.isEmpty) return null;
    // Not knowing which floor you are on is different from being on one we have no
    // map for. The first is normal in a single-floor space and the only map is the
    // right answer; the second means the map we hold is somebody else's floor, and
    // handing it over would place walls that are not there.
    if (floorId == null) return all.length == 1 ? all.values.first : null;
    return all[floorId];
  }

  /// The same floor, drawn rather than measured: see `space_art.dart`.
  ///
  /// Separate from [forFloor] because the two answer different questions and change
  /// at different rates — walkability is consumed four times a second by party mode,
  /// artwork once per screen. Cached per floor *and* per theme, since a space that
  /// switches appearance re-resolves every filename.
  SpaceArt? artFor(String? floorId, {bool dark = true}) {
    final map = forFloor(floorId);
    if (map == null) return null;
    return _art.putIfAbsent('${map.floorId}/$dark', () => _buildArt(map, dark: dark));
  }

  Map<String, Map<String, Object?>>? _storeFor(String model) => switch (model) {
        'MapArea' => _areas,
        'MapObject' => _objects,
        'CatalogItemVariant' => _variants,
        'CatalogItem' => _items,
        'FloorMap' => _floors,
        _ => null,
      };

  /// Returns whether this patch could have changed the map.
  bool apply(String model, Map<String, Object?> patch) {
    final store = _storeFor(model);
    if (store == null) return false;

    switch (patch['op']) {
      case 'addmodel':
        final data = patch['data'];
        if (data is! Map<String, Object?>) return false;
        final id = data['id'];
        if (id is! String) return false;
        store[id] = {...data};
      case 'deletemodel':
        final id = patch['id'];
        if (id is! String || store.remove(id) == null) return false;
      case 'replace':
        // Map edits arrive as field patches like `/relativeX` — a dragged object
        // does not resend the row.
        final id = patch['id'];
        final row = id is String ? store[id] : null;
        if (row == null) return false;
        final segments = (patch['path'] as String? ?? '')
            .split('/')
            .where((s) => s.isNotEmpty)
            .toList();
        if (segments.isEmpty) return false;
        if (segments.length == 1) {
          row[segments.first] = patch['data'];
        } else {
          final nested = row[segments.first];
          if (nested is! Map<String, Object?>) return false;
          row[segments.first] = {...nested, segments[1]: patch['data']};
        }
      default:
        return false;
    }

    _dirty = true;
    _art.clear();
    return true;
  }

  // ---- the client's getters, transcribed ---------------------------------------

  static num? _num(Object? value) => value is num ? value : null;

  static String? _str(Object? value) => value is String ? value : null;

  /// A row is live unless it carries a deletion timestamp. Absent fields decode to
  /// msgpack's undefined, which is not a String, so this is a positive test.
  static bool _live(Map<String, Object?> row) => row['deletedAt'] is! String;

  /// `MapEntity#absolutePosition` — the parent chain summed, nothing rounded.
  ({double x, double y})? _absolute(Map<String, Object?> row, [int depth = 0]) {
    if (depth > _maxHierarchyDepth) return null;
    final x = (_num(row['relativeX']) ?? 0).toDouble();
    final y = (_num(row['relativeY']) ?? 0).toDouble();

    final parentId = _str(row['parentObjectId']) ?? _str(row['parentAreaId']);
    if (parentId == null) return (x: x, y: y);

    final parent = _objects[parentId] ?? _areas[parentId];
    if (parent == null) return null;
    final up = _absolute(parent, depth + 1);
    return up == null ? null : (x: up.x + x, y: up.y + y);
  }

  /// `MapObject#topLeftAbsolutePosition` — the sprite's anchor backed out.
  ({double x, double y})? _topLeft(
    Map<String, Object?> object,
    Map<String, Object?> variant,
  ) {
    final at = _absolute(object);
    if (at == null) return null;
    return (
      x: at.x - (_num(variant['originX']) ?? 0) / _tileSize,
      y: at.y - (_num(variant['originY']) ?? 0) / _tileSize,
    );
  }

  /// `MapObject#absoluteCollisionPositionHashes`, or the `sittable` equivalent.
  List<({int x, int y})> _pointsOf(
    Map<String, Object?> object,
    Map<String, Object?> variant,
    String field,
  ) {
    final shape = variant[field];
    final points = shape is Map<String, Object?> ? shape['points'] : null;
    if (points is! List || points.isEmpty) return const [];
    final tl = _topLeft(object, variant);
    if (tl == null) return const [];
    return [
      for (final point in points)
        if (point is Map<String, Object?>)
          (
            x: (tl.x + (_num(point['x']) ?? 0)).round(),
            y: (tl.y + (_num(point['y']) ?? 0)).round(),
          ),
    ];
  }

  static bool _sameRow(List<({int x, int y})> tiles) =>
      tiles.isNotEmpty && tiles.every((t) => t.y == tiles.first.y);

  /// `MapObject#canSnapToWalls`.
  bool _canSnapToWalls(Map<String, Object?> object, Map<String, Object?> variant) {
    final areaId = _str(object['parentAreaId']);
    final area = areaId == null ? null : _areas[areaId];
    if (area == null || area['wallsTexture'] == _noWall) return false;

    final itemId = _str(variant['catalogItemId']);
    final family = itemId == null ? null : _str(_items[itemId]?['family']);
    if (family == 'Chair' || family == 'Desk') return false;

    final collision = _pointsOf(object, variant, 'collision');
    if (collision.isNotEmpty) return _sameRow(collision);
    final sittable = _pointsOf(object, variant, 'sittable');
    if (sittable.isNotEmpty) return _sameRow(sittable);
    return false;
  }

  /// `MapObject#isSpecialEffectActive` — `!parentObjectId && !isSnappedToWall`.
  ///
  /// Anything standing on something else, or flush against a wall, contributes no
  /// collision at all. 78 of the 352 colliding objects on the measured space.
  bool _collides(Map<String, Object?> object, Map<String, Object?> variant) {
    if (_str(object['parentObjectId']) != null) return false;
    final snapped = _canSnapToWalls(object, variant) &&
        _str(object['parentAreaId']) != null &&
        (_num(object['relativeY']) ?? 0).floor() == 0;
    return !snapped;
  }

  // ---- artwork -------------------------------------------------------------------

  /// How deep in the parent chain a row sits. `MapEntity#depth`, which only breaks
  /// ties between floors that end on the same row.
  int _nesting(Map<String, Object?> row, [int depth = 0]) {
    if (depth >= _maxHierarchyDepth) return depth;
    final parentId = _str(row['parentObjectId']) ?? _str(row['parentAreaId']);
    final parent = parentId == null ? null : (_objects[parentId] ?? _areas[parentId]);
    return parent == null ? depth : _nesting(parent, depth + 1);
  }

  /// `MapArea#doorwayPositionHashes`, in tiles relative to the area.
  ///
  /// Each location is two tiles — right for `Horizontal`, down for `Vertical` — and
  /// a wall piece is simply not drawn on either of them, which is what makes a door
  /// a gap rather than a picture of a door.
  Set<int> _doorways(Map<String, Object?> area, int width) {
    final doorways = area['doorways'];
    final locations = doorways is Map<String, Object?> ? doorways['locations'] : null;
    if (locations is! List) return const {};

    final tiles = <int>{};
    for (final location in locations) {
      if (location is! Map<String, Object?>) continue;
      final origin = location['origin'];
      if (origin is! Map<String, Object?>) continue;
      final x = _num(origin['x'])?.toInt();
      final y = _num(origin['y'])?.toInt();
      if (x == null || y == null) continue;
      final horizontal = _str(location['orientation']) == 'Horizontal';
      tiles.add(y * width + x);
      tiles.add(horizontal ? y * width + x + 1 : (y + 1) * width + x);
    }
    return tiles;
  }

  /// Every line a walled area's perimeter draws between two tiles.
  ///
  /// `Collisions.addArea`, transcribed. Its shape is worth keeping in view because two
  /// details of it are not what the wall *art* would lead you to expect:
  ///
  /// ```js
  /// addArea(A) {
  ///   if (!A.isWalled) return;
  ///   const e = A.absolutePosition;
  ///   const g = new Set(A.doorwayPositionHashes);
  ///   for (let t = 0; t < A.dimensionsInTiles.width; t++) {
  ///     if (t === 0 || t === A.dimensionsInTiles.width - 1) {
  ///       for (let I = 0; I < A.dimensionsInTiles.height; I++) {
  ///         if (g.has(Position.hashOf({x: t, y: I}))) continue;
  ///         const i = Position.hashOf({x: e.x + t, y: e.y + I});
  ///         if (t === 0) {
  ///           const g = Position.hashOf({x: e.x + t - 1, y: e.y + I});
  ///           this.addBlockedDirection(A.id, g, i)
  ///         } else if (t === A.dimensionsInTiles.width - 1) {
  ///           const g = Position.hashOf({x: e.x + t + 1, y: e.y + I});
  ///           this.addBlockedDirection(A.id, g, i)
  ///         }
  ///       }
  ///     }
  ///     if (!g.has(Position.hashOf({x: t, y: 0}))) {
  ///       this.addBlockedDirection(A.id,
  ///         Position.hashOf({x: e.x + t, y: e.y}),
  ///         Position.hashOf({x: e.x + t, y: e.y - 1}))
  ///     }
  ///     if (!g.has(Position.hashOf({x: t, y: A.dimensionsInTiles.height - 1}))) {
  ///       this.addBlockedDirection(A.id,
  ///         Position.hashOf({x: e.x + t, y: e.y + A.dimensionsInTiles.height - 1}),
  ///         Position.hashOf({x: e.x + t, y: e.y + A.dimensionsInTiles.height}))
  ///     }
  ///   }
  /// }
  /// ```
  ///
  /// **The side walls run the full height**, `I` from 0 to `height - 1`. The drawing
  /// loop in `space_art.dart` stops three short of it, because the north and south
  /// bands are two tiles tall and cover the corners visually. Collision has no bands
  /// and no corners to cover, so copying the art's range would leave a walkable gap at
  /// the bottom of every room in the office.
  ///
  /// **The doorway hashes are relative to the area**, so they are indexed by the
  /// area's own width — which is what [_doorways] already returns. Two of the three
  /// lookups here use a relative coordinate against a *relative* stride, and the third
  /// (`{x: t, y: 0}`) is just `t`.
  void _wallEdges({
    required Map<String, Object?> area,
    required int x0,
    required int y0,
    required int w,
    required int h,
    required int width,
    required int height,
    required Set<int> edges,
  }) {
    final doorways = _doorways(area, w);

    void add(int ax, int ay, int bx, int by) {
      final horizontal = ay == by;
      final x = horizontal ? (ax > bx ? ax : bx) : ax;
      final y = horizontal ? ay : (ay > by ? ay : by);
      // A line whose own tile is off the grid is one nobody can stand on either side
      // of — the map bounds refuse that step long before the wall would.
      if (x < 0 || y < 0 || x >= width || y >= height) return;
      edges.add((y * width + x) * 2 + (horizontal ? 1 : 0));
    }

    for (var t = 0; t < w; t++) {
      if (t == 0 || t == w - 1) {
        for (var i = 0; i < h; i++) {
          if (doorways.contains(i * w + t)) continue;
          final wallX = x0 + t;
          final wallY = y0 + i;
          add(t == 0 ? wallX - 1 : wallX + 1, wallY, wallX, wallY);
        }
      }
      if (!doorways.contains(t)) {
        add(x0 + t, y0, x0 + t, y0 - 1);
      }
      if (!doorways.contains((h - 1) * w + t)) {
        add(x0 + t, y0 + h - 1, x0 + t, y0 + h);
      }
    }
  }

  /// `updateDepth`: the sprite's fold line, or its parent's with the child's own
  /// tucked in behind the decimal point so a lamp travels with the desk it stands on.
  /// One level deep, exactly as the client does it.
  double _propDepth(Map<String, Object?> object, double topY, num fold) {
    final own = topY * _tileSize + fold;

    final parent = _objects[_str(object['parentObjectId']) ?? ''];
    if (parent == null) return own;
    final parentVariant = _variants[_str(parent['catalogItemVariantId']) ?? ''];
    if (parentVariant == null) return own;
    final parentTopLeft = _topLeft(parent, parentVariant);
    if (parentTopLeft == null) return own;

    final renderable = parentVariant['mainRenderable'];
    final parentFold =
        renderable is Map<String, Object?> ? (_num(renderable['fold']) ?? 0) : 0;
    return parentTopLeft.y * _tileSize + parentFold + own / 1e6;
  }

  SpaceArt _buildArt(SpaceMap map, {required bool dark}) {
    Map<String, Object?>? floor;
    for (final row in _floors.values) {
      if (_live(row) && row['floorId'] == map.floorId) {
        floor = row;
        break;
      }
    }
    final mapId = floor?['id'];
    if (mapId is! String) {
      return SpaceArt(
        width: (map.width * _tileSize).toDouble(),
        height: (map.height * _tileSize).toDouble(),
        ground: const [],
        props: const [],
      );
    }
    final baseId = _str(floor?['baseAreaId']);

    final ground = <ArtGround>[];
    final props = <ArtSprite>[];

    // Paint order for the ground, which is a lookup and not a coordinate: the base
    // area first, then `Public` zones, then rooms and desks. Within a layer, nesting
    // and then the bottom edge — `updateFloorsDepth`'s two tiebreaks, in its order.
    final areas = [
      for (final area in _areas.values)
        if (area['mapId'] == mapId && _live(area)) area,
    ];
    int layerOf(Map<String, Object?> area) => area['id'] == baseId
        ? 0
        : _str(area['mapAreaType']) == 'Public'
            ? 2
            : 4;
    double bottomOf(Map<String, Object?> area) {
      final dims = area['dimensionsInTiles'];
      final at = _absolute(area);
      if (dims is! Map<String, Object?> || at == null) return 0;
      return (at.y + (_num(dims['height']) ?? 0)) * _tileSize;
    }

    areas.sort((a, b) {
      final layer = layerOf(a).compareTo(layerOf(b));
      if (layer != 0) return layer;
      final nesting = _nesting(a).compareTo(_nesting(b));
      if (nesting != 0) return nesting;
      return bottomOf(a).compareTo(bottomOf(b));
    });

    for (final area in areas) {
      final dims = area['dimensionsInTiles'];
      if (dims is! Map<String, Object?>) continue;
      final at = _absolute(area);
      if (at == null) continue;

      final tilesWide = _num(dims['width'])?.toInt() ?? 0;
      final tilesHigh = _num(dims['height'])?.toInt() ?? 0;
      if (tilesWide <= 0 || tilesHigh <= 0) continue;

      final left = at.x * _tileSize;
      final top = at.y * _tileSize;
      final width = (tilesWide * _tileSize).toDouble();
      final height = (tilesHigh * _tileSize).toDouble();

      final url = floorImageUrl(
        _str(area['floorTexture']),
        _str(area['floorColor']),
        dark: dark,
      );
      if (url != null) {
        ground.add(ArtFloor(
          url: url,
          left: left,
          top: top,
          width: width,
          height: height,
        ));
      }

      // The base area is the grid, and grids have no walls; `wallsTexture` on it is
      // `NewStyleNoWall` anyway, but saying so here means one less thing to be
      // surprised by.
      final style = _str(area['wallsTexture']);
      if (area['id'] == baseId || style == null || style == _noWall) continue;

      final doorways = _doorways(area, tilesWide);
      // North and south bands are two tiles tall and own the corners; the sides run
      // between them, which is why they stop at `tilesHigh - 3`.
      const bandHeight = _tileSize * 2;
      for (var x = 0; x < tilesWide; x++) {
        final north = x == 0
            ? WallPiece.northWest
            : x == tilesWide - 1
                ? WallPiece.northEast
                : WallPiece.north;
        final south = x == 0
            ? WallPiece.southWest
            : x == tilesWide - 1
                ? WallPiece.southEast
                : WallPiece.south;

        if (!doorways.contains(x)) {
          final url = wallImageUrl(style, north, dark: dark);
          if (url != null) {
            props.add(ArtSprite(
              url: url,
              left: left + x * _tileSize,
              // Above the area's first row: `northEdge.setPosition(0, -nw)`.
              top: top - bandHeight,
              width: _tileSize.toDouble(),
              height: bandHeight.toDouble(),
              // `QS(container.y + .1)` — the area's own top line, so the band covers
              // whatever stands north of the room and nothing inside it.
              depth: top + 0.1,
            ));
          }
        }
        if (!doorways.contains((tilesHigh - 1) * tilesWide + x)) {
          final url = wallImageUrl(style, south, dark: dark);
          if (url != null) {
            props.add(ArtSprite(
              url: url,
              left: left + x * _tileSize,
              top: top + height - bandHeight,
              width: _tileSize.toDouble(),
              height: bandHeight.toDouble(),
              // `QS(container.y + height * TILE_SIZE)` — the area's bottom line. The
              // band is two tiles tall and its bottom sits on that line, so it hangs
              // over the room's last two rows and is drawn over what stands in them.
              depth: top + height,
            ));
          }
        }
      }

      for (var y = 0; y < tilesHigh - 2; y++) {
        for (final (piece, column) in [
          (WallPiece.west, 0),
          (WallPiece.east, tilesWide - 1),
        ]) {
          if (tilesWide == 1 && piece == WallPiece.east) continue;
          if (doorways.contains(y * tilesWide + column)) continue;
          final url = wallImageUrl(style, piece, dark: dark);
          if (url == null) continue;
          ground.add(ArtWall(
            url: url,
            left: left + column * _tileSize,
            top: top + y * _tileSize,
            width: _tileSize.toDouble(),
            height: _tileSize.toDouble(),
          ));
        }
      }
    }

    for (final object in _objects.values) {
      if (object['mapId'] != mapId || !_live(object)) continue;
      final variant = _variants[_str(object['catalogItemVariantId']) ?? ''];
      if (variant == null) continue;
      final topLeft = _topLeft(object, variant);
      if (topLeft == null) continue;

      final dims = variant['dimensionsInPixels'];
      final width =
          dims is Map<String, Object?> ? (_num(dims['width']) ?? 0).toDouble() : 0.0;
      final height =
          dims is Map<String, Object?> ? (_num(dims['height']) ?? 0).toDouble() : 0.0;

      final item = _items[_str(variant['catalogItemId']) ?? ''];
      final authoredAt = _str(item?['lastSyncAuthoredAt']);

      for (final (field, foreground) in [
        ('mainRenderable', false),
        ('foregroundRenderable', true),
      ]) {
        final renderable = variant[field];
        if (renderable is! Map<String, Object?>) continue;
        final url = catalogImageUrl(_str(renderable['imageUrl']), authoredAt: authoredAt);
        if (url == null) continue;

        props.add(ArtSprite(
          url: url,
          left: topLeft.x * _tileSize,
          top: topLeft.y * _tileSize,
          width: width,
          height: height,
          depth: _propDepth(object, topLeft.y, _num(renderable['fold']) ?? 0),
          foreground: foreground,
        ));
      }
    }

    // The ground is already in order — it was built area by area in it. Only the
    // furniture needs sorting, and it sorts by its fold line.
    props.sort((a, b) => a.depth.compareTo(b.depth));

    return SpaceArt(
      width: (map.width * _tileSize).toDouble(),
      height: (map.height * _tileSize).toDouble(),
      ground: List.unmodifiable(ground),
      props: List.unmodifiable(props),
    );
  }

  // ---- building ----------------------------------------------------------------

  Map<String, SpaceMap> _build() {
    final out = <String, SpaceMap>{};

    for (final floor in _floors.values) {
      if (!_live(floor)) continue;
      final mapId = floor['id'];
      final floorId = floor['floorId'];
      final baseId = floor['baseAreaId'];
      if (mapId is! String || floorId is! String || baseId is! String) continue;

      final base = _areas[baseId];
      final size = base?['dimensionsInTiles'];
      if (size is! Map<String, Object?>) continue;
      final width = _num(size['width'])?.toInt() ?? 0;
      final height = _num(size['height'])?.toInt() ?? 0;
      if (width <= 0 || height <= 0) continue;

      final blocked = <int>{};
      final edges = <int>{};
      final private = <int>{};
      final inside = <int>{};
      final seats = <int, String?>{};
      final rooms = <SpaceRoom>[];

      // Furniture, and only furniture. Walls are directions, not tiles — see the
      // library doc — so nothing here paints a perimeter.
      for (final object in _objects.values) {
        if (object['mapId'] != mapId || !_live(object)) continue;
        final variantId = _str(object['catalogItemVariantId']);
        final variant = variantId == null ? null : _variants[variantId];
        if (variant == null || !_collides(object, variant)) continue;
        for (final tile in _pointsOf(object, variant, 'collision')) {
          if (tile.x < 0 || tile.y < 0 || tile.x >= width || tile.y >= height) continue;
          blocked.add(tile.y * width + tile.x);
        }
        // `activeSittableAbsoluteTiles` — the same placement and the same
        // `isSpecialEffectActive` gate the collision tiles get, which is why this
        // shares the loop rather than repeating it.
        for (final tile in _pointsOf(object, variant, 'sittable')) {
          if (tile.x < 0 || tile.y < 0 || tile.x >= width || tile.y >= height) continue;
          // Which way the chair is turned, kept with the tile: it is what the sitter
          // is drawn facing. See [SpaceMap.seatFacing].
          seats[tile.y * width + tile.x] = _str(variant['orientation']);
        }
      }

      for (final area in _areas.values) {
        if (area['mapId'] != mapId || !_live(area)) continue;
        final id = _str(area['id']);
        final dims = area['dimensionsInTiles'];
        if (id == null || dims is! Map<String, Object?>) continue;
        final at = _absolute(area);
        if (at == null) continue;

        final w = _num(dims['width'])?.toInt() ?? 0;
        final h = _num(dims['height'])?.toInt() ?? 0;
        if (w <= 0 || h <= 0) continue;
        final x0 = at.x.round();
        final y0 = at.y.round();
        final type = _str(area['mapAreaType']) ?? 'Public';
        final walled = id != baseId && area['wallsTexture'] != _noWall;

        rooms.add(SpaceRoom(
          id: id,
          name: _str(area['name']),
          type: type,
          x: x0,
          y: y0,
          width: w,
          height: h,
          walled: walled,
        ));

        if (walled) {
          _wallEdges(
            area: area,
            x0: x0,
            y0: y0,
            w: w,
            h: h,
            width: width,
            height: height,
            edges: edges,
          );
        }

        // The base area is the grid itself. Counting it as building would make the
        // whole map "inside", which is the thing the footprint exists to disprove.
        if (id == baseId) continue;

        // Neither of these is collision — both are manners. Being inside the office
        // at all, and staying out of the rooms people shut behind them.
        final closed = walled && _privateTypes.contains(type);
        for (var y = y0; y < y0 + h; y++) {
          if (y < 0 || y >= height) continue;
          for (var x = x0; x < x0 + w; x++) {
            if (x < 0 || x >= width) continue;
            inside.add(y * width + x);
            if (closed) private.add(y * width + x);
          }
        }
      }

      out[floorId] = SpaceMap(
        floorId: floorId,
        width: width,
        height: height,
        blocked: blocked,
        edges: edges,
        private: private,
        inside: inside,
        seats: seats,
        rooms: rooms,
      );
    }

    return out;
  }
}
