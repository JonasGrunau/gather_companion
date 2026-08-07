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
}) {
  if (family != null) {
    b.apply('CatalogItem', _add({'id': 'item-$id', 'family': family}));
  }
  b.apply('CatalogItemVariant', _add({
    'id': id,
    'catalogItemId': 'item-$id',
    'originX': originX,
    'originY': originY,
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
      // origin plus one down for Vertical, one right for Horizontal. Nothing here
      // blocks a tile either way, so the assertion is that the room still parses
      // and stays private.
      final map = b.forFloor('floor-1')!;
      expect(map.blockedCount, 0);
      expect(map.rooms.any((r) => r.walled), isTrue);
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

  test('a single floor answers even when the floor is not named', () {
    // The roster can carry a null floorId, and a one-floor space has only one
    // possible answer. Guessing is only wrong when there is a choice.
    final b = _base();
    expect(b.forFloor(null), isNotNull);
    expect(b.forFloor('some-other-floor'), isNull);
  });
}
