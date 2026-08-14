/// The map screen, drawn with Gather's own artwork.
///
/// These paint for real and then read the pixels back, because everything this
/// feature can get wrong is invisible to a widget finder: a floor that paints over
/// the room inside it, a sprite hung from the wrong corner, a body drawn on top of
/// the desk it is sitting behind. Each image is a flat colour, so "what is at this
/// pixel" answers "which image landed here".
///
/// No network: [ArtCache] takes the fetch as a seam, and these hand it colours.
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/src/art_cache.dart';
import 'package:gather_companion/src/map_motion.dart';
import 'package:gather_companion/src/map_person.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/map_screen.dart';

Map<String, Object?> _add(Map<String, Object?> data) => {'op': 'addmodel', 'data': data};

Map<String, Object?> _dims(int width, int height) =>
    {r'$type': 'Dimensions', 'width': width, 'height': height};

/// A 10×8 grass base area with a wood-floored, white-walled 4×4 room at (2, 2) and
/// one sprite in it at tile (3, 3).
///
/// The room's walls take its outer ring: the north band covers map rows 0–1, the
/// south band rows 4–5, and the sides columns 2 and 5. Tiles (3, 2), (4, 2), (3, 3)
/// and (4, 3) are the only clear floor, which is where every probe below has to go.
SpaceArt _art({int spriteSize = 32, num fold = 0}) {
  final b = SpaceMapBuilder();
  b.apply('MapArea', _add({
    'id': 'base',
    'mapId': 'map-1',
    'relativeX': 0,
    'relativeY': 0,
    'dimensionsInTiles': _dims(10, 8),
    'mapAreaType': 'Public',
    'wallsTexture': 'NewStyleNoWall',
    'floorTexture': 'NewStyleGrass',
    'floorColor': 'Green',
  }));
  b.apply('FloorMap', _add({'id': 'map-1', 'floorId': 'floor-1', 'baseAreaId': 'base'}));
  b.apply('MapArea', _add({
    'id': 'room',
    'mapId': 'map-1',
    'parentAreaId': 'base',
    'relativeX': 2,
    'relativeY': 2,
    'dimensionsInTiles': _dims(4, 4),
    'mapAreaType': 'MeetingRoom',
    'wallsTexture': 'PlainWhite',
    'floorTexture': 'WoodSlats',
    'floorColor': 'Wood',
    'doorways': const {'locations': []},
  }));
  b.apply('CatalogItemVariant', _add({
    'id': 'v1',
    'catalogItemId': 'i1',
    'originX': 0,
    'originY': 0,
    'dimensionsInPixels': _dims(spriteSize, spriteSize),
    'mainRenderable': {'imageUrl': '/catalog/assets/stg/desk.png', 'fold': fold},
    'collision': {'points': const []},
    'sittable': {'points': const []},
  }));
  b.apply('MapObject', _add({
    'id': 'o1',
    'mapId': 'map-1',
    'parentAreaId': 'base',
    'relativeX': 3,
    'relativeY': 3,
    'catalogItemVariantId': 'v1',
  }));
  return b.artFor('floor-1')!;
}

SpaceMapBuilder _bareMap() {
  final b = SpaceMapBuilder();
  b.apply('MapArea', _add({
    'id': 'base',
    'mapId': 'map-1',
    'relativeX': 0,
    'relativeY': 0,
    'dimensionsInTiles': _dims(10, 8),
    'mapAreaType': 'Public',
    'wallsTexture': 'NewStyleNoWall',
  }));
  b.apply('FloorMap', _add({'id': 'map-1', 'floorId': 'floor-1', 'baseAreaId': 'base'}));
  return b;
}

SpaceMap _map() => _bareMap().forFloor('floor-1')!;

/// The same map with a chair you can sit on at tile (4, 2).
SpaceMap _seatedMap({String? orientation}) {
  final b = _bareMap();
  b.apply('CatalogItem', _add({'id': 'i-chair', 'family': 'Chair'}));
  b.apply('CatalogItemVariant', _add({
    'id': 'v-chair',
    'catalogItemId': 'i-chair',
    'originX': 0,
    'originY': 0,
    'dimensionsInPixels': _dims(32, 32),
    'orientation': ?orientation,
    'mainRenderable': {'imageUrl': '/catalog/assets/stg/chair.png', 'fold': 0},
    'collision': {'points': const []},
    'sittable': {
      'points': const [
        {'x': 0, 'y': 0},
      ],
    },
  }));
  b.apply('MapObject', _add({
    'id': 'chair',
    'mapId': 'map-1',
    'parentAreaId': 'base',
    'relativeX': 4,
    'relativeY': 2,
    'catalogItemVariantId': 'v-chair',
  }));
  return b.forFloor('floor-1')!;
}

/// A 10×8 grass floor carrying the two kinds of named area: a team zone at (2, 4)
/// and a meeting room at (2, 1). Neither has walls, so nothing but a label can be
/// drawn outside the floor colour.
({SpaceArt art, SpaceMap map}) _sections() {
  final b = SpaceMapBuilder();
  b.apply('MapArea', _add({
    'id': 'base',
    'mapId': 'map-1',
    'relativeX': 0,
    'relativeY': 0,
    'dimensionsInTiles': _dims(10, 8),
    'mapAreaType': 'Public',
    'wallsTexture': 'NewStyleNoWall',
    'floorTexture': 'NewStyleGrass',
    'floorColor': 'Green',
  }));
  b.apply('FloorMap', _add({'id': 'map-1', 'floorId': 'floor-1', 'baseAreaId': 'base'}));
  b.apply('MapArea', _add({
    'id': 'team',
    'mapId': 'map-1',
    'parentAreaId': 'base',
    'relativeX': 2,
    'relativeY': 4,
    'dimensionsInTiles': _dims(6, 3),
    'mapAreaType': 'Team',
    'name': 'Frontend',
    'wallsTexture': 'NewStyleNoWall',
  }));
  b.apply('MapArea', _add({
    'id': 'meeting',
    'mapId': 'map-1',
    'parentAreaId': 'base',
    'relativeX': 2,
    'relativeY': 1,
    'dimensionsInTiles': _dims(6, 2),
    'mapAreaType': 'MeetingRoom',
    'name': 'Boardroom',
    'wallsTexture': 'NewStyleNoWall',
  }));
  return (art: b.artFor('floor-1')!, map: b.forFloor('floor-1')!);
}

/// A PNG of one flat colour, which is how a pixel read tells images apart.
Future<Uint8List> _png(Color colour, int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = colour,
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

const _grass = Color(0xFF00FF00);
const _wood = Color(0xFFFF0000);
const _wall = Color(0xFF0000FF);
const _sprite = Color(0xFFFFFF00);

/// Every image the art asks for, as a colour keyed by what it is.
Future<Uint8List?> _colours(String url, {int spriteSize = 32}) async {
  if (url.contains('/catalog/')) return _png(_sprite, spriteSize, spriteSize);
  if (url.contains('/walls/')) return _png(_wall, 32, url.contains('%20w.png') || url.contains('%20e.png') ? 32 : 64);
  if (url.contains('NewStyle_Grass')) return _png(_grass, 32, 32);
  return _png(_wood, 32, 32);
}

Future<ArtCache> _loaded(SpaceArt art, {int spriteSize = 32}) async {
  final cache = ArtCache(fetch: (url) => _colours(url, spriteSize: spriteSize));
  cache.prefetch(art.urls);
  for (var i = 0; i < 200 && !cache.settled; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(cache.settled, isTrue, reason: 'the art never finished loading');
  expect(cache.failed, 0);
  return cache;
}

/// Paint at 1:1 — one map pixel per image pixel — and read the result back.
///
/// [view] is the viewer's transform, which is where the painter reads the zoom from;
/// the default is none at all, meaning 1:1 and everything on screen.
Future<ui.Image> _paint(
  SpaceArt? art,
  ArtCache cache, {
  List<MapPerson> people = const [],
  TransformationController? view,
  SpaceMap? map,
  MapMotion? motion,
  ({int x, int y, SpaceRoom? room})? selection,
}) async {
  map ??= _map();
  final size = Size(map.width * artTileSize.toDouble(), map.height * artTileSize.toDouble());
  final recorder = ui.PictureRecorder();
  officePainter(
    map: map,
    art: art,
    cache: cache,
    people: people,
    partyActive: false,
    tokens: GatherTokens.dark,
    view: view,
    viewport: size,
    motion: motion,
    selection: selection,
  ).paint(Canvas(recorder, Offset.zero & size), size);
  return recorder.endRecording().toImage(size.width.round(), size.height.round());
}

/// An avatar sheet whose every frame is a different colour, so a pixel says which
/// frame was drawn: 72 frames of 32×64, frame *n* carrying red channel *n*.
Future<Uint8List> _sheet() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  for (var frame = 0; frame < 72; frame++) {
    canvas.drawRect(
      Rect.fromLTWH(frame * 32.0, 0, 32, 64),
      Paint()..color = Color.fromARGB(255, frame, 128, 200),
    );
  }
  final image = await recorder.endRecording().toImage(72 * 32, 64);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// A kart sheet in the same trick as [_sheet], distinguishable from it: 16 frames of
/// 32×32, frame *n* carrying red *n* over a **blue** channel of 7 rather than 200. A
/// kart is drawn over the body it hides, so telling the two apart at one pixel is the
/// whole of the test.
Future<Uint8List> _kartSheet() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  for (var frame = 0; frame < 16; frame++) {
    canvas.drawRect(
      Rect.fromLTWH(frame * 32.0, 0, 32, 32),
      Paint()..color = Color.fromARGB(255, frame, 128, 7),
    );
  }
  final image = await recorder.endRecording().toImage(16 * 32, 32);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

const _avatarUrl = 'https://sprite.v2.gather.town/v2/sprite/avatar-x.png';

extension on ByteData {
  /// The colour at a tile's centre, given the image is [width] pixels across.
  Color at(int width, double tileX, double tileY) =>
      pixel(width, ((tileX + 0.5) * artTileSize).round(), ((tileY + 0.5) * artTileSize).round());

  /// The colour at one map pixel. What [at] is built on, and what anything drawn at
  /// a tile's *edge* rather than its middle has to be read with.
  Color pixel(int width, int x, int y) {
    final offset = (y * width + x) * 4;
    return Color.fromARGB(
      getUint8(offset + 3),
      getUint8(offset),
      getUint8(offset + 1),
      getUint8(offset + 2),
    );
  }
}

void main() {
  test('the room floor covers the base area, not the other way round', () async {
    // Sorted by position the base area wins everywhere — it is the whole grid, so
    // its bottom edge is the lowest on the map. The layer lookup is what stops it.
    final art = _art();
    final image = await _paint(art, await _loaded(art));
    final pixels = (await image.toByteData())!;

    expect(pixels.at(image.width, 1, 1), _grass, reason: 'outside the room');
    expect(pixels.at(image.width, 4, 2), _wood, reason: 'inside the room');
  });

  test('walls stand on the room they belong to, and above the base floor', () async {
    final art = _art();
    final image = await _paint(art, await _loaded(art));
    final pixels = (await image.toByteData())!;

    // The north band sits *above* the room's first row: rows 0 and 1 for a room at
    // y = 2, which is why it can overlap what is behind it.
    expect(pixels.at(image.width, 2, 1), _wall);
    // The sides run down the room's own columns.
    expect(pixels.at(image.width, 2, 2), _wall);
    expect(pixels.at(image.width, 5, 2), _wall);
  });

  test('furniture draws over the floor it stands on', () async {
    final art = _art();
    final image = await _paint(art, await _loaded(art));
    final pixels = (await image.toByteData())!;

    expect(pixels.at(image.width, 3, 3), _sprite);
  });

  test('a body behind a desk is hidden by it; one in front is not', () async {
    // The whole point of sorting people into the prop list rather than over it. A
    // 64×64 sprite at tile (3, 3) covers tiles (3, 3) to (4, 4), and a fold of 63
    // puts its line at the bottom of that box — so a body on row 3 is behind it and
    // a body on row 4 is in front.
    final art = _art(spriteSize: 64, fold: 63);
    final cache = await _loaded(art, spriteSize: 64);
    const person = MapPerson(
      id: 'a',
      label: 'A',
      x: 3,
      y: 3,
      isFollowingMe: false,
      speaking: false,
    );

    final behind = await _paint(art, cache, people: [person]);
    expect(
      (await behind.toByteData())!.at(behind.width, 3, 3),
      _sprite,
      reason: 'a body at the desk should be covered by it',
    );

    final front = await _paint(art, cache, people: [
      const MapPerson(id: 'a', label: 'A', x: 3, y: 4, isFollowingMe: false, speaking: false),
    ]);
    expect(
      (await front.toByteData())!.at(front.width, 3, 4),
      isNot(_sprite),
      reason: 'a body in front of the desk should be drawn over it',
    );
  });

  test('with no art at all it still draws the schematic', () async {
    // The screen predates the artwork and has to survive the fetch failing, which on
    // a phone is a normal Tuesday.
    final image = await _paint(null, ArtCache(fetch: (_) async => null));
    final pixels = (await image.toByteData())!;

    expect(pixels.at(image.width, 1, 1).a, 1.0);
    expect(pixels.at(image.width, 1, 1), isNot(_grass));
  });

  group('the reticle', () {
    /// The map pixel at a tile's top-left corner, where a bracket's elbow sits.
    (int, int) corner(int tileX, int tileY) => (tileX * artTileSize, tileY * artTileSize);

    Future<ByteData> painted({
      required ({int x, int y, SpaceRoom? room})? selection,
      TransformationController? view,
    }) async {
      final image = await _paint(
        null,
        ArtCache(fetch: (_) async => null),
        selection: selection,
        view: view,
      );
      return (await image.toByteData())!;
    }

    test('a selected tile is bracketed at its corners', () async {
      final pixels = await painted(selection: (x: 4, y: 2, room: null));
      final (cx, cy) = corner(4, 2);
      final floor = pixels.at(320, 7, 6);

      // Measured as "not the floor" rather than against a colour. The mark is black
      // over a light halo, so which of the two a given pixel lands on depends on
      // where in the stroke it falls — but neither of them is the floor.
      expect(pixels.pixel(320, cx + 3, cy), isNot(floor),
          reason: 'the top arm of the top-left bracket');
      expect(pixels.pixel(320, cx, cy + 3), isNot(floor),
          reason: 'and its side arm');
    });

    test('the brackets are black, and nothing else', () async {
      // Black rather than the brand blue: the office's own artwork is full of blue —
      // the rugs, the sofas, half the desks — and a brand-coloured mark on top of it
      // reads as one more piece of furniture. Drawn as one pass, with no outline
      // under it: a light halo made the crosshair look like a sticker.
      final pixels = await painted(selection: (x: 4, y: 2, room: null));
      final (cx, cy) = corner(4, 2);

      final along = [for (var d = -2; d <= 2; d++) pixels.pixel(320, cx + 3, cy + d)];
      expect(along.map((c) => c.r).reduce((a, b) => a < b ? a : b), lessThan(0.15),
          reason: 'the stroke itself is black');
      expect(
        along.every((c) => c.r <= pixels.at(320, 7, 6).r + 0.01),
        isTrue,
        reason: 'and nothing beside it is lighter than the floor',
      );
    });

    test('the brackets leave the middle of the tile alone', () async {
      // The whole reason for this shape over a filled square: the tile you tapped
      // usually has the thing you tapped it for on it — a chair, a desk, somebody's
      // avatar — and a fill would hide it.
      final pixels = await painted(selection: (x: 4, y: 2, room: null));

      expect(pixels.at(320, 4, 2), pixels.at(320, 7, 6),
          reason: 'the middle is exactly the floor it was before');
    });

    test('an unselected floor is drawn without any of it', () async {
      final pixels = await painted(selection: null);
      final (cx, cy) = corner(4, 2);

      expect(pixels.pixel(320, cx + 3, cy), pixels.pixel(320, cx + 3, cy + 8));
    });

    test('the brackets keep their size on the glass, not on the map', () async {
      // The same rule the labels follow, and the reason it is not optional: left in
      // map pixels a 2-pixel stroke is a 40-pixel slab at 20x and a smear at 1x.
      //
      // Measured as reach rather than as brightness. At 8x every length this draws is
      // an eighth of what it is at 1x *in map pixels*, which is the same length on the
      // glass — and at that point the stroke is a quarter of a map pixel, so what a
      // pixel reads is a fraction of the colour rather than the colour.
      final (cx, cy) = corner(4, 2);
      final far = await painted(selection: (x: 4, y: 2, room: null));
      final floor = far.at(320, 7, 6);

      expect(far.pixel(320, cx + 6, cy), isNot(floor),
          reason: 'at 1x the arm is 8 map pixels long');

      final close = await painted(
        selection: (x: 4, y: 2, room: null),
        view: TransformationController()
          ..value = Matrix4.identity().scaledByDouble(8, 8, 8, 1),
      );

      expect(close.pixel(320, cx, cy), isNot(floor), reason: 'still drawn');
      expect(close.pixel(320, cx + 6, cy), floor,
          reason: 'but the arm no longer reaches a fifth of the way across the tile');
    });

    test('zoomed right out the mark is still exactly the tile', () async {
      // The bug this replaced: the reticle used to be held to a minimum size on the
      // glass, which zoomed all the way out inflated it to over twice the tile — so
      // the crosshair came visibly unstuck from the square it was marking. Every
      // length is a proportion of the tile now, with the on-glass figures acting only
      // as ceilings.
      final pixels = await painted(
        selection: (x: 4, y: 2, room: null),
        view: TransformationController()
          ..value = Matrix4.identity().scaledByDouble(0.1, 0.1, 0.1, 1),
      );
      final floor = pixels.at(320, 7, 6);
      final (cx, cy) = corner(4, 2);

      expect(pixels.pixel(320, cx + 1, cy + 1), isNot(floor), reason: 'drawn');

      // Nothing at all outside the tile it belongs to.
      for (var d = 0; d < artTileSize; d++) {
        expect(pixels.pixel(320, cx + d, cy - 2), floor, reason: 'above the tile');
        expect(pixels.pixel(320, cx - 2, cy + d), floor, reason: 'left of the tile');
        expect(pixels.pixel(320, cx + d, cy + artTileSize + 1), floor,
            reason: 'below the tile');
        expect(pixels.pixel(320, cx + artTileSize + 1, cy + d), floor,
            reason: 'right of the tile');
      }
    });

    test('a room target is bracketed around the whole room', () async {
      // `onPointerMove` snaps the highlighter to an area's bounding box rather than
      // to the tile under the pointer, with five pixels of padding.
      final room = SpaceRoom(
        id: 'r1',
        name: 'Boardroom',
        type: 'MeetingRoom',
        x: 2,
        y: 2,
        width: 4,
        height: 4,
        walled: true,
      );
      final pixels = await painted(selection: (x: 3, y: 3, room: room));
      final floor = pixels.at(320, 7, 6);

      // The room's own corner, five pixels out — not the tapped tile's.
      expect(pixels.pixel(320, 2 * artTileSize - 5 + 3, 2 * artTileSize - 5),
          isNot(floor));
      expect(pixels.at(320, 3, 3), floor,
          reason: 'and the tapped tile inside it is untouched');
    });
  });

  group('people', () {
    Future<ArtCache> cacheWithSheet() async {
      final sheet = await _sheet();
      final cache = ArtCache(
        fetch: (url) async => url == _avatarUrl ? sheet : _colours(url),
      );
      return cache;
    }

    Future<ui.Image> paintFacing(
      String? direction, {
      TransformationController? view,
      String label = 'Ada Lovelace',
      bool speaking = false,
      MapMotion? motion,
      double x = 4,
    }) async {
      final art = _art();
      final cache = await cacheWithSheet();
      cache.prefetch([...art.urls, _avatarUrl]);
      for (var i = 0; i < 200 && !cache.settled; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      return _paint(art, cache, view: view, motion: motion, people: [
        MapPerson(
          id: 'a',
          label: label,
          x: x,
          y: 2,
          isFollowingMe: false,
          speaking: speaking,
          avatarUrl: _avatarUrl,
          direction: direction,
        ),
      ]);
    }

    test('somebody with an outfit is drawn as themselves, facing their way', () async {
      // The red channel of the sheet is the frame index, so this reads back which
      // frame the painter chose: idle-s is 0, idle-n 18, idle-e 23.
      for (final (direction, frame) in [(null, 0), ('Up', 18), ('Right', 23)]) {
        final image = await paintFacing(direction);
        final pixels = (await image.toByteData())!;
        expect(
          pixels.at(image.width, 4, 2).r * 255,
          closeTo(frame, 1),
          reason: 'facing $direction should draw frame $frame',
        );
      }
    });

    Future<double> paintSeated({String? chair, String? facing}) async {
      final art = _art();
      final map = _seatedMap(orientation: chair);
      final sheet = await _sheet();
      final cache = ArtCache(fetch: (url) async => url == _avatarUrl ? sheet : _colours(url));
      cache.prefetch([...art.urls, _avatarUrl]);
      for (var i = 0; i < 200 && !cache.settled; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(map.isSeat(4, 2), isTrue, reason: 'the fixture puts a chair at (4, 2)');
      final image = await _paint(
        art,
        cache,
        map: map,
        people: [
          MapPerson(
            id: 'a',
            label: 'Ada',
            x: 4,
            y: 2,
            isFollowingMe: false,
            speaking: false,
            avatarUrl: _avatarUrl,
            direction: facing,
          ),
        ],
      );
      return (await image.toByteData())!.at(image.width, 4, 2).r * 255;
    }

    test('somebody sits the way their chair is turned, not the way they walked in', () {
      // The bug: a sitter was drawn on their own `direction`, and that is a separate
      // patch from the position. The client turns you in `applySittingDirection` —
      // `CATALOG_ORIENTATION_TO_MOVE_DIRECTION[seat.orientation]`, which is the
      // identity — and publishes the turn afterwards, so a roster can carry somebody
      // sat down and still facing the corridor they arrived along. idle-sit-w is
      // frame 14, idle-sit-n 21, idle-sit-s 5.
      return Future.wait([
        paintSeated(chair: 'Left', facing: 'Up').then((f) => expect(f, closeTo(14, 1))),
        paintSeated(chair: 'Down', facing: 'Right').then((f) => expect(f, closeTo(5, 1))),
      ]);
    });

    test('a chair that names no orientation leaves them as they were', () async {
      // `playerState` is the client's own and never reaches the wire, so sitting is
      // still worked out from the map: a `sittable` tile under the body. All 115
      // sittable variants on the measured space name an orientation, so this is the
      // defensive path rather than the usual one.
      expect(await paintSeated(facing: 'Up'), closeTo(21, 1));
    });

    test('somebody with no outfit keeps the dot', () async {
      final art = _art();
      final image = await _paint(art, await _loaded(art), people: [
        const MapPerson(
          id: 'a',
          label: 'Ada',
          x: 4,
          y: 2,
          isFollowingMe: false,
          speaking: false,
        ),
      ]);
      // Not the floor, and not the avatar sheet either — the marker.
      expect((await image.toByteData())!.at(image.width, 4, 2), isNot(_wood));
    });

    test('the name plate sits above the head, at every zoom', () async {
      // A name never comes off. Zone labels do — at 124 tiles across a phone
      // "Frontend" is wider than the desks it names — but "where is everybody" is the
      // question this screen exists to answer, and it is worth answering from across
      // the office.
      final anonymous = await paintFacing('Down', label: '');
      final bare = (await anonymous.toByteData())!.at(anonymous.width, 4, 0.9375);

      // The body is at tile (4, 2), so its own tile starts at y = 64 and the plate's
      // bottom edge is half a tile clear of it — at y = 48 whatever the zoom, since
      // it is the plate's *height* that shrinks as you close in. So y = 46 is inside
      // the plate at every zoom, and is the avatar's own head when there is none.
      for (final zoom in [0.2, 1.0, 2.0]) {
        final image = await paintFacing('Down', view: TransformationController()
          // All three axes: `getMaxScaleOnAxis` takes the largest, so leaving z at 1
          // would report a zoom of 1 however far out x and y are.
          ..value = Matrix4.identity().scaledByDouble(zoom, zoom, zoom, 1));
        expect(
          (await image.toByteData())!.at(image.width, 4, 0.9375),
          isNot(bare),
          reason: 'the name should still be there at ${zoom}x',
        );
      }

      // And nothing under the feet, where the plate used to be.
      final close = await paintFacing('Down');
      expect(
        (await close.toByteData())!.at(close.width, 4, 2.75),
        (await anonymous.toByteData())!.at(anonymous.width, 4, 2.75),
      );
    });


    test('somebody mid-step is drawn walking, and between the two tiles', () async {
      // Gather's positions are whole tiles — measured: all 98 rows of a live dump
      // carry integer `position.x`/`y` — so without this a walk is a hop, four times
      // a second. walk-s is frames 32–35.
      var now = Duration.zero;
      final motion = MapMotion(clock: () => now);
      const from = MapPerson(
        id: 'a',
        label: 'Ada',
        x: 4,
        y: 2,
        isFollowingMe: false,
        speaking: false,
        avatarUrl: _avatarUrl,
        direction: 'Down',
      );
      motion.update([from]);
      now += const Duration(seconds: 1);
      motion.update([
        const MapPerson(
          id: 'a',
          label: 'Ada',
          x: 3,
          y: 2,
          isFollowingMe: false,
          speaking: false,
          avatarUrl: _avatarUrl,
          direction: 'Down',
        ),
      ]);
      // Half of one tile's worth of walking: 1000/7 ms a tile.
      now += const Duration(microseconds: 71428);

      final image = await paintFacing('Down', x: 3, motion: motion);
      final pixels = (await image.toByteData())!;

      // The sheet's green channel is 128 everywhere, so this asks "is that a body".
      // A 32-wide sprite drawn at tile 3.5 covers pixels 112–143 and nothing either
      // side of that, which pins the position from both directions: snapped to tile 3
      // it would cover 104, snapped to 4 it would cover 152.
      double body(double tile) => pixels.at(image.width, tile, 2).g * 255;
      expect(body(3.5), closeTo(128, 1), reason: 'halfway between the two tiles');
      expect(body(2.75), isNot(closeTo(128, 1)), reason: 'not snapped back to tile 3');
      expect(body(4.25), isNot(closeTo(128, 1)), reason: 'not snapped on to tile 4');

      final frame = pixels.at(image.width, 3.5, 2).r * 255;
      expect(frame, greaterThanOrEqualTo(32), reason: 'walk-s is 32–35, not idle-s 0');
      expect(frame, lessThanOrEqualTo(35));
      motion.dispose();
    });

    /// Somebody driving, mid-step, with both sheets loaded.
    ///
    /// Mid-step because a kart's cycle is `moving-` only while the body is moving —
    /// and because the run cycle is only chosen while walking at all.
    Future<ByteData> paintDriving({Gait gait = Gait.driving}) async {
      var now = Duration.zero;
      final motion = MapMotion(clock: () => now);
      MapPerson at(double x) => MapPerson(
            id: 'a',
            label: 'Ada',
            x: x,
            y: 2,
            isFollowingMe: false,
            speaking: false,
            avatarUrl: _avatarUrl,
            direction: 'Down',
            gait: gait,
          );
      motion.update([at(4)]);
      now += const Duration(seconds: 1);
      motion.update([at(3)]);
      now += const Duration(microseconds: 71428);

      final art = _art();
      final sheet = await _sheet();
      final kart = await _kartSheet();
      final cache = ArtCache(fetch: (url) async => switch (url) {
            _avatarUrl => sheet,
            goKartUrl => kart,
            _ => _colours(url),
          });
      cache.prefetch([...art.urls, _avatarUrl, goKartUrl]);
      for (var i = 0; i < 200 && !cache.settled; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      final image = await _paint(art, cache, motion: motion, people: [at(3)]);
      motion.dispose();
      return (await image.toByteData())!;
    }

    test('somebody in a go-kart is drawn running, with the kart over the top', () async {
      // Two assertions in one pixel. The kart is a 32×32 sprite on the body's own
      // tile and the client draws it *in front* — `bringToTop(this.vehicleImage)` —
      // which is what makes a flat sprite read as something being sat in. So the
      // bottom half of the tile is kart, and the top half, a whole tile higher, is
      // still the running body underneath.
      final pixels = await paintDriving();

      // Blue 7 is the kart sheet, blue 200 the avatar's.
      final onTheTile = pixels.pixel(320, (3.5 * artTileSize).round(), (2.5 * artTileSize).round());
      expect(onTheTile.b * 255, closeTo(7, 1), reason: 'the kart is drawn over the legs');
      // `moving-s` is 4–7.
      expect(onTheTile.r * 255, inInclusiveRange(4, 7));

      // A tile higher is the avatar's own sprite, which hangs two tiles tall.
      final above = pixels.pixel(320, (3.5 * artTileSize).round(), (1.5 * artTileSize).round());
      expect(above.b * 255, closeTo(200, 1), reason: 'and the body above it is not hidden');
      // `run-s` is 36–39, and this is the whole point of sending `drive`: everybody
      // else reads `speed.modifier` and picks the run cycle off it.
      expect(above.r * 255, inInclusiveRange(36, 39));
    });

    test('somebody merely running gets the cycle and no kart', () async {
      final pixels = await paintDriving(gait: Gait.running);

      final onTheTile = pixels.pixel(320, (3.5 * artTileSize).round(), (2.5 * artTileSize).round());
      expect(onTheTile.b * 255, closeTo(200, 1), reason: 'no kart at a modifier of 2');
      expect(onTheTile.r * 255, inInclusiveRange(36, 39), reason: 'but still running');
    });

    test('somebody walking is drawn walking', () async {
      // The guard the two above are worth nothing without: `walk-s` is 32–35, and it
      // is one frame away from the run, so a mixed-up table would look almost right.
      final pixels = await paintDriving(gait: Gait.walking);

      final onTheTile = pixels.pixel(320, (3.5 * artTileSize).round(), (2.5 * artTileSize).round());
      expect(onTheTile.b * 255, closeTo(200, 1));
      expect(onTheTile.r * 255, inInclusiveRange(32, 35));
    });

    test('somebody talking has their mouth going', () async {
      // `talking-idle-s-1` is [1,0,0,1,0,0,1,0,0,0,1,0,1,0] over the pose's idle
      // frame, at 4fps — so a talking southbound body alternates frames 0 and 1. The
      // dot on the plate says who is available; this says who is actually speaking.
      //
      // Which frame lands first depends on the person's phase offset, which is the
      // point of the offset, so this samples a whole second: the longest run of shut
      // mouths in the loop is three, so any five consecutive quarter-seconds contain
      // at least one open one.
      var now = Duration.zero;
      final motion = MapMotion(clock: () => now);
      final frames = <double>{};
      for (var i = 0; i < 6; i++) {
        final image = await paintFacing('Down', speaking: true, motion: motion);
        frames.add((await image.toByteData())!.at(image.width, 4, 2).r * 255);
        now += const Duration(milliseconds: 250);
      }
      expect(frames, unorderedEquals(<Object>[closeTo(0, 0.5), closeTo(1, 0.5)]));
      motion.dispose();
    });
  });

  test('a team zone is labelled and a meeting room is not', () async {
    // The office names twenty-eight areas and only ten of them are zones people sit
    // in. Writing all of them across the floor made a contents page of it; the room
    // you are standing in is in the app bar instead.
    final sections = _sections();
    final image = await _paint(sections.art, await _loaded(sections.art), map: sections.map);
    final pixels = (await image.toByteData())!;

    // The plate floats above its zone rather than lying on it: the team area's top
    // edge is y = 128, and the capsule sits just clear of it, around y = 103 to 122.
    expect(
      pixels.at(image.width, 4.5, 3.02),
      isNot(_grass),
      reason: 'the team zone should be labelled above itself',
    );
    // The same place relative to the meeting room — top edge y = 32 — is bare floor.
    expect(
      pixels.at(image.width, 4.5, 0.02),
      _grass,
      reason: 'a meeting room gets no label on the map',
    );
    // And nothing is written inside the zone either.
    expect(pixels.at(image.width, 4.5, 5), _grass, reason: 'the zone itself stays clear');
  });

  test('a failed image is a hole, not a crash', () async {
    final art = _art();
    final cache = ArtCache(fetch: (url) async => url.contains('/catalog/') ? null : _colours(url));
    cache.prefetch(art.urls);
    for (var i = 0; i < 200 && !cache.settled; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(cache.failed, 1);
    final image = await _paint(art, cache);
    // The floor under the missing desk is still there.
    expect((await image.toByteData())!.at(image.width, 3, 3), _wood);
  });

  /// The office is asked for in one burst the moment the map lands, which on a
  /// phone is the moment the radio may still be coming up. What that burst does
  /// when it goes wrong is the difference between an office that draws a second
  /// late and one that is a schematic until you force-quit.
  group('fetching', () {
    /// Real delays, because [ArtCache] runs on real timers and real futures — a
    /// backoff is a `Timer` and a decode is a `Future`, and neither is something a
    /// fake clock can reach through.
    ///
    /// The ceiling is generous rather than tight. It is only reached when a test is
    /// about to fail anyway, and a suite sharing a machine with another one takes
    /// far longer per poll than the delay asks for — which is how the first version
    /// of these flaked.
    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 2000 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    test('an outage delays the office rather than losing it', () async {
      final art = _art();
      var offline = true;
      var attempts = 0;
      final cache = ArtCache(
        // Long enough that the office cannot spend all eight of its goes while this
        // test is still noticing the first round failed, short enough that the
        // recovery below is one wait rather than a pause in the suite.
        backoff: const Duration(milliseconds: 50),
        fetch: (url) async {
          attempts++;
          if (offline) throw const SocketException('the radio was still coming up');
          return _colours(url);
        },
      );

      addTearDown(cache.dispose);

      cache.prefetch(art.urls);
      await until(() => attempts >= art.urls.length);
      expect(cache.loaded, 0);
      // The one signal that anything is wrong. While a failure was permanent this
      // was true the moment the burst finished, so the legend went away and the
      // office looked finished rather than broken.
      expect(cache.settled, isFalse, reason: 'a cache waiting out a backoff is not settled');

      offline = false;
      await until(() => cache.settled);

      expect(cache.loaded, art.urls.length);
      expect(cache.failed, 0);
      // And it is the artwork, not the schematic underneath it.
      final image = await _paint(art, cache);
      expect((await image.toByteData())!.at(image.width, 3, 3), _sprite);
    });

    test('an outage that never ends is eventually called a hole', () async {
      var attempts = 0;
      final cache = ArtCache(
        backoff: const Duration(milliseconds: 5),
        fetch: (_) async {
          attempts++;
          throw const SocketException('there is no network');
        },
      );

      addTearDown(cache.dispose);

      cache.prefetch({'https://static.gather.town/a.png'});
      await until(() => cache.settled);

      expect(cache.failed, 1, reason: 'patience is bounded');
      expect(attempts, 8, reason: 'eight goes, and no more');
    });

    test('an answer is not argued with', () async {
      var attempts = 0;
      final cache = ArtCache(
        backoff: const Duration(milliseconds: 5),
        fetch: (_) async {
          attempts++;
          return null; // A 404, or a body that is not a picture.
        },
      );

      addTearDown(cache.dispose);

      cache.prefetch({'https://static.gather.town/gone.png'});
      await until(() => cache.settled);
      // Long enough that a backoff would have fired if one had been set.
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(attempts, 1, reason: 'a missing file costs one request, not eight');
      expect(cache.failed, 1);
    });

    test('a superseded office stops being fetched', () async {
      final asked = <String>[];
      final cache = ArtCache(fetch: (url) async {
        asked.add(url);
        return _png(_sprite, 32, 32);
      });

      addTearDown(cache.dispose);

      // Twenty pictures as the office looked before the `CatalogItem` rows landed,
      // and then as it looks once they have: the same art, a different spelling.
      Set<String> office({required bool stamped}) => {
            for (var i = 0; i < 20; i++)
              'https://static.gather.town/$i.png${stamped ? '?t=2026-08-04' : ''}',
          };

      cache.prefetch(office(stamped: false));
      cache.prefetch(office(stamped: true));
      await until(() => cache.settled);

      expect(cache.wanted, 20);
      expect(cache.loaded, 20);
      expect(asked.where((url) => url.contains('?t=')), hasLength(20));
      // Only what was already on the wire when the office was superseded. The rest
      // left the queue instead of being fetched ahead of the art that is drawn.
      expect(
        asked.where((url) => !url.contains('?t=')),
        hasLength(lessThanOrEqualTo(8)),
        reason: 'no more than one round of concurrency was wasted',
      );
    });

    test('replacing the office leaves the avatars alone', () async {
      var attempts = 0;
      final cache = ArtCache(fetch: (_) async {
        attempts++;
        return _png(_sprite, 32, 32);
      });

      addTearDown(cache.dispose);

      cache.prefetch({'https://gather/avatar.png'}, group: ArtRequest.avatars);
      await until(() => cache.settled);
      expect(cache.loaded, 1);

      cache.prefetch({'https://gather/floor.png'}, group: ArtRequest.office);
      await until(() => cache.wanted == 2 && cache.settled);

      expect(cache['https://gather/avatar.png'], isNotNull, reason: 'not evicted');
      expect(attempts, 2, reason: 'and not fetched again');
    });
  });
}
