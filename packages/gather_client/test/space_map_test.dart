/// [SpaceMapBuilder] turns the map models into tiles you can stand on.
///
/// Every rule here is transcribed from Gather's own client bundle, and the tests
/// name the getter they came from. That provenance is the point: the first version
/// of this file inferred the rules statistically instead, scored a perfect zero
/// against the live roster, and was still wrong in 425 of about 500 tiles. Eleven
/// connected people cannot distinguish four contradictory decodings. The bundle
/// can.
library;

import 'package:gather_client/gather_client.dart';
import 'package:test/test.dart';

Map<String, Object?> _add(Map<String, Object?> data) => {'op': 'addmodel', 'data': data};

Map<String, Object?> _dims(int width, int height) =>
    {r'$type': 'Dimensions', 'width': width, 'height': height};

/// A builder holding one floor: a 20×10 base area and nothing else.
SpaceMapBuilder _base({int width = 20, int height = 10}) {
  final b = SpaceMapBuilder();
  b.apply('MapArea', _add({
    'id': 'base',
    'mapId': 'map-1',
    'relativeX': 0,
    'relativeY': 0,
    'dimensionsInTiles': _dims(width, height),
    'mapAreaType': 'Public',
    'wallsTexture': 'NewStyleNoWall',
  }));
  b.apply('FloorMap', _add({
    'id': 'map-1',
    'floorId': 'floor-1',
    'baseAreaId': 'base',
  }));
  return b;
}

/// A variant that blocks the tiles at [points], expressed as `[x, y]` pairs.
///
/// `originX`/`originY` are in pixels and default to zero so most tests can ignore
/// them; the one that cares sets them explicitly.
void _variant(
  SpaceMapBuilder b,
  String id,
  List<List<num>> points, {
  num originX = 0,
  num originY = 0,
  String? family,
  List<List<num>> sittable = const [],
  String? orientation,
}) {
  if (family != null) {
    b.apply('CatalogItem', _add({'id': 'item-$id', 'family': family}));
  }
  b.apply('CatalogItemVariant', _add({
    'id': id,
    'catalogItemId': 'item-$id',
    'originX': originX,
    'originY': originY,
    'orientation': ?orientation,
    'collision': {
      'points': [
        for (final p in points) {'x': p[0], 'y': p[1]},
      ],
    },
    'sittable': {
      'points': [
        for (final p in sittable) {'x': p[0], 'y': p[1]},
      ],
    },
  }));
}

void main() {
  test('an empty floor is entirely walkable', () {
    final map = _base().forFloor('floor-1')!;

    expect(map.width, 20);
    expect(map.height, 10);
    expect(map.tiles, 200);
    expect(map.walkable, hasLength(200));
    expect(map.blockedCount, 0);
  });

  test('no map at all is null rather than an empty one', () {
    // The difference the UI needs: "still loading" and "a floor with nowhere to
    // stand" look identical if this returns an empty map.
    expect(SpaceMapBuilder().forFloor('floor-1'), isNull);
    expect(SpaceMapBuilder().hasData, isFalse);
  });

  group('furniture', () {
    test('blocks the tiles its variant names', () {
      final b = _base();
      _variant(b, 'v1', [
        [0, 0],
        [1, 0],
      ]);
      b.apply('MapObject', _add({
        'id': 'o1',
        'mapId': 'map-1',
        'parentAreaId': 'base',
        'relativeX': 5,
        'relativeY': 3,
        'catalogItemVariantId': 'v1',
      }));

      final map = b.forFloor('floor-1')!;
      expect(map.isWalkable(5, 3), isFalse);
      expect(map.isWalkable(6, 3), isFalse);
      expect(map.isWalkable(7, 3), isTrue);
      expect(map.blockedCount, 2);
    });

    test('a variant that collides with nothing blocks nothing', () {
      // 341 of the 477 variants in the measured space are like this — rugs,
      // posters, things sitting on top of desks. Treating a placed object as an
      // obstacle by default would wall off most of the floor.
      final b = _base();
      _variant(b, 'rug', []);
      b.apply('MapObject', _add({
        'id': 'o1',
        'mapId': 'map-1',
        'parentAreaId': 'base',
        'relativeX': 5,
        'relativeY': 3,
        'catalogItemVariantId': 'rug',
      }));

      expect(b.forFloor('floor-1')!.blockedCount, 0);
    });

    test("the sprite's pixel origin is backed out before rounding", () {
      // MapObject#topLeftAbsolutePosition:
      //   topLeft = absolutePosition - (originX, originY)/TILE_SIZE
      // then absoluteCollisionPositionHashes rounds topLeft + point.
      //
      // x: 5.6484375 - 46/32 = 4.2109; + (-0.0625, 0.9375, 1.9375) -> 4, 5, 6.
      // y: 3.4296875 - 28/32 = 2.5547; + 0                          -> 3.
      // Skipping the origin subtraction puts x at 6, 7, 8 — two tiles out. No
      // amount of staring at coordinates produces this rule; it came from the
      // bundle.
      final b = _base();
      _variant(b, 'desk', [
        [-0.0625, 0],
        [0.9375, 0],
        [1.9375, 0],
      ], originX: 46, originY: 28);
      b.apply('MapObject', _add({
        'id': 'o1',
        'mapId': 'map-1',
        'parentAreaId': 'base',
        'relativeX': 5.6484375,
        'relativeY': 3.4296875,
        'catalogItemVariantId': 'desk',
      }));

      final map = b.forFloor('floor-1')!;
      expect(map.isWalkable(4, 3), isFalse);
      expect(map.isWalkable(5, 3), isFalse);
      expect(map.isWalkable(6, 3), isFalse);
      expect(map.blockedCount, 3, reason: 'a three-tile desk, not four');
      expect(map.isWalkable(7, 3), isTrue);
      expect(map.isWalkable(4, 2), isTrue, reason: '2.55 rounds up, not down');
    });

    test('an object standing on another object does not collide', () {
      // isSpecialEffectActive = !parentObjectId && !isSnappedToWall. A monitor on a
      // desk is the desk's problem, not the floor's — 28 objects on the measured
      // space, and counting them was part of why the old grid was wrong.
      final b = _base();
      _variant(b, 'v1', [
        [0, 0],
      ]);
      b.apply('MapObject', _add({
        'id': 'desk',
        'mapId': 'map-1',
        'parentAreaId': 'base',
        'relativeX': 4,
        'relativeY': 4,
        'catalogItemVariantId': 'nothing',
      }));
      b.apply('MapObject', _add({
        'id': 'monitor',
        'mapId': 'map-1',
        'parentObjectId': 'desk',
        'relativeX': 2,
        'relativeY': 1,
        'catalogItemVariantId': 'v1',
      }));

      expect(b.forFloor('floor-1')!.blockedCount, 0);
    });

    test('an object flush against a room wall does not collide', () {
      // isSnappedToWall: canSnapToWalls && parentAreaId && floor(relativeY) === 0.
      // 50 objects on the measured space.
      final b = _base();
      b.apply('MapArea', _add({
        'id': 'room',
        'mapId': 'map-1',
        'parentAreaId': 'base',
        'relativeX': 2,
        'relativeY': 2,
        'dimensionsInTiles': _dims(6, 6),
        'mapAreaType': 'MeetingRoom',
        'wallsTexture': 'PlainWhite',
      }));
      _variant(b, 'poster', [
        [0, 0],
        [1, 0],
      ], family: 'Wall Decor');
      b.apply('MapObject', _add({
        'id': 'o1',
        'mapId': 'map-1',
        'parentAreaId': 'room',
        'relativeX': 2,
        'relativeY': 0.4,
        'catalogItemVariantId': 'poster',
      }));

      expect(b.forFloor('floor-1')!.blockedCount, 0);
    });

    test('a chair against a wall still collides, because chairs never snap', () {
      final b = _base();
      b.apply('MapArea', _add({
        'id': 'room',
        'mapId': 'map-1',
        'parentAreaId': 'base',
        'relativeX': 2,
        'relativeY': 2,
        'dimensionsInTiles': _dims(6, 6),
        'mapAreaType': 'MeetingRoom',
        'wallsTexture': 'PlainWhite',
      }));
      _variant(b, 'chair', [
        [0, 0],
      ], family: 'Chair');
      b.apply('MapObject', _add({
        'id': 'o1',
        'mapId': 'map-1',
        'parentAreaId': 'room',
        'relativeX': 2,
        'relativeY': 0.4,
        'catalogItemVariantId': 'chair',
      }));

      expect(b.forFloor('floor-1')!.blockedCount, 1);
    });

    test('an unresolvable parent is dropped rather than placed at the origin', () {
      // Guessing would put a wall in the top-left corner of the map, which is both
      // wrong and invisible. Dropping it leaves a real obstacle unmarked, which is
      // the lesser of the two — party mode simply lands somewhere it should not,
      // where the other way it would avoid a corner of the map forever.
      final b = _base();
      _variant(b, 'v1', [
        [0, 0],
      ]);
      b.apply('MapObject', _add({
        'id': 'orphan',
        'mapId': 'map-1',
        'parentObjectId': 'nobody',
        'relativeX': 3,
        'relativeY': 3,
        'catalogItemVariantId': 'v1',
      }));

      expect(b.forFloor('floor-1')!.blockedCount, 0);
    });
  });

  group('rooms', () {
    test('a walled area blocks nothing — walls are directions, not tiles', () {
      final b = _base();
      b.apply('MapArea', _add({
        'id': 'room',
        'mapId': 'map-1',
        'parentAreaId': 'base',
        'relativeX': 2,
        'relativeY': 2,
        'dimensionsInTiles': _dims(4, 4),
        'mapAreaType': 'MeetingRoom',
        'name': 'Content & CM',
        'wallsTexture': 'PlainWhite',
      }));

      // Collisions.addArea records blocked *directions* between the wall tile and
      // the tile outside it; blockedAtPosition consults only the object map. So
      // every one of these is standable, and teleporting ignores walls entirely.
      final map = b.forFloor('floor-1')!;
      expect(map.blockedCount, 0);
      expect(map.isWalkable(2, 2), isTrue, reason: 'corner');
      expect(map.isWalkable(3, 2), isTrue, reason: 'top wall');
      expect(map.isWalkable(3, 3), isTrue, reason: 'inside the room');

      // Standable, but not somewhere to throw a party. That is manners, not physics,
      // and it is a separate list.
      expect(map.isPrivate(3, 3), isTrue);
      expect(map.open, isNot(contains(3 * 20 + 3)));
      expect(map.walkable, contains(3 * 20 + 3));
    });

    test('walls around a zone are the building, not a closed door', () {
      // The bug this fixes. "Walled means private" is Gather's own rule for audio
      // and the wrong rule for a floor plan: the measured office's main room is a
      // walled 44x34 Public area holding 42 of the 112 people, and the Lobby is
      // walled too. Treating those as private deleted the entire office from the
      // party pool and left only the void outside it.
      final b = _base();
      for (final (id, type, x) in [
        ('floor', 'Public', 2),
        ('lobby', 'Lobby', 10),
      ]) {
        b.apply('MapArea', _add({
          'id': id,
          'mapId': 'map-1',
          'parentAreaId': 'base',
          'relativeX': x,
          'relativeY': 2,
          'dimensionsInTiles': _dims(6, 6),
          'mapAreaType': type,
          'wallsTexture': 'PlainWhite',
        }));
      }

      final map = b.forFloor('floor-1')!;
      expect(map.rooms.where((r) => r.walled), hasLength(2), reason: 'both have walls');
      expect(map.isPrivate(3, 3), isFalse, reason: 'a walled Public zone is the office');
      expect(map.isPrivate(11, 3), isFalse, reason: 'so is a walled Lobby');
      expect(map.open, contains(3 * 20 + 3));
      expect(map.open, contains(3 * 20 + 11));
    });

    test('a walled desk booth is somewhere to leave alone', () {
      final b = _base();
      b.apply('MapArea', _add({
        'id': 'booth',
        'mapId': 'map-1',
        'parentAreaId': 'base',
        'relativeX': 2,
        'relativeY': 2,
        'dimensionsInTiles': _dims(4, 4),
        'mapAreaType': 'Desk',
        'wallsTexture': 'PlainWhite',
      }));

      expect(b.forFloor('floor-1')!.isPrivate(3, 3), isTrue);
    });

    test('the emptiness outside the building is not party floor', () {
      // Walls block *directions*, so nothing marks the void impassable and a
      // teleport ignores directions entirely. On the measured space that left 5133
      // of 7315 party tiles outside the office, which is where every hop went.
      final b = _base();
      b.apply('MapArea', _add({
        'id': 'floor',
        'mapId': 'map-1',
        'parentAreaId': 'base',
        'relativeX': 4,
        'relativeY': 2,
        'dimensionsInTiles': _dims(6, 6),
        'mapAreaType': 'Public',
        'wallsTexture': 'PlainWhite',
      }));

      final map = b.forFloor('floor-1')!;
      expect(map.isWalkable(0, 0), isTrue, reason: 'physically standable — nothing is there');
      expect(map.isInside(0, 0), isFalse, reason: 'but it is not the office');
      expect(map.walkable, contains(0));
      expect(map.open, isNot(contains(0)));
      expect(map.open, hasLength(36), reason: 'the 6x6 area and nothing else');
      expect(map.insideCount, 36);
    });

    test('a space that names no areas is all office', () {
      // The base area is the grid, so a footprint built from it would be the whole
      // map and prove nothing. With no other areas there is nothing to be outside
      // of, and a party still has to have somewhere to go.
      final map = _base().forFloor('floor-1')!;
      expect(map.open, hasLength(200));
      expect(map.isInside(0, 0), isTrue);
      expect(map.insideCount, 200);
    });

    test('an area with no walls is a label, not an obstacle', () {
      // 74 of 93 areas are like this: desk clusters and team zones, which group
      // people without enclosing them.
      final b = _base();
      b.apply('MapArea', _add({
        'id': 'team',
        'mapId': 'map-1',
        'parentAreaId': 'base',
        'relativeX': 2,
        'relativeY': 2,
        'dimensionsInTiles': _dims(4, 4),
        'mapAreaType': 'Team',
        'name': 'Backend & DevOps',
        'wallsTexture': 'NewStyleNoWall',
      }));

      final map = b.forFloor('floor-1')!;
      expect(map.blockedCount, 0);
      expect(map.isPrivate(3, 3), isFalse, reason: 'no walls, so not private');
      expect(map.roomAt(3, 3)?.name, 'Backend & DevOps');
    });

    test('a doorway is a two-tile gap in the wall', () {
      final b = _base();
      b.apply('MapArea', _add({
        'id': 'room',
        'mapId': 'map-1',
        'parentAreaId': 'base',
        'relativeX': 2,
        'relativeY': 2,
        'dimensionsInTiles': _dims(4, 6),
        'mapAreaType': 'MeetingRoom',
        'wallsTexture': 'PlainGreen',
        'doorways': {
          'locations': [
            {
              'origin': {'x': 3, 'y': 2},
              'orientation': 'Vertical',
            },
          ],
        },
      }));

      // doorwayPositionHashes expands {origin, orientation} into two tiles — the
      // origin plus one down for Vertical, one right for Horizontal — in coordinates
      // relative to the area, so the room's own width is the stride.
      //
      // The room is 4x6 at (2,2), so its east wall is the column at x=5 and the
      // doorway is the two tiles of it at y=4 and y=5. Nothing blocks a *tile* either
      // way: a doorway is a gap in the line between two tiles.
      final map = b.forFloor('floor-1')!;
      expect(map.blockedCount, 0);
      expect(map.rooms.any((r) => r.walled), isTrue);

      expect(map.canPassThrough(5, 4, 6, 4), isTrue, reason: 'through the door');
      expect(map.canPassThrough(5, 5, 6, 5), isTrue);
      expect(map.canPassThrough(5, 3, 6, 3), isFalse, reason: 'the wall above it');
      expect(map.canPassThrough(5, 6, 6, 6), isFalse);
      // Twenty lines around a 4x6 room — six a side, four top and bottom — less the
      // two the door opens.
      expect(map.edgeCount, 18);
    });

    test('the smallest named room wins when they overlap', () {
      // Desks sit inside team zones, which sit inside the base area. "Which room am
      // I in" should answer with the specific one.
      final b = _base();
      for (final (id, name, size) in [
        ('team', 'Frontend', 8),
        ('desk', 'Ada', 2),
      ]) {
        b.apply('MapArea', _add({
          'id': id,
          'mapId': 'map-1',
          'parentAreaId': 'base',
          'relativeX': 2,
          'relativeY': 2,
          'dimensionsInTiles': _dims(size, size),
          'mapAreaType': 'Team',
          'name': name,
          'wallsTexture': 'NewStyleNoWall',
        }));
      }

      expect(b.forFloor('floor-1')!.roomAt(3, 3)?.name, 'Ada');
    });
  });

  group('walls', () {
    /// A 4x6 walled room at (2,2), so it covers x 2..5 and y 2..7.
    SpaceMapBuilder walled({String texture = 'PlainGreen'}) {
      final b = _base();
      b.apply('MapArea', _add({
        'id': 'room',
        'mapId': 'map-1',
        'parentAreaId': 'base',
        'relativeX': 2,
        'relativeY': 2,
        'dimensionsInTiles': _dims(4, 6),
        'mapAreaType': 'MeetingRoom',
        'wallsTexture': texture,
      }));
      return b;
    }

    test('a wall is a line between tiles, not a tile', () {
      // `Collisions.addArea` records `addBlockedDirection(outsideTile, wallTile)` and
      // `blockedAtPosition` never consults it, so the perimeter stays standable. This
      // is the finding the whole floor plan turned on: treating walls as blocked tiles
      // deleted 488 perfectly good tiles from the measured space.
      final map = walled().forFloor('floor-1')!;

      expect(map.blockedCount, 0);
      expect(map.isWalkable(2, 2), isTrue, reason: 'the north-west corner of the wall');
      expect(map.isWalkable(5, 7), isTrue);
      expect(map.edgeCount, 20);
    });

    test('the line stops you both ways round', () {
      // `canPassThrough` asks its set for `A.hashPair(e)` and `e.hashPair(A)`, so a
      // wall keeps you in exactly as firmly as it keeps you out. Storing one ordering
      // and forgetting the other would let anyone walk out of every meeting room.
      final map = walled().forFloor('floor-1')!;

      expect(map.canPassThrough(2, 1, 2, 2), isFalse, reason: 'in through the north');
      expect(map.canPassThrough(2, 2, 2, 1), isFalse, reason: 'and back out');
      expect(map.canStep(2, 1, 'Down'), isFalse);
      expect(map.canStep(2, 2, 'Up'), isFalse);
    });

    test('the side walls run the full height of the room', () {
      // The one place the art and the physics disagree, and the reason this is not
      // copied from `space_art.dart`: the drawing loop stops at `tilesHigh - 2`
      // because the north and south bands are two tiles tall and cover the corners.
      // `addArea` has no bands, and its `I` runs to `height - 1`. Following the art
      // would leave a walkable gap in the bottom of every room in the office.
      final map = walled().forFloor('floor-1')!;

      for (var y = 2; y <= 7; y++) {
        expect(map.canPassThrough(1, y, 2, y), isFalse, reason: 'west wall at y=$y');
        expect(map.canPassThrough(6, y, 5, y), isFalse, reason: 'east wall at y=$y');
      }
    });

    test('an area with no walls draws no lines', () {
      // `if (!A.isWalled) return`, and `isWalled` is `wallsTexture !== 'NewStyleNoWall'`.
      // Team zones are areas too, and a zone whose edges stopped people would turn the
      // office into a maze of invisible pens.
      final map = walled(texture: 'NewStyleNoWall').forFloor('floor-1')!;

      expect(map.edgeCount, 0);
      expect(map.canPassThrough(2, 1, 2, 2), isTrue);
    });

    test('a step is refused off the grid, into furniture, or through a wall', () {
      final b = walled();
      _variant(b, 'v1', [
        [0, 0],
      ]);
      b.apply('MapObject', _add({
        'id': 'o1',
        'mapId': 'map-1',
        'parentAreaId': 'base',
        'relativeX': 9,
        'relativeY': 5,
        'catalogItemVariantId': 'v1',
      }));
      final map = b.forFloor('floor-1')!;

      expect(map.canStep(0, 0, 'Left'), isFalse, reason: 'off the west edge');
      expect(map.canStep(0, 0, 'Up'), isFalse, reason: 'off the north edge');
      expect(map.canStep(8, 5, 'Right'), isFalse, reason: 'into the desk at (9,5)');
      expect(map.canStep(1, 4, 'Right'), isFalse, reason: 'through the room wall');
      expect(map.canStep(8, 5, 'Down'), isTrue, reason: 'open floor');
      expect(map.canStep(8, 5, 'Sideways'), isFalse, reason: 'not a direction');
    });

    test('walking about inside a room is not walking through its walls', () {
      // The lines are on the perimeter, so the inside of the room has none of them.
      final map = walled().forFloor('floor-1')!;

      expect(map.canStep(3, 4, 'Right'), isTrue);
      expect(map.canStep(3, 4, 'Left'), isTrue);
      expect(map.canStep(3, 4, 'Up'), isTrue);
      expect(map.canStep(3, 4, 'Down'), isTrue);
    });
  });

  group('staying current', () {
    test('a dragged object moves its collision', () {
      // Map edits arrive as field patches — the row is not resent — so a builder
      // that only understood `addmodel` would hold a stale floor plan until the
      // next reconnect.
      final b = _base();
      _variant(b, 'v1', [
        [0, 0],
      ]);
      b.apply('MapObject', _add({
        'id': 'o1',
        'mapId': 'map-1',
        'parentAreaId': 'base',
        'relativeX': 5,
        'relativeY': 3,
        'catalogItemVariantId': 'v1',
      }));
      expect(b.forFloor('floor-1')!.isWalkable(5, 3), isFalse);

      b.apply('MapObject', {
        'op': 'replace',
        'id': 'o1',
        'path': '/relativeX',
        'data': 9,
      });

      final map = b.forFloor('floor-1')!;
      expect(map.isWalkable(5, 3), isTrue, reason: 'it moved away');
      expect(map.isWalkable(9, 3), isFalse, reason: 'and arrived here');
    });

    test('a nested field patch keeps the rest of the value', () {
      final b = _base();
      b.apply('MapArea', _add({
        'id': 'room',
        'mapId': 'map-1',
        'parentAreaId': 'base',
        'relativeX': 2,
        'relativeY': 2,
        'dimensionsInTiles': _dims(4, 4),
        'mapAreaType': 'MeetingRoom',
        'wallsTexture': 'PlainWhite',
      }));
      b.apply('MapArea', {
        'op': 'replace',
        'id': 'room',
        'path': '/dimensionsInTiles/width',
        'data': 6,
      });

      final room = b.forFloor('floor-1')!.rooms.firstWhere((r) => r.id == 'room');
      expect(room.width, 6);
      expect(room.height, 4, reason: 'height was not in the patch and must survive');
    });

    test('a deleted object stops blocking', () {
      final b = _base();
      _variant(b, 'v1', [
        [0, 0],
      ]);
      b.apply('MapObject', _add({
        'id': 'o1',
        'mapId': 'map-1',
        'parentAreaId': 'base',
        'relativeX': 5,
        'relativeY': 3,
        'catalogItemVariantId': 'v1',
      }));
      expect(b.forFloor('floor-1')!.isWalkable(5, 3), isFalse);

      b.apply('MapObject', {'op': 'deletemodel', 'id': 'o1'});
      expect(b.forFloor('floor-1')!.isWalkable(5, 3), isTrue);
    });

    test('a soft-deleted row is ignored', () {
      // `deletedAt` is how the server retires a row without a `deletemodel`.
      final b = _base();
      _variant(b, 'v1', [
        [0, 0],
      ]);
      b.apply('MapObject', _add({
        'id': 'o1',
        'mapId': 'map-1',
        'parentAreaId': 'base',
        'relativeX': 5,
        'relativeY': 3,
        'catalogItemVariantId': 'v1',
        'deletedAt': '2026-08-07T12:00:00Z',
      }));

      expect(b.forFloor('floor-1')!.blockedCount, 0);
    });
  });

  group('seats', () {
    test('a chair marks the tile you sit on, placed like a collision tile', () {
      // `activeSittableAbsoluteTiles` is `sittablePositions` through the same
      // origin-and-round placement as collision. Nothing else on the wire says who
      // is sitting: `playerState` never leaves the client that owns it.
      final b = _base();
      _variant(b, 'v1', const [], family: 'Chair', sittable: [
        [0, 0],
      ]);
      b.apply('MapObject', _add({
        'id': 'chair',
        'mapId': 'map-1',
        'parentAreaId': 'base',
        'relativeX': 6,
        'relativeY': 4,
        'catalogItemVariantId': 'v1',
      }));

      final map = b.forFloor('floor-1')!;
      expect(map.isSeat(6, 4), isTrue);
      expect(map.isSeat(6, 5), isFalse);
      // A seat is not furniture: you stand on it, so it must stay walkable.
      expect(map.isWalkable(6, 4), isTrue);
      expect(map.seatCount, 1);
      expect(map.seatFacing(6, 4), isNull, reason: 'this fixture names no orientation');
    });

    test('a seat remembers which way its chair is turned', () {
      // `applySittingDirection` faces the sitter along the variant's `orientation`,
      // through a `CATALOG_ORIENTATION_TO_MOVE_DIRECTION` table that is the identity.
      // It runs on the local player only and publishes the turn as its own patch, so
      // another client can see somebody sat down still facing the way they walked in.
      // The chair is the answer that does not race.
      final b = _base();
      _variant(b, 'v1', const [], family: 'Chair', orientation: 'Left', sittable: [
        [0, 0],
      ]);
      b.apply('MapObject', _add({
        'id': 'chair',
        'mapId': 'map-1',
        'parentAreaId': 'base',
        'relativeX': 6,
        'relativeY': 4,
        'catalogItemVariantId': 'v1',
      }));

      final map = b.forFloor('floor-1')!;
      // The same four words `SpaceUser.direction` uses, which is what makes the
      // client's mapping table an identity rather than a translation.
      expect(map.seatFacing(6, 4), 'Left');
      expect(map.seatFacing(6, 5), isNull);
    });

    test('a chair standing on something else seats nobody', () {
      // The `isSpecialEffectActive` gate collision uses, applied to the same tiles:
      // a chair on a table is scenery.
      final b = _base();
      _variant(b, 'v1', const [], family: 'Chair', sittable: [
        [0, 0],
      ]);
      b.apply('MapObject', _add({
        'id': 'table',
        'mapId': 'map-1',
        'parentAreaId': 'base',
        'relativeX': 6,
        'relativeY': 4,
        'catalogItemVariantId': 'v1',
      }));
      b.apply('MapObject', _add({
        'id': 'chair',
        'mapId': 'map-1',
        'parentObjectId': 'table',
        'relativeX': 0,
        'relativeY': 0,
        'catalogItemVariantId': 'v1',
      }));

      expect(b.forFloor('floor-1')!.seatCount, 1);
    });
  });

  group('routing', () {
    /// A room, walled unless told otherwise, with doorways given relative to it.
    void area(
      SpaceMapBuilder b, {
      required String id,
      required String type,
      required int x,
      required int y,
      int width = 4,
      int height = 4,
      String? name,
      String walls = 'PlainWhite',
      List<(int, int, String)> doorways = const [],
    }) {
      b.apply('MapArea', _add({
        'id': id,
        'mapId': 'map-1',
        'parentAreaId': 'base',
        'relativeX': x,
        'relativeY': y,
        'dimensionsInTiles': _dims(width, height),
        'mapAreaType': type,
        'name': ?name,
        'wallsTexture': walls,
        'doorways': {
          'locations': [
            for (final (dx, dy, orientation) in doorways)
              {
                'origin': {'x': dx, 'y': dy},
                'orientation': orientation,
              },
          ],
        },
      }));
    }

    /// How many times a route changes direction. One turn is an L; seven is a
    /// staircase, which is what the −0.001 exists to prevent.
    int turns(List<({int x, int y})> route) {
      var count = 0;
      for (var i = 2; i < route.length; i++) {
        final was = (route[i - 1].x - route[i - 2].x, route[i - 1].y - route[i - 2].y);
        final now = (route[i].x - route[i - 1].x, route[i].y - route[i - 1].y);
        if (was != now) count++;
      }
      return count;
    }

    test('an open floor is crossed in a straight line', () {
      final map = _base().forFloor('floor-1')!;
      final route = map.routeTo(fromX: 2, fromY: 5, toX: 8, toY: 5)!;

      expect(route.first, (x: 2, y: 5), reason: 'the start is included');
      expect(route.last, (x: 8, y: 5));
      expect(route.length, 7, reason: 'six steps, seven tiles');
      expect(route.every((t) => t.y == 5), isTrue);
    });

    test('a route turns once rather than climbing a staircase', () {
      // The −0.001 bonus for continuing in the same direction. Every step costs 1,
      // so on an open floor an L and a staircase are exactly the same length and
      // nothing but this tiebreak chooses between them.
      final map = _base().forFloor('floor-1')!;
      final route = map.routeTo(fromX: 2, fromY: 2, toX: 7, toY: 7)!;

      expect(route.length, 11, reason: 'still a shortest route');
      expect(turns(route), 1, reason: 'an L, not a staircase');
    });

    test('a wall is not crossed even though both of its sides are walkable', () {
      // The bug this geometry invites, and the reason `canPassThrough` exists: a
      // wall is a line between two tiles, and both of those tiles are perfectly good
      // floor. A route that asked only `isWalkable` would step straight through it.
      final b = _base();
      area(b, id: 'room', type: 'MeetingRoom', x: 2, y: 2, name: 'Boardroom');
      final map = b.forFloor('floor-1')!;

      expect(map.isWalkable(3, 1), isTrue);
      expect(map.isWalkable(3, 2), isTrue, reason: 'the wall tile is standable');
      expect(map.canPassThrough(3, 1, 3, 2), isFalse, reason: 'but the line is not');
      expect(map.routeTo(fromX: 3, fromY: 1, toX: 3, toY: 3), isNull);
    });

    test('a room with a doorway is entered through it', () {
      final b = _base();
      area(b, id: 'room', type: 'MeetingRoom', x: 2, y: 2, name: 'Boardroom',
          doorways: [(1, 0, 'Horizontal')]);
      final map = b.forFloor('floor-1')!;

      final route = map.routeTo(fromX: 8, fromY: 1, toX: 3, toY: 4)!;
      expect(route.last, (x: 3, y: 4));
      // `doorwayPositionHashes` is two tiles wide: the origin and the one beside it.
      expect(
        route,
        anyOf(contains((x: 3, y: 2)), contains((x: 4, y: 2))),
        reason: 'it came in through the door',
      );
    });

    test('a room with no doorway cannot be walked into at all', () {
      // Which is the honest answer rather than a failure: `teleport` ignores walls
      // and walking does not, so there is genuinely no way to walk there.
      final b = _base();
      area(b, id: 'room', type: 'MeetingRoom', x: 2, y: 2, name: 'Sealed');
      final map = b.forFloor('floor-1')!;

      expect(map.routeTo(fromX: 8, fromY: 1, toX: 3, toY: 3), isNull);
    });

    test('a route will not cut through somebody else\'s desk', () {
      // `isPublicWalkway`: Common, MeetingRoom and Desk are false, and every area
      // that answers false is impassable unless the route starts or ends in it.
      // Desks are usually unwalled, so nothing else would stop this.
      final b = _base();
      area(b, id: 'desk', type: 'Desk', x: 10, y: 0, width: 2, height: 10,
          walls: 'NewStyleNoWall');
      final map = b.forFloor('floor-1')!;

      expect(map.isWalkable(10, 5), isTrue, reason: 'physically fine to stand on');
      expect(map.routeTo(fromX: 5, fromY: 5, toX: 15, toY: 5), isNull);
      // Ending there is exactly what "go to that desk" is, so the goal's own area is
      // always exempt.
      expect(map.routeTo(fromX: 5, fromY: 5, toX: 10, toY: 5), isNotNull);
    });

    test('a team zone is a walkway and may be crossed', () {
      // The same fixture, one word changed. Public, Lobby and Team answer true.
      final b = _base();
      area(b, id: 'team', type: 'Team', x: 10, y: 0, width: 2, height: 10,
          name: 'Frontend', walls: 'NewStyleNoWall');
      final map = b.forFloor('floor-1')!;

      expect(map.routeTo(fromX: 5, fromY: 5, toX: 15, toY: 5), isNotNull);
    });

    test('a tile somebody is standing on is routed around', () {
      final map = _base().forFloor('floor-1')!;
      final route = map.routeTo(
        fromX: 2,
        fromY: 5,
        toX: 8,
        toY: 5,
        avoid: [(x: 5, y: 5)],
      )!;

      expect(route.last, (x: 8, y: 5));
      expect(route, isNot(contains((x: 5, y: 5))));
    });

    test('the goal itself is never avoided', () {
      // Otherwise walking up to somebody would be impossible, and the client's own
      // arrival rules — `havePriorityToStayOnTile`, `getNearestFreeTile` — are about
      // what happens when you get there, not about refusing to set off.
      final map = _base().forFloor('floor-1')!;
      expect(
        map.routeTo(fromX: 2, fromY: 5, toX: 8, toY: 5, avoid: [(x: 8, y: 5)]),
        isNotNull,
      );
    });

    test('a search that runs out of budget gives up rather than grinding', () {
      final map = _base().forFloor('floor-1')!;
      expect(map.routeTo(fromX: 0, fromY: 0, toX: 19, toY: 9, budget: 4), isNull);
      expect(map.routeTo(fromX: 0, fromY: 0, toX: 19, toY: 9), isNotNull);
    });

    test('standing where you already are is a route of one tile', () {
      final map = _base().forFloor('floor-1')!;
      expect(map.routeTo(fromX: 4, fromY: 4, toX: 4, toY: 4), [(x: 4, y: 4)]);
    });

    test('a room offers its seats first, then its nearest floor', () {
      // `getAbsoluteTilesClosestToPrioritizedBySeats`. A meeting room you walk into
      // should sit you down, and the tile you tapped only breaks ties.
      final b = _base();
      area(b, id: 'room', type: 'MeetingRoom', x: 2, y: 2, name: 'Boardroom',
          doorways: [(1, 0, 'Horizontal')]);
      _variant(b, 'v1', const [], family: 'Chair', sittable: [
        [0, 0],
      ]);
      b.apply('MapObject', _add({
        'id': 'chair',
        'mapId': 'map-1',
        'parentAreaId': 'base',
        'relativeX': 5,
        'relativeY': 5,
        'catalogItemVariantId': 'v1',
      }));
      final map = b.forFloor('floor-1')!;
      final room = map.rooms.firstWhere((r) => r.id == 'room');

      // The chair is in the far corner from the tapped tile and still comes first.
      final tiles = map.tilesClosestTo(room, (x: 2, y: 2));
      expect(tiles.first, (x: 5, y: 5), reason: 'the seat outranks proximity');
      expect(tiles[1], (x: 2, y: 2), reason: 'then the nearest standing tile');
      expect(tiles.length, 16, reason: 'the whole 4x4 room is walkable');
    });

    test('areaAt sees the desks that roomAt is built to skip', () {
      // Two questions that look alike: roomAt labels a position for a human and so
      // wants a name, areaAt decides what a route may cross and so must count the 62
      // unnamed desks.
      final b = _base();
      area(b, id: 'desk', type: 'Desk', x: 2, y: 2, width: 2, height: 2,
          walls: 'NewStyleNoWall');
      final map = b.forFloor('floor-1')!;

      expect(map.roomAt(2, 2), isNull, reason: 'a desk has no name');
      expect(map.areaAt(2, 2)?.id, 'desk');
      expect(map.areaAt(9, 9)?.id, 'base', reason: 'the base area still contains it');
    });
  });

  test('a single floor answers even when the floor is not named', () {
    // The roster can carry a null floorId, and a one-floor space has only one
    // possible answer. Guessing is only wrong when there is a choice.
    final b = _base();
    expect(b.forFloor(null), isNotNull);
    expect(b.forFloor('some-other-floor'), isNull);
  });
}
