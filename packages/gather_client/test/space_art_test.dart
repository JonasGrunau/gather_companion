/// [SpaceMapBuilder.artFor] turns the same map models into something to draw.
///
/// Same provenance rule as `space_map_test.dart`: every expectation here is a
/// transcription of the client's own resolver or renderer, and the test names which
/// one. The filenames are not decorative — a wrong stem is a 404 per tile, and the
/// screen has no way to tell that from a room with no floor.
library;

import 'package:gather_client/gather_client.dart';
import 'package:test/test.dart';

Map<String, Object?> _add(Map<String, Object?> data) => {'op': 'addmodel', 'data': data};

Map<String, Object?> _dims(int width, int height) =>
    {r'$type': 'Dimensions', 'width': width, 'height': height};

/// A builder holding one floor: a 20×10 grass base area and nothing else.
SpaceMapBuilder _base() {
  final b = SpaceMapBuilder();
  b.apply('MapArea', _add({
    'id': 'base',
    'mapId': 'map-1',
    'relativeX': 0,
    'relativeY': 0,
    'dimensionsInTiles': _dims(20, 10),
    'mapAreaType': 'Public',
    'wallsTexture': 'NewStyleNoWall',
    'floorTexture': 'NewStyleGrass',
    'floorColor': 'Green',
  }));
  b.apply('FloorMap', _add({'id': 'map-1', 'floorId': 'floor-1', 'baseAreaId': 'base'}));
  return b;
}

/// A walled room, by default 4×5 at tile (2, 3).
void _room(
  SpaceMapBuilder b, {
  String id = 'room',
  int x = 2,
  int y = 3,
  int width = 4,
  int height = 5,
  String walls = 'PlainWhite',
  String floor = 'WoodSlats',
  String colour = 'Wood',
  List<Map<String, Object?>> doorways = const [],
}) {
  b.apply('MapArea', _add({
    'id': id,
    'mapId': 'map-1',
    'parentAreaId': 'base',
    'relativeX': x,
    'relativeY': y,
    'dimensionsInTiles': _dims(width, height),
    'mapAreaType': 'MeetingRoom',
    'wallsTexture': walls,
    'floorTexture': floor,
    'floorColor': colour,
    'doorways': {'locations': doorways},
  }));
}

/// One piece of furniture, and the variant it draws with.
void _object(
  SpaceMapBuilder b, {
  required String id,
  required String variantId,
  required num x,
  required num y,
  String? parentObjectId,
  String imageUrl = '/catalog/assets/stg/sprite.png',
  String? foregroundUrl,
  num fold = 0,
  num originX = 0,
  num originY = 0,
  int width = 32,
  int height = 32,
}) {
  b.apply('CatalogItemVariant', _add({
    'id': variantId,
    'catalogItemId': 'item-$variantId',
    'originX': originX,
    'originY': originY,
    'dimensionsInPixels': _dims(width, height),
    'mainRenderable': {'imageUrl': imageUrl, 'fold': fold},
    if (foregroundUrl != null)
      'foregroundRenderable': {'imageUrl': foregroundUrl, 'fold': fold},
    'collision': {'points': const []},
    'sittable': {'points': const []},
  }));
  b.apply('MapObject', _add({
    'id': id,
    'mapId': 'map-1',
    if (parentObjectId == null) 'parentAreaId': 'base' else 'parentObjectId': parentObjectId,
    'relativeX': x,
    'relativeY': y,
    'catalogItemVariantId': variantId,
  }));
}

/// One wall piece, from whichever list it ended up in.
typedef _Wall = ({String url, double left, double top, double height, double? depth});

/// Every wall the floor draws.
///
/// Two lists, because the client uses two depths: the sides carry their area's floor
/// depth and stay in the ground band, while the north and south bands are given
/// depths of their own and sort against the furniture. [depth] is null for the sides,
/// which is the difference made visible.
List<_Wall> _walls(SpaceArt art) => [
      for (final wall in art.ground.whereType<ArtWall>())
        (url: wall.url, left: wall.left, top: wall.top, height: wall.height, depth: null),
      for (final band in art.props.where((p) => p.url.contains('/walls/')))
        (url: band.url, left: band.left, top: band.top, height: band.height, depth: band.depth),
    ];

List<ArtFloor> _floors(SpaceArt art) => art.ground.whereType<ArtFloor>().toList();

List<ArtSprite> _sprites(SpaceArt art) =>
    art.props.where((p) => !p.url.contains('/walls/')).toList();

void main() {
  group('filenames', () {
    test('a floor is its texture and its colour joined, per d(texture, colour)', () {
      expect(
        floorImageUrl('WoodSlats', 'Wood', dark: true),
        'https://app.v2.gather.town/images/studio/new-assets/walls-and-floors/floors/'
        'Wood_Slats_Wood_Dark.png',
      );
      expect(
        floorImageUrl('WoodSlats', 'Wood', dark: false),
        endsWith('/floors/Wood_Slats_Wood.png'),
      );
    });

    test('NewStyleGrass exists only in green, and falls back when asked for more', () {
      // `r` in the bundle restricts exactly this one texture. Asking for a blue lawn
      // is not an error, it is the plain per-theme table.
      expect(floorImageUrl('NewStyleGrass', 'Green', dark: false),
          endsWith('/floors/NewStyle_Grass_Green.png'));
      expect(floorImageUrl('NewStyleGrass', 'Blue', dark: false),
          endsWith('/floors/floor_main_grass.png'));
    });

    test('a texture with no colourable stem uses the flat table, per theme', () {
      expect(floorImageUrl('NewStyleSquares', 'Wood', dark: false),
          endsWith('/floors/floor_main_squares.png'));
      // Dark is a different set of files rather than a suffix — the wood floors are
      // a later re-cut, which is why both tables are carried in full.
      expect(floorImageUrl('NewStylePlanks', 'Wood', dark: true),
          endsWith('/floors/Wood_Slats_Dark.png'));
    });

    test('an unknown texture draws nothing rather than 404ing every tile', () {
      expect(floorImageUrl('SomethingShipped2027', 'Wood', dark: true), isNull);
      expect(floorImageUrl(null, 'Wood', dark: true), isNull);
    });

    test('a wall piece is the style folder plus an escaped filename', () {
      expect(
        wallImageUrl('PlainWhite', WallPiece.northEast, dark: true),
        'https://app.v2.gather.town/images/studio/new-assets/walls-and-floors/walls/'
        'Plain_White_Dark/thin%20wall%20ne.png',
      );
      expect(wallImageUrl('PlainWhite', WallPiece.west, dark: false),
          endsWith('/walls/Plain_White/thin%20wall%20w.png'));
    });

    test('NewStyleNoWall is the absence of a style, not a style', () {
      expect(wallImageUrl('NewStyleNoWall', WallPiece.north, dark: true), isNull);
      expect(wallImageUrl(null, WallPiece.north, dark: true), isNull);
    });

    test('furniture is a path on the catalog host unless it already has a scheme', () {
      expect(catalogImageUrl('/catalog/assets/stg/a.png'),
          'https://static.gather.town/catalog/assets/stg/a.png');
      expect(catalogImageUrl('/catalog/assets/stg/a.png', authoredAt: '2026-08-04T08:17:37'),
          endsWith('a.png?t=2026-08-04T08:17:37'));
      expect(catalogImageUrl('https://cdn.example/a.png'), 'https://cdn.example/a.png');
      expect(catalogImageUrl(null), isNull);
      expect(catalogImageUrl(''), isNull);
    });
  });

  group('floors', () {
    test('every area contributes one tiled rectangle, the base included', () {
      final b = _base();
      _room(b);
      final art = b.artFor('floor-1')!;

      expect(art.width, 20 * 32);
      expect(art.height, 10 * 32);
      expect(_floors(art), hasLength(2));

      final room = _floors(art).firstWhere((f) => f.url.contains('Wood_Slats'));
      expect(room.left, 2 * 32);
      expect(room.top, 3 * 32);
      expect(room.width, 4 * 32);
      expect(room.height, 5 * 32);
    });

    test('the base area is painted under everything, however far down it ends', () {
      // The rule that looked like a bug: sorted by position the base area, being the
      // whole grid, has the lowest bottom edge on the map and paints over every room
      // inside it. `getBaseDepthForSimplifiedAreaFloor` is a layer lookup instead —
      // base, then Public, then rooms — and position only breaks ties within a layer.
      final b = _base();
      _room(b, id: 'low', y: 6, height: 3);
      _room(b, id: 'high', y: 1, height: 3);

      final floors = _floors(b.artFor('floor-1')!);
      expect(floors.first.url, contains('NewStyle_Grass'), reason: 'the base area is first');
      expect(floors.map((f) => f.top).toList(), [0, 1 * 32, 6 * 32]);
    });

    test('a Public zone sits between the base area and the rooms', () {
      final b = _base();
      _room(b, id: 'room', x: 1, y: 1, width: 3, height: 3);
      b.apply('MapArea', _add({
        'id': 'floor-zone',
        'mapId': 'map-1',
        'parentAreaId': 'base',
        'relativeX': 0,
        'relativeY': 0,
        'dimensionsInTiles': _dims(12, 9),
        'mapAreaType': 'Public',
        'wallsTexture': 'NewStyleNoWall',
        'floorTexture': 'CarpetWave',
        'floorColor': 'Blue',
      }));

      final floors = _floors(b.artFor('floor-1')!);
      expect(
        floors.map((f) => f.url.split('/').last).toList(),
        ['NewStyle_Grass_Green_Dark.png', 'Carpet_Wavy_Blue_Dark.png', 'Wood_Slats_Wood_Dark.png'],
      );
    });

    test('a nested area of the same depth still lands on top of its parent', () {
      final b = _base();
      _room(b, id: 'team', x: 0, y: 0, width: 8, height: 8);
      b.apply('MapArea', _add({
        'id': 'desk',
        'mapId': 'map-1',
        'parentAreaId': 'team',
        'relativeX': 0,
        'relativeY': 4,
        'dimensionsInTiles': _dims(4, 4),
        'mapAreaType': 'Desk',
        'wallsTexture': 'NewStyleNoWall',
        'floorTexture': 'CarpetWave',
        'floorColor': 'Blue',
      }));
      final floors = _floors(b.artFor('floor-1')!);

      final team = floors.firstWhere((f) => f.url.contains('Wood_Slats'));
      final desk = floors.firstWhere((f) => f.url.contains('Carpet_Wavy'));
      // Both end on row 8, and both are in the same layer; only nesting separates
      // them, which is `updateFloorsDepth`'s first tiebreak.
      expect(desk.top + desk.height, team.top + team.height);
      expect(floors.indexOf(desk), greaterThan(floors.indexOf(team)));
    });
  });

  group('walls', () {
    test('a room is two-tile bands north and south and single tiles down the sides', () {
      final b = _base();
      _room(b);
      final walls = _walls(b.artFor('floor-1')!);

      // 4 north + 4 south + 3 rows × 2 sides.
      expect(walls, hasLength(14));

      final north = walls.where((w) => w.top == 3 * 32 - 64).toList();
      expect(north, hasLength(4));
      expect(north.every((w) => w.height == 64), isTrue);
      // The north band sits *above* the room's first row, which is why a room's
      // walls overlap whatever is behind it rather than eating its own floor.
      expect(north.map((w) => w.left).toList()..sort(), [64, 96, 128, 160]);
      // Matched on the filename, not on the URL: the path itself contains
      // `new-assets`, so a substring test for a corner piece matches everything.
      expect(north.where((w) => w.url.endsWith('%20nw.png')), hasLength(1));
      expect(north.where((w) => w.url.endsWith('%20ne.png')), hasLength(1));
      expect(north.where((w) => w.url.endsWith('%20n.png')), hasLength(2));

      final south = walls.where((w) => w.top == (3 + 5) * 32 - 64).toList();
      expect(south, hasLength(4));

      final sides = walls.where((w) => w.height == 32).toList();
      expect(sides, hasLength(6));
      expect(sides.map((w) => w.top).toSet(), {3 * 32, 4 * 32, 5 * 32});
    });

    test('a doorway is a gap, both of its tiles', () {
      final b = _base();
      _room(b, doorways: [
        {
          'origin': {'x': 1, 'y': 0},
          'orientation': 'Horizontal',
        },
      ]);
      final walls = _walls(b.artFor('floor-1')!);

      final north = walls.where((w) => w.top == 3 * 32 - 64).toList();
      expect(north, hasLength(2));
      expect(north.map((w) => w.left).toSet(), {64, 160});
    });

    test('a vertical doorway opens the side it is on', () {
      final b = _base();
      _room(b, doorways: [
        {
          'origin': {'x': 3, 'y': 1},
          'orientation': 'Vertical',
        },
      ]);
      final walls = _walls(b.artFor('floor-1')!);

      final east = walls.where((w) => w.height == 32 && w.left == (2 + 3) * 32).toList();
      // Rows 0..2 minus rows 1 and 2.
      expect(east, hasLength(1));
      expect(east.single.top, 3 * 32);
    });

    test('the base area draws no walls, and neither does an unwalled zone', () {
      final b = _base();
      _room(b, walls: 'NewStyleNoWall');
      expect(_walls(b.artFor('floor-1')!), isEmpty);
    });

    test('the sides are ground; the horizontal bands sort with the furniture', () {
      // An area is one container in the client and its *side* walls carry its floor's
      // depth, which puts them below every object: a plant standing against one covers
      // it, and occlusion the other way is what `foregroundRenderable` is for.
      //
      // The horizontal bands are the exception, and `ensureImmersiveWalls` is explicit
      // about it — `northEdge` is handed `QS(container.y + .1)` and `southEdge`
      // `QS(container.y + height * TILE_SIZE)`, depths of their own. Drawn as ground
      // like the sides, a room's south band ends up behind the desks in the room it is
      // supposed to stand in front of, which is exactly what it looked like.
      final b = _base();
      _room(b);
      _object(b, id: 'chair', variantId: 'v1', x: 3, y: 5);
      final art = b.artFor('floor-1')!;

      final roomFloor = art.ground.indexWhere((g) => g is ArtFloor && g.top == 3 * 32);
      final firstWall = art.ground.indexWhere((g) => g is ArtWall);
      expect(firstWall, greaterThan(roomFloor));
      expect(
        art.ground.whereType<ArtWall>().every((w) => w.height == 32),
        isTrue,
        reason: 'only the single-tile sides stay in the ground band',
      );

      final chair = _sprites(art).single;
      expect(chair.url, contains('sprite.png'));
      final bands = _walls(art).where((w) => w.depth != null);
      // The room is at (2, 3) and five tiles tall, so its bottom line is y = 256 and
      // the chair on its third row folds at 160.
      expect(
        bands.where((w) => w.top == (3 + 5) * 32 - 64).every((w) => w.depth! > chair.depth),
        isTrue,
        reason: 'the south band stands in front of what is in the room',
      );
      expect(
        bands.where((w) => w.top == 3 * 32 - 64).every((w) => w.depth! < chair.depth),
        isTrue,
        reason: 'and the north band behind it',
      );
    });
  });

  group('furniture', () {
    test('a sprite hangs from its own anchor, not from its tile', () {
      // `topLeftAbsolutePosition` backs the pixel origin out before anything is
      // drawn; the same subtraction the collision grid makes.
      final b = _base();
      _object(b, id: 'o1', variantId: 'v1', x: 4, y: 5, originX: 8, originY: 16, width: 48, height: 64);
      final sprite = _sprites(b.artFor('floor-1')!).single;

      expect(sprite.left, 4 * 32 - 8);
      expect(sprite.top, 5 * 32 - 16);
      expect(sprite.width, 48);
      expect(sprite.height, 64);
      expect(sprite.url, 'https://static.gather.town/catalog/assets/stg/sprite.png');
    });

    test('depth is the fold line, so two things on one tile still stack', () {
      final b = _base();
      _object(b, id: 'rug', variantId: 'v-rug', x: 4, y: 5, fold: 0);
      _object(b, id: 'shelf', variantId: 'v-shelf', x: 4, y: 5, fold: 24);
      final sprites = _sprites(b.artFor('floor-1')!);

      final rug = sprites.firstWhere((s) => s.url.contains('sprite'));
      expect(rug.depth, 5 * 32.0);
      expect(sprites.last.depth, 5 * 32 + 24);
    });

    test('a foreground renderable is a second sprite, drawn over people', () {
      final b = _base();
      _object(
        b,
        id: 'booth',
        variantId: 'v1',
        x: 4,
        y: 5,
        foregroundUrl: '/catalog/assets/stg/front.png',
      );
      final sprites = _sprites(b.artFor('floor-1')!);

      expect(sprites, hasLength(2));
      expect(sprites.where((s) => s.foreground), hasLength(1));
      expect(sprites.firstWhere((s) => s.foreground).url, endsWith('front.png'));
      // Same box: the foreground half is cut from the same sprite sheet cell.
      expect(sprites.first.left, sprites.last.left);
    });

    test('something standing on a desk travels with the desk', () {
      // `updateDepth` folds a child's depth in behind the parent's decimal point, so
      // a lamp cannot sink through the desk it stands on however tall it is.
      final b = _base();
      _object(b, id: 'desk', variantId: 'v-desk', x: 4, y: 5, fold: 30);
      _object(b, id: 'lamp', variantId: 'v-lamp', x: 0.5, y: -1, parentObjectId: 'desk', fold: 4);
      final sprites = _sprites(b.artFor('floor-1')!);

      final desk = sprites.firstWhere((s) => s.depth < 200);
      final lamp = sprites.firstWhere((s) => s != desk);
      expect(desk.depth, 5 * 32 + 30);
      expect(lamp.depth, greaterThan(desk.depth));
      expect(lamp.depth - desk.depth, lessThan(1));
      // It is still drawn where it stands, a tile above the desk.
      expect(lamp.top, (5 - 1) * 32);
    });

    test('deleted furniture is gone from the drawing as well as from the grid', () {
      final b = _base();
      _object(b, id: 'o1', variantId: 'v1', x: 4, y: 5);
      expect(_sprites(b.artFor('floor-1')!), hasLength(1));

      b.apply('MapObject', {'op': 'deletemodel', 'id': 'o1'});
      expect(_sprites(b.artFor('floor-1')!), isEmpty);
    });
  });

  group('the prefetch list', () {
    test('urls is every distinct image and nothing else', () {
      final b = _base();
      _room(b);
      _object(b, id: 'o1', variantId: 'v1', x: 4, y: 5);
      _object(b, id: 'o2', variantId: 'v1', x: 6, y: 5);
      final art = b.artFor('floor-1')!;

      // Two objects, one variant: one sprite fetch. Plus two floors and five wall
      // pieces (nw, n, ne, w, e — s/sw/se make eight).
      expect(art.urls, contains('https://static.gather.town/catalog/assets/stg/sprite.png'));
      expect(art.urls.where((u) => u.contains('/floors/')), hasLength(2));
      expect(art.urls.where((u) => u.contains('/walls/')), hasLength(8));
      expect(art.urls, hasLength(11));
    });

    test('no map is no art, which is different from art with nothing in it', () {
      expect(SpaceMapBuilder().artFor('floor-1'), isNull);
      expect(_base().artFor('floor-1')!.isEmpty, isFalse);
    });

    test('a moved object is redrawn rather than remembered', () {
      final b = _base();
      _object(b, id: 'o1', variantId: 'v1', x: 4, y: 5);
      expect(_sprites(b.artFor('floor-1')!).single.left, 4 * 32);

      b.apply('MapObject', {'op': 'replace', 'id': 'o1', 'path': '/relativeX', 'data': 9});
      expect(_sprites(b.artFor('floor-1')!).single.left, 9 * 32);
    });
  });
}
