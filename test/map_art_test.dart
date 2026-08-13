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
SpaceMap _seatedMap() {
  final b = _bareMap();
  b.apply('CatalogItem', _add({'id': 'i-chair', 'family': 'Chair'}));
  b.apply('CatalogItemVariant', _add({
    'id': 'v-chair',
    'catalogItemId': 'i-chair',
    'originX': 0,
    'originY': 0,
    'dimensionsInPixels': _dims(32, 32),
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

const _avatarUrl = 'https://sprite.v2.gather.town/v2/sprite/avatar-x.png';

extension on ByteData {
  /// The colour at a tile's centre, given the image is [width] pixels across.
  Color at(int width, double tileX, double tileY) {
    final x = ((tileX + 0.5) * artTileSize).round();
    final y = ((tileY + 0.5) * artTileSize).round();
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

    test('somebody on a chair is drawn sitting, facing the same way', () async {
      // `playerState` is the client's own and never reaches the wire, so sitting is
      // worked out from the map: a `sittable` tile under the body. idle-sit-s is
      // frame 5, idle-sit-n 21.
      final art = _art();
      final map = _seatedMap();
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
          const MapPerson(
            id: 'a',
            label: 'Ada',
            x: 4,
            y: 2,
            isFollowingMe: false,
            speaking: false,
            avatarUrl: _avatarUrl,
            direction: 'Up',
          ),
        ],
      );
      expect((await image.toByteData())!.at(image.width, 4, 2).r * 255, closeTo(21, 1));
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
}
