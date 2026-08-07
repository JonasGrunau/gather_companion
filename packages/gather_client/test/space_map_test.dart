/// [SpaceMapBuilder] turns the map models into tiles you can stand on.
///
/// The rules being pinned here were not reasoned out — they were recovered by
/// sweeping every plausible decoding against a live space and keeping the one that
/// put nobody inside a wall (`tool/probe-connect.mjs walkable`). That makes them
/// exactly the kind of thing that looks arbitrary later and gets "tidied up", so
/// each one is stated as a named guarantee with the evidence in the reason.
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
void _variant(SpaceMapBuilder b, String id, List<List<num>> points) {
  b.apply('CatalogItemVariant', _add({
    'id': id,
    'collision': {
      'points': [
        for (final p in points) {'x': p[0], 'y': p[1]},
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

    test('the origin floors and the offset rounds', () {
      // The rule that survived the sweep. An object at 5.65 with an offset of
      // -0.0625 blocks tile 5: floor(5.65) + round(-0.0625) = 5 + 0. Rounding the
      // sum instead gives 6, which is how people ended up inside walls.
      final b = _base();
      _variant(b, 'desk', [
        [-0.0625, 0],
        [0.9375, 0],
        [1.9375, 0],
      ]);
      b.apply('MapObject', _add({
        'id': 'o1',
        'mapId': 'map-1',
        'parentAreaId': 'base',
        'relativeX': 5.6484375,
        'relativeY': 3.4296875,
        'catalogItemVariantId': 'desk',
      }));

      final map = b.forFloor('floor-1')!;
      expect(map.isWalkable(5, 3), isFalse);
      expect(map.isWalkable(6, 3), isFalse);
      expect(map.isWalkable(7, 3), isFalse);
      expect(map.isWalkable(8, 3), isTrue, reason: 'a three-tile desk, not four');
      expect(map.isWalkable(5, 4), isTrue, reason: 'y floored to 3, not rounded to 4');
    });

    test('an object parented to another object is placed against it', () {
      // 1140 of 1140 objects in the measured space carry a fractional offset, and
      // they nest — a monitor sits on a desk, not on the floor.
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

      expect(b.forFloor('floor-1')!.isWalkable(6, 5), isFalse);
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
    test('a walled area blocks its perimeter but not its inside', () {
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

      final map = b.forFloor('floor-1')!;
      expect(map.isWalkable(2, 2), isFalse, reason: 'corner');
      expect(map.isWalkable(3, 2), isFalse, reason: 'top wall');
      expect(map.isWalkable(2, 3), isFalse, reason: 'left wall');
      expect(map.isWalkable(3, 3), isTrue, reason: 'inside the room');
      expect(map.isWalkable(4, 4), isTrue);
      expect(map.isWalkable(5, 5), isFalse, reason: 'far corner');
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

      final map = b.forFloor('floor-1')!;
      expect(map.isWalkable(5, 4), isTrue, reason: 'the doorway itself');
      expect(map.isWalkable(5, 5), isTrue, reason: 'doors are two tiles tall');
      expect(map.isWalkable(5, 6), isFalse, reason: 'wall resumes below the door');
      expect(map.isWalkable(5, 3), isFalse, reason: 'and above it');
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
