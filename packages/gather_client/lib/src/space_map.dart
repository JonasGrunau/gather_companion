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
/// 488 perimeter tiles this used to exclude are perfectly good floor. Since party
/// mode teleports rather than walks, blocked directions never apply to it at all.
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
  })  : _blocked = blocked,
        _private = private ?? const {},
        _inside = inside ?? const {},
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
  final Set<int> _private;

  /// Every tile covered by an area other than the base one: the office's footprint.
  ///
  /// The base area is the whole grid, so it says nothing about where the building
  /// is. Empty for a space that defines no other areas — see the constructor.
  final Set<int> _inside;

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

  /// Inside a closed room: standable, but not somewhere to teleport for fun.
  bool isPrivate(int x, int y) => _private.contains(y * width + x);

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
      final private = <int>{};
      final inside = <int>{};
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
        private: private,
        inside: inside,
        rooms: rooms,
      );
    }

    return out;
  }
}
