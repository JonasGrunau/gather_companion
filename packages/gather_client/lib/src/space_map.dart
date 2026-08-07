/// The floor plan, read off the game socket.
///
/// Gather never serves the map over REST — `/spaces/<id>/maps`, `/floors` and
/// `/map` all 404. It does not need to: **the whole map is already in the state
/// dump**, and until now this client threw it away. Three models carry it, and the
/// counts are from the 124×82 space this was built against:
///
///  - **`FloorMap`** names the base `MapArea` (`baseAreaId`) and the floor the map
///    belongs to. One per floor.
///  - **`MapArea`** ×93 — rectangles. The base area is the grid itself
///    (`dimensionsInTiles` 124×82); the rest are rooms, desks and team zones, each
///    positioned by `relativeX`/`relativeY` against a parent area. Area origins are
///    always whole tiles.
///  - **`MapObject`** ×1140 — furniture, positioned the same way but against an
///    area *or* another object, and at sub-tile precision. Each names a
///    `CatalogItemVariant`.
///  - **`CatalogItemVariant`** ×477 — the shapes. `collision.points` is a list of
///    tile offsets the object blocks. 341 of the 477 block nothing at all (rugs,
///    posters, things on top of desks); the rest block one to six tiles.
///
/// ## Two kinds of obstacle
///
/// **Furniture** is the object collision above. **Walls** are not objects at all —
/// they are a property of an area: `wallsTexture` is `NewStyleNoWall` for the 74
/// areas that are only logical groupings (a desk cluster, a team's zone), and a
/// real texture for the 17 that are rooms. A room's walls are its perimeter, minus
/// the gaps named in `doorways`, which are two tiles wide.
///
/// Together those give 1012 blocked tiles of 10168 on the measured space — and,
/// checked against the eleven people connected at the time, **not one of them was
/// standing on a tile this calls blocked**. That check is worth keeping: everybody
/// in a space is standing somewhere, so live positions are a free, continuous test
/// of whether the decoding is right.
///
/// ## Why the rounding is what it is
///
/// Area origins are whole tiles. Object origins never are — all 1140 carry a
/// fractional offset, because `relativeX`/`relativeY` place a *sprite*, which has
/// its own pixel origin. Collision points are near-integers with the same kind of
/// nudge (`-0.0625`, `0.9375`). Rounding the sum of the two puts people inside
/// walls; flooring the object origin and rounding the offset does not. That was
/// settled by sweeping every combination against the live roster, not by reasoning
/// about it — see `tool/probe-connect.mjs walkable`.
library;

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

  /// Whether this area draws walls, and therefore blocks its own perimeter.
  final bool walled;

  bool contains(int tx, int ty) =>
      tx >= x && tx < x + width && ty >= y && ty < y + height;
}

/// One floor, as a grid of tiles you can and cannot stand on.
class SpaceMap {
  SpaceMap({
    required this.floorId,
    required this.width,
    required this.height,
    required Set<int> blocked,
    required this.rooms,
  })  : _blocked = blocked,
        walkable = List.unmodifiable([
          for (var y = 0; y < height; y++)
            for (var x = 0; x < width; x++)
              if (!blocked.contains(y * width + x)) y * width + x,
        ]);

  final String floorId;
  final int width;
  final int height;
  final Set<int> _blocked;
  final List<SpaceRoom> rooms;

  /// Every walkable tile, as `y * width + x`.
  ///
  /// Materialised once per rebuild rather than recomputed: party mode reads it
  /// four times a second and the map changes only when somebody edits it.
  final List<int> walkable;

  int get tiles => width * height;
  int get blockedCount => _blocked.length;

  bool isWalkable(int x, int y) =>
      x >= 0 && y >= 0 && x < width && y < height && !_blocked.contains(y * width + x);

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
/// Kept separate from `GameProtocolReader` because the lifecycles differ: the
/// roster changes several times a second and the map changes when somebody drags a
/// plant, which in most spaces is never. Rebuilding is therefore lazy — a full
/// state dump applies ~1700 map patches, and rebuilding on each would be 1700
/// sweeps of a 10168-tile grid to produce the same answer as one.
class SpaceMapBuilder {
  /// Wall texture meaning "this area is a grouping, not a room".
  static const _noWall = 'NewStyleNoWall';

  final Map<String, Map<String, Object?>> _areas = {};
  final Map<String, Map<String, Object?>> _objects = {};
  final Map<String, Map<String, Object?>> _variants = {};
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

  // ---- building --------------------------------------------------------------

  static num? _num(Object? value) => value is num ? value : null;

  /// Absolute tile position, following `parentObjectId` then `parentAreaId` up to
  /// the base area.
  ///
  /// Returns null when the chain cannot be resolved. That matters: a missing
  /// parent means an unknown offset, and an object placed at the wrong offset is a
  /// wall in the wrong place. Dropping it leaves a tile walkable that is not,
  /// which a person walks around; inventing one leaves a tile blocked that is fine,
  /// which party mode would simply never use. Neither is good, but only one of them
  /// is silent.
  ({double x, double y})? _originOf(Map<String, Object?> row, [int depth = 0]) {
    if (depth > 32) return null; // a cycle in the parent chain
    final x = (_num(row['relativeX']) ?? 0).toDouble();
    final y = (_num(row['relativeY']) ?? 0).toDouble();

    final parentObject = row['parentObjectId'];
    final parentArea = row['parentAreaId'];
    final parentId = parentObject is String
        ? parentObject
        : parentArea is String
            ? parentArea
            : null;
    if (parentId == null) return (x: x, y: y);

    final parent = _objects[parentId] ?? _areas[parentId];
    if (parent == null) return null;
    final up = _originOf(parent, depth + 1);
    return up == null ? null : (x: up.x + x, y: up.y + y);
  }

  /// A row is live unless it carries a deletion timestamp. Absent fields decode to
  /// msgpack's undefined, which is not a String, so this is a positive test.
  static bool _live(Map<String, Object?> row) => row['deletedAt'] is! String;

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
      final rooms = <SpaceRoom>[];
      void block(int x, int y) {
        if (x < 0 || y < 0 || x >= width || y >= height) return;
        blocked.add(y * width + x);
      }

      // 1. Furniture.
      for (final object in _objects.values) {
        if (object['mapId'] != mapId || !_live(object)) continue;
        final variantId = object['catalogItemVariantId'];
        final variant = variantId is String ? _variants[variantId] : null;
        final collision = variant?['collision'];
        final points = collision is Map<String, Object?> ? collision['points'] : null;
        if (points is! List || points.isEmpty) continue;

        final at = _originOf(object);
        if (at == null) continue;
        // Floor the origin, round the offset — see the library doc.
        final ox = at.x.floor();
        final oy = at.y.floor();
        for (final point in points) {
          if (point is! Map<String, Object?>) continue;
          block(
            ox + (_num(point['x']) ?? 0).round(),
            oy + (_num(point['y']) ?? 0).round(),
          );
        }
      }

      // 2. Rooms, and the walls of the ones that have them.
      for (final area in _areas.values) {
        if (area['mapId'] != mapId || !_live(area)) continue;
        final id = area['id'];
        final dims = area['dimensionsInTiles'];
        if (id is! String || dims is! Map<String, Object?>) continue;
        final at = _originOf(area);
        if (at == null) continue;

        final w = _num(dims['width'])?.toInt() ?? 0;
        final h = _num(dims['height'])?.toInt() ?? 0;
        if (w <= 0 || h <= 0) continue;
        final x0 = at.x.round();
        final y0 = at.y.round();
        final walled = id != baseId && area['wallsTexture'] != _noWall;

        final name = area['name'];
        rooms.add(SpaceRoom(
          id: id,
          name: name is String ? name : null,
          type: area['mapAreaType'] is String ? area['mapAreaType']! as String : 'Public',
          x: x0,
          y: y0,
          width: w,
          height: h,
          walled: walled,
        ));

        if (!walled) continue;

        // The perimeter, minus the doorways. A doorway is two tiles: its own, and
        // the next one along the wall it sits in.
        final gaps = <int>{};
        final doorways = area['doorways'];
        final locations =
            doorways is Map<String, Object?> ? doorways['locations'] : null;
        if (locations is List) {
          for (final door in locations) {
            if (door is! Map<String, Object?>) continue;
            final at = door['origin'];
            if (at is! Map<String, Object?>) continue;
            final dx = x0 + (_num(at['x']) ?? 0).round();
            final dy = y0 + (_num(at['y']) ?? 0).round();
            gaps.add(dy * width + dx);
            gaps.add(door['orientation'] == 'Vertical'
                ? (dy + 1) * width + dx
                : dy * width + dx + 1);
          }
        }

        void wall(int x, int y) {
          if (x < 0 || y < 0 || x >= width || y >= height) return;
          if (gaps.contains(y * width + x)) return;
          blocked.add(y * width + x);
        }

        for (var x = x0; x < x0 + w; x++) {
          wall(x, y0);
          wall(x, y0 + h - 1);
        }
        for (var y = y0; y < y0 + h; y++) {
          wall(x0, y);
          wall(x0 + w - 1, y);
        }
      }

      out[floorId] = SpaceMap(
        floorId: floorId,
        width: width,
        height: height,
        blocked: blocked,
        rooms: rooms,
      );
    }

    return out;
  }
}
