import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:gather_client/gather_client.dart';

import '../src/app_state.dart';
import '../src/art_cache.dart';
import '../src/map_motion.dart';
import '../src/map_person.dart';
import '../theme/gather_theme.dart';
import 'dpad.dart';

/// The office, drawn — with Gather's own artwork.
///
/// This exists because the map turned out to be free. Gather never serves it over
/// REST, but every state dump carries it in full — rooms, furniture and the
/// collision shapes behind them — and this client used to discard all of it.
///
/// It used to stop there, at blocks of colour, on the reasoning that 124 tiles
/// across a phone is three pixels a tile and anything more detailed is a smudge.
/// That was right about the zoomed-out view and wrong about the screen: the map is
/// pannable, and once you are close enough to read a room name you are close enough
/// to want the desks in it. So the schematic is still here, underneath, and the real
/// art is drawn over it as it arrives.
///
/// **The art is fetched, not bundled.** Gather ships no tileset: the client resolves
/// one image per floor texture, wall piece and furniture variant, and so does
/// [SpaceArt]. On the space this was built against that is 573 images totalling
/// 222 KB, which is why "draw all of it" is a reasonable thing to do on a phone. See
/// `art_cache.dart` for the fetching and `space_art.dart` for where the URLs come
/// from.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key, required this.state});

  final AppState state;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  /// Owned by the screen rather than by [AppState]: it is decoded images, which is a
  /// rendering concern, and the disk half of it makes coming back cheap anyway.
  final _cache = ArtCache();

  SpaceArt? _art;

  @override
  void dispose() {
    _cache.dispose();
    super.dispose();
  }

  /// Ask for whatever this floor needs, once per distinct floor plan.
  ///
  /// The parent rebuilds this widget on every position tick, so the identity check
  /// matters: [SpaceArt] is rebuilt only when a map patch lands, which makes it a
  /// good proxy for "somebody moved the furniture".
  void _wantArt(SpaceArt? art) {
    if (identical(art, _art)) return;
    _art = art;
    if (art != null) _cache.prefetch(art.urls);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final map = widget.state.map;
    _wantArt(widget.state.art);

    // Everybody in the room, me included: "here" is a count of the office, and the
    // reader is standing in it. `peopleOnMap` deliberately excludes me, because
    // every other screen is asking about other people.
    final present =
        widget.state.peopleOnMap.length + (widget.state.mePerson == null ? 0 : 1);

    return Scaffold(
      backgroundColor: t.background,
      // Where the space name and the head count live: the map is the screen, and a
      // strip above it repeating what it already shows was costing the map a fifth
      // of a phone.
      appBar: AppBar(
        backgroundColor: t.background,
        titleSpacing: 0,
        title: _Where(space: widget.state.spaceName),
        actions: [
          if (map != null) _HeadCount(present: present),
          const SizedBox(width: 12),
        ],
      ),
      // Deliberately not wrapped in SafeArea: the floor runs under the home
      // indicator, which is what "fullscreen" has to mean for something you pan.
      body: map == null
          ? _Waiting(connected: widget.state.link.isLive)
          : _Plan(state: widget.state, map: map, art: _art, cache: _cache),
    );
  }
}

/// The space's name, in the app bar.
///
/// It used to carry a second line underneath — the named area you were standing
/// in, falling back to the floor's size in tiles. Both are gone. The area name
/// changed as you walked, which put a line of type that flickers directly under
/// the one that does not, and neither answer was worth the movement: the map
/// already draws the zone names on the floor, and nobody opens the office to find
/// out how many tiles it is.
class _Where extends StatelessWidget {
  const _Where({required this.space});

  /// The space's own name, from Gather.
  final String? space;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        space ?? 'The office',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
          color: t.foreground,
        ),
      ),
    );
  }
}

/// The head count, as a pill rather than a word: it changes while you watch it.
class _HeadCount extends StatelessWidget {
  const _HeadCount({required this.present});

  final int present;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: t.muted,
        borderRadius: BorderRadius.circular(t.radius),
        border: Border.all(color: t.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: present > 0 ? t.ok : t.faint,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$present here',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: present > 0 ? t.foreground : t.mutedForeground,
            ),
          ),
        ],
      ),
    );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting({required this.connected});

  final bool connected;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.map_outlined, size: 30, color: t.faint),
            const SizedBox(height: 14),
            Text(
              connected ? 'Reading the floor plan' : 'Not connected',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.mutedForeground),
            ),
            const SizedBox(height: 6),
            Text(
              connected
                  // True rather than reassuring: the map is ~1700 rows inside a dump
                  // of about 5000, so it lands a moment after the roster does.
                  ? 'Gather sends the map with everything else, so it arrives a '
                      'moment after the people do.'
                  : 'The map comes from Gather, so this needs the connection back.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, height: 1.5, color: t.faint),
            ),
          ],
        ),
      ),
    );
  }
}

/// The transform that puts [at] — a point in the child's own pixels — as near the
/// middle of the viewport as the edges of the map allow.
///
/// `M = T(centre − zoom·point) · S(zoom)` is the standard zoom-about-a-point, and
/// the clamp after it is the rule that there is never anything on screen that is not
/// map. The child is laid out to *cover* the viewport at `zoom == 1`, so
/// `viewport − child·zoom` is zero or negative and the range is always real; the
/// `math.min` only guards a degenerate size.
///
/// This is a function rather than a method because [InteractiveViewer] enforces the
/// same rule for drags and pinches (`boundaryMargin: EdgeInsets.zero`) and cannot
/// enforce it for a transform set from outside — which is every transform this
/// screen sets itself.
@visibleForTesting
Matrix4 framedOn({
  required Offset at,
  required Size viewport,
  required Size child,
  required double zoom,
}) {
  final scale = zoom.clamp(kMinZoom, kMaxZoom);
  final dx = (viewport.width / 2 - scale * at.dx)
      .clamp(math.min(0.0, viewport.width - child.width * scale), 0.0)
      .toDouble();
  final dy = (viewport.height / 2 - scale * at.dy)
      .clamp(math.min(0.0, viewport.height - child.height * scale), 0.0)
      .toDouble();
  return Matrix4.identity()
    ..translateByDouble(dx, dy, 0, 1)
    ..scaleByDouble(scale, scale, scale, 1);
}

/// Zoomed all the way out the map covers the screen exactly, so there is no zoom
/// below 1 that would not show something which is not office.
const double kMinZoom = 1;

/// A shade past one Gather pixel per screen pixel on a 3x display, and the point
/// where the art stops rewarding a closer look.
const double kMaxZoom = 20;

class _Plan extends StatefulWidget {
  const _Plan({
    required this.state,
    required this.map,
    required this.art,
    required this.cache,
  });

  final AppState state;
  final SpaceMap map;
  final SpaceArt? art;
  final ArtCache cache;

  @override
  State<_Plan> createState() => _PlanState();
}

class _PlanState extends State<_Plan> with TickerProviderStateMixin {
  /// Held rather than left to [InteractiveViewer] so a double tap can drive it and
  /// so "fit the floor again" is a thing the screen can offer.
  final _view = TransformationController();

  /// The walk. Owned here because it owns a [Ticker] and needs this screen's vsync;
  /// the painter listens to it rather than the widget tree rebuilding for footsteps.
  late final MapMotion _motion = MapMotion(vsync: this);

  late final AnimationController _zoom = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  Animation<Matrix4>? _zoomTo;

  /// Where the last double tap landed, in the viewer's own coordinates.
  Offset _tapped = Offset.zero;

  @override
  void initState() {
    super.initState();
    _zoom.addListener(() {
      final to = _zoomTo;
      if (to != null) _view.value = to.value;
    });
  }

  @override
  void dispose() {
    _motion.dispose();
    _zoom.dispose();
    _view.dispose();
    super.dispose();
  }

  /// Whether the opening shot has been framed yet.
  bool _placed = false;

  /// Open on yourself, close enough to see who is around you.
  ///
  /// The whole floor is 124 tiles across; arriving at that and hunting for your own
  /// body is the wrong first second. This waits for a position — it is scheduled
  /// after the frame that has one, and only fires once — and leaves the map alone
  /// from then on, because after that the viewer belongs to whoever is dragging it.
  void _centreOnMe(Size viewport, Size child, double base, List<MapPerson> people) {
    if (_placed) return;
    final me = people.where((p) => p.isMe).firstOrNull;
    if (me == null) return;
    _placed = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _view.value = framedOn(
        at: Offset((me.x + 0.5) * artTileSize * base, (me.y + 0.5) * artTileSize * base),
        viewport: viewport,
        child: child,
        zoom: _openingZoom,
      );
    });
  }

  /// Close enough that a desk is a desk, far enough to see the room it is in.
  static const _openingZoom = 3.0;

  /// Double tap zooms in on what was tapped, or back out again if already close.
  ///
  /// Pinch is [InteractiveViewer]'s own and needs nothing from us; this is the
  /// one-handed version of it, which on a map you are holding in one hand while
  /// walking to a meeting is the one that gets used. It is also the only one of the
  /// two the iOS Simulator can do without holding a modifier key down.
  void _onDoubleTap(Size viewport, Size child) {
    final current = _view.value.getMaxScaleOnAxis();
    final target = framedOn(
      // The tap is in viewport coordinates; the point under it is wherever the
      // current transform says it is.
      at: MatrixUtils.transformPoint(
        Matrix4.tryInvert(_view.value) ?? Matrix4.identity(),
        _tapped,
      ),
      viewport: viewport,
      child: child,
      zoom: current > 2.5 ? 1 : 4,
    );
    _zoomTo = Matrix4Tween(begin: _view.value, end: target)
        .animate(CurvedAnimation(parent: _zoom, curve: Curves.easeOutCubic));
    _zoom.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final map = widget.map;
    final art = widget.art;
    final cache = widget.cache;
    final t = context.tokens;
    final people = [...state.peopleOnMap, ?state.mePerson];

    // Avatars are fetched exactly like the furniture is, through the same cache, so
    // asking for them is a set difference on every build and a no-op once they land.
    cache.prefetch([for (final person in people) ?person.avatarUrl]);

    // Somebody who has asked the system to stop moving things gets the tiles the
    // wire reports, with no walk between them — which is what the desktop client
    // does with the same preference, rather than a degraded version of it.
    _motion.enabled = !MediaQuery.disableAnimationsOf(context);
    // Before the roster, not after: a hop we fired ourselves is the better answer for
    // the next few hundred milliseconds, and it has to be in place before the tiles
    // that follow it are applied. Replaying is not a risk — the hop carries a
    // sequence number and `noteTeleport` ignores one it has already drawn.
    _motion.noteTeleport(state.lastTeleport);
    _motion.update(people);

    return Stack(
      children: [
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, box) {
              final viewport = box.biggest;
              // Zoomed all the way out the floor *covers* the screen rather than
              // fitting inside it: whichever way it has to overflow, it does, and the
              // other dimension is exact. Letterboxing would waste the dimension a
              // phone has least of, and — with the boundary below — a map smaller than
              // the screen in either direction is a map you can drag the void into.
              final base = math.max(
                viewport.height / (map.height * artTileSize),
                viewport.width / (map.width * artTileSize),
              );
              final child = Size(
                map.width * artTileSize * base,
                map.height * artTileSize * base,
              );
              _centreOnMe(viewport, child, base, people);

              // The whole floor at once, pinchable and pannable. A map you cannot get
              // closer to is decoration, so the ceiling is 20x.
              return GestureDetector(
                onDoubleTapDown: (details) => _tapped = details.localPosition,
                onDoubleTap: () => _onDoubleTap(viewport, child),
                child: InteractiveViewer(
                  transformationController: _view,
                  // Sized here, so the viewer must not stretch it back to the
                  // viewport and undo the cover-the-screen decision above.
                  constrained: false,
                  minScale: kMinZoom,
                  maxScale: kMaxZoom,
                  // The child exactly, with no slack: pan stops at the edge of the
                  // office instead of dragging the background in beside it. The
                  // viewer applies this to drags and pinches; [framedOn] applies the
                  // same rule to the transforms this screen sets itself.
                  boundaryMargin: EdgeInsets.zero,
                  child: SizedBox.fromSize(
                    size: child,
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: _OfficePainter(
                          map: map,
                          art: art,
                          cache: cache,
                          people: people,
                          partyActive: state.party.active,
                          tokens: t,
                          view: _view,
                          viewport: viewport,
                          motion: _motion,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        // Floating over the map rather than taking a strip from it, and only while
        // it has something to say.
        Positioned(
          left: 12,
          right: 12,
          bottom: 12,
          child: SafeArea(top: false, child: _Legend(cache: cache, art: art)),
        ),
        // Centred across the bottom, so it is the same reach from either hand. High
        // enough off the edge to sit above the home indicator rather than fight it for
        // the same gesture, and above the legend rather than over it.
        if (state.canWalk)
          Positioned(
            left: 0,
            right: 0,
            bottom: 64,
            child: SafeArea(
              top: false,
              child: Center(
                child: DPad(onPress: state.walk, onRelease: state.stopWalking),
              ),
            ),
          ),
      ],
    );
  }
}

/// The key, or the loading line while there is still art in flight.
class _Legend extends StatelessWidget {
  const _Legend({required this.cache, required this.art});

  final ArtCache cache;
  final SpaceArt? art;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return AnimatedBuilder(
      animation: cache,
      builder: (context, _) {
        // Once the art is down there is nothing left worth covering the floor with:
        // the bodies are avatars now, and a key explaining that a person is a person
        // was answering a question the map stopped asking.
        if (art == null || cache.settled) return const SizedBox.shrink();
        return Align(
          alignment: Alignment.bottomLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: t.card.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(t.radius),
              border: Border.all(color: t.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(strokeWidth: 1.6, color: t.faint),
                ),
                const SizedBox(width: 8),
                Text(
                  'Drawing the office — ${cache.loaded} of ${cache.wanted}',
                  style: TextStyle(fontSize: 11.5, color: t.mutedForeground),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The painter, for tests that want to draw without standing up a whole app.
///
/// Worth a seam because what this file does that can go wrong is *painting* — the
/// widgets around it are an app bar and an [InteractiveViewer], and no widget finder
/// can tell a floor drawn over a room from one drawn under it.
@visibleForTesting
CustomPainter officePainter({
  required SpaceMap map,
  required SpaceArt? art,
  required ArtCache cache,
  required List<MapPerson> people,
  required bool partyActive,
  required GatherTokens tokens,
  TransformationController? view,
  Size? viewport,
  MapMotion? motion,
}) =>
    _OfficePainter(
      map: map,
      art: art,
      cache: cache,
      people: people,
      partyActive: partyActive,
      tokens: tokens,
      view: view,
      viewport: viewport,
      motion: motion,
    );

class _OfficePainter extends CustomPainter {
  _OfficePainter({
    required this.map,
    required this.art,
    required this.cache,
    required this.people,
    required this.partyActive,
    required this.tokens,
    this.view,
    this.viewport,
    this.motion,
  }) : super(
          repaint: Listenable.merge([cache, ?view, ?motion]),
        );

  final SpaceMap map;
  final SpaceArt? art;
  final ArtCache cache;

  /// Everybody on this floor, me included — the map is the one screen where I am
  /// just another body to draw.
  final List<MapPerson> people;
  final bool partyActive;

  /// The viewer's own transform, read at paint time rather than passed as a number.
  ///
  /// It has to come from here: this painter sits under a [RepaintBoundary], so its
  /// canvas is a fresh recording whose clip is the whole map however far out the
  /// viewer is. `getLocalClipBounds()` therefore always answered "all of it", which
  /// silently disabled both the culling and the labels that depend on the zoom.
  /// Null means "no viewer": the map is drawn whole, at whatever size it is given.
  final TransformationController? view;

  /// What the viewer is showing it through, in logical pixels. Defaults to the
  /// painted size, which is the same thing when there is no viewer.
  final Size? viewport;
  final GatherTokens tokens;

  /// The walk between the tiles the wire reports. Null means "draw them on their
  /// tiles, standing still", which is what a still test render wants.
  final MapMotion? motion;

  /// Pixels per tile in Gather's own coordinates. Everything in [SpaceArt] is in
  /// these, and the canvas is scaled once to fit them on screen.
  static const _tile = artTileSize;

  @override
  void paint(Canvas canvas, Size size) {
    // Child pixels per map pixel: the canvas scale this painter applies. The viewer
    // then multiplies it by its own zoom to reach the glass.
    final base = size.width / (map.width * _tile);
    final matrix = view?.value ?? Matrix4.identity();
    final zoom = matrix.getMaxScaleOnAxis();

    // What is genuinely on screen, in map pixels. Inside an InteractiveViewer the
    // whole map is laid out and only a slice is visible; at two thousand draws a
    // frame that slice is worth knowing about.
    final inverse = Matrix4.tryInvert(matrix);
    final shown = inverse == null
        ? Offset.zero & size
        : MatrixUtils.transformRect(inverse, Offset.zero & (viewport ?? size));
    final visible = Rect.fromLTWH(
      shown.left / base,
      shown.top / base,
      shown.width / base,
      shown.height / base,
    ).inflate(_tile.toDouble() * 2);

    // One clock reading for the whole frame, and one position per body taken from
    // it. Sampling the walk twice inside a single paint would let a body's name plate
    // disagree with its feet by however long the paint took.
    final now = motion?.now ?? Duration.zero;
    final where = {
      for (final person in people)
        person.id: motion?.positionOf(person, now) ?? Offset(person.x, person.y),
    };

    canvas.save();
    canvas.scale(base);

    final paint = Paint()
      // Pixel art: no smoothing, or every 32×32 tile turns to mush at close zoom.
      ..isAntiAlias = false
      ..filterQuality = FilterQuality.none;

    _paintSchematic(canvas);
    final art = this.art;
    if (art != null) _paintGround(canvas, art, paint, visible);
    _paintProps(canvas, art, paint, visible, where, now);
    // Names and room labels last: they are the one thing that must never end up
    // behind a pot plant.
    _paintLabels(canvas, visible, base * zoom, where, now);

    canvas.restore();
  }

  /// The floor plan as it was before there were pictures: blocks of colour for the
  /// rooms, one rect per blocked tile for the furniture.
  ///
  /// Still drawn, underneath everything, and not only as a placeholder — it is what
  /// the screen falls back to when the art cannot be fetched at all, and it is
  /// legible at the zoom where the sprites are three pixels wide.
  void _paintSchematic(Canvas canvas) {
    final width = map.width * _tile.toDouble();
    final height = map.height * _tile.toDouble();
    canvas.drawRect(Rect.fromLTWH(0, 0, width, height), Paint()..color = tokens.card);

    final rooms = [...map.rooms.where((r) => r.name != null)]
      ..sort((a, b) => (b.width * b.height).compareTo(a.width * a.height));
    for (final room in rooms) {
      canvas.drawRect(
        Rect.fromLTWH(
          room.x * _tile.toDouble(),
          room.y * _tile.toDouble(),
          room.width * _tile.toDouble(),
          room.height * _tile.toDouble(),
        ),
        Paint()..color = tokens.brand.withValues(alpha: room.walled ? 0.10 : 0.05),
      );
    }

    // Only worth drawing while the floor above it is still missing: over the real
    // art these blocks would be a grey haze on top of the furniture they stand for.
    if (art == null || cache.loaded == 0) {
      final blocked = Path();
      for (var y = 0; y < map.height; y++) {
        for (var x = 0; x < map.width; x++) {
          if (map.isWalkable(x, y)) continue;
          blocked.addRect(
            Rect.fromLTWH(x * _tile.toDouble(), y * _tile.toDouble(), _tile.toDouble(), _tile.toDouble()),
          );
        }
      }
      canvas.drawPath(blocked, Paint()..color = tokens.border);
    }
  }

  /// Floors and walls, in the order [SpaceArt.ground] hands them over.
  ///
  /// That order is the client's three ground layers — base area, `Public` zones,
  /// then rooms and desks — and it is a lookup rather than a coordinate. Sorting it
  /// by position instead paints the base area, the tallest rectangle on the map,
  /// over every room inside it.
  void _paintGround(Canvas canvas, SpaceArt art, Paint paint, Rect visible) {
    for (final item in art.ground) {
      final image = cache[item.url];
      if (image == null) continue;
      final rect = Rect.fromLTWH(item.left, item.top, item.width, item.height);
      if (!rect.overlaps(visible)) continue;

      switch (item) {
        case ArtFloor():
          // A floor is one 32×32 tile repeated, so it is a shader rather than a
          // loop — the base area alone is 124×82 of them.
          canvas.drawRect(
            rect,
            Paint()
              ..isAntiAlias = false
              ..filterQuality = FilterQuality.none
              ..shader = ui.ImageShader(
                image,
                TileMode.repeated,
                TileMode.repeated,
                (Matrix4.identity()..setTranslationRaw(item.left, item.top, 0)).storage,
                filterQuality: FilterQuality.none,
              ),
          );
        case ArtWall():
          canvas.drawImageRect(
            image,
            Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
            rect,
            paint,
          );
      }
    }
  }

  void _paintProp(Canvas canvas, ArtSprite prop, Paint paint, Rect visible) {
    final image = cache[prop.url];
    if (image == null) return;
    final width = image.width.toDouble();
    final height = image.height.toDouble();
    final rect = Rect.fromLTWH(prop.left, prop.top, width, height);
    if (!rect.overlaps(visible)) return;
    canvas.drawImageRect(image, Rect.fromLTWH(0, 0, width, height), rect, paint);
  }

  /// Furniture and people in one pass, sorted together, then the parts of the
  /// furniture that stand in front of everybody.
  ///
  /// Gather sorts players into the same depth list as the props, which is what puts
  /// somebody *behind* the desk they are sitting at rather than on it. A body's
  /// depth is the line it stands on — the bottom of its tile — the same measure
  /// `updateDepth` uses for a sprite's fold. The near half of an object is a separate
  /// `foregroundRenderable` for exactly this reason, and goes on last.
  void _paintProps(
    Canvas canvas,
    SpaceArt? art,
    Paint paint,
    Rect visible,
    Map<String, Offset> where,
    Duration now,
  ) {
    // A body's depth is the line it stands on: the bottom of its own tile — and the
    // tile it is drawn on rather than the one the wire last named, or somebody walking
    // out from behind a desk pops in front of it a quarter of a second early.
    //
    // Somebody mid-teleport is two entries rather than one. The body they left is at a
    // different place on the floor and has to sort by *that* line, or a ghost left
    // behind a desk is drawn standing on it.
    final bodies = <({MapPerson person, Offset at, double alpha, double scale})>[];
    for (final person in people) {
      final flash = motion?.flashOf(person, now);
      bodies.add((
        person: person,
        at: where[person.id]!,
        alpha: flash?.alpha ?? 1,
        scale: flash?.scale ?? 1,
      ));
      if (flash != null) {
        bodies.add((
          person: person,
          at: flash.ghostAt,
          alpha: flash.ghostAlpha,
          scale: 1,
        ));
      }
    }
    bodies.sort((a, b) => a.at.dy.compareTo(b.at.dy));

    // A merge, not a concatenation: `props` is already sorted and the bodies now are
    // too, so this walks both once.
    final props = art?.props ?? const <ArtSprite>[];
    var next = 0;
    void body(int i) => _paintPerson(
          canvas,
          bodies[i].person,
          paint,
          bodies[i].at,
          now,
          alpha: bodies[i].alpha,
          scale: bodies[i].scale,
        );

    for (final prop in props) {
      if (prop.foreground) continue;
      while (next < bodies.length && (bodies[next].at.dy + 1) * _tile <= prop.depth) {
        body(next);
        next++;
      }
      _paintProp(canvas, prop, paint, visible);
    }
    while (next < bodies.length) {
      body(next);
      next++;
    }

    for (final prop in props) {
      if (prop.foreground) _paintProp(canvas, prop, paint, visible);
    }
  }

  /// Somebody, as their own avatar when we have one and as a pin when we do not.
  ///
  /// The sheet is 72 frames of 32×64 in a row and the frame is chosen the way the
  /// client chooses it — `idle-s` is frame 0, `idle-n` 18, `idle-w` 9, `idle-e` 23 —
  /// so people face the way they are actually facing. Sprites hang a tile above
  /// their own tile, which is `defaultAvatarOffsetY = -32` in the client and is what
  /// puts the feet on the floor rather than the head.
  ///
  /// Nothing is drawn around a body — no ring, no shadow. Gather draws people as
  /// people, and "which one is me" is answered by the name plate above the head
  /// rather than by a halo on the floor.
  /// [alpha] and [scale] are the teleport, and are 1 for everybody standing still.
  /// A body arriving fades and grows into place; the one it left behind dissolves at
  /// full size. See `../src/map_motion.dart`.
  void _paintPerson(
    Canvas canvas,
    MapPerson person,
    Paint paint,
    Offset at,
    Duration now, {
    double alpha = 1,
    double scale = 1,
  }) {
    final sheet = person.avatarUrl == null ? null : cache[person.avatarUrl!];

    if (sheet == null) {
      // The fallback, for anybody whose outfit never arrived. Not a ring around a
      // body — a stand-in for one.
      final middle = Offset((at.dx + 0.5) * _tile, (at.dy + 0.5) * _tile);
      final colour = person.isMe
          ? tokens.brand
          : person.isFollowingMe
              ? tokens.ok
              : tokens.mutedForeground;
      final radius = _tile * 0.42 * scale;
      canvas.drawCircle(
          middle, radius + 3, Paint()..color = tokens.background.withValues(alpha: 0.55 * alpha));
      canvas.drawCircle(middle, radius, Paint()..color = colour.withValues(alpha: alpha));
      return;
    }

    final posture = _posture(person, now);
    final frame = avatarAnimation(facing: posture.facing, pose: posture.pose)
        .frameAt(motion?.phaseOf(person, now) ?? Duration.zero);

    // Grown about the feet rather than the middle: a sprite scaled around its centre
    // sinks into the floor on the way in, and the tile somebody stands on is the one
    // thing about a body that must not move.
    final width = avatarFrameWidth * scale;
    final height = avatarFrameHeight * scale;
    final floor = at.dy * _tile + avatarOffsetY + avatarFrameHeight;
    canvas.drawImageRect(
      sheet,
      Rect.fromLTWH(
        (frame * avatarFrameWidth).toDouble(),
        0,
        avatarFrameWidth.toDouble(),
        avatarFrameHeight.toDouble(),
      ),
      Rect.fromLTWH(
        at.dx * _tile + (avatarFrameWidth - width) / 2,
        floor - height,
        width,
        height,
      ),
      // The shared paint carries the pixel-art settings and is reused for everybody
      // at full opacity; a fading body needs its own, since the alpha that fades it
      // is the paint's own colour.
      alpha >= 1
          ? paint
          : (Paint()
            ..isAntiAlias = false
            ..filterQuality = FilterQuality.none
            ..color = const Color(0xFFFFFFFF).withValues(alpha: alpha.clamp(0.0, 1.0))),
    );
  }

  /// What somebody is doing and which way they are pointing.
  ///
  /// `updateMoveStateVisuals` asks moving-then-sitting-then-idle, and speaking is
  /// layered over the idles by `handleAnimationEnds`. Sitting is not on the wire —
  /// `playerState` is the client's own and never sent — so it is worked out the way
  /// Gather works it out: you are sitting when you are standing on a chair's
  /// `sittable` tile. The tile asked about is the one the wire named rather than the
  /// one the body is sliding across, or somebody walking over a chair sits down for a
  /// frame on their way past.
  ///
  /// A sitter faces their chair rather than the way they walked in. The client turns
  /// them in `applySittingDirection` and publishes the turn, but it does so as a
  /// patch of its own, arriving separately from the position — so a roster can carry
  /// somebody sat down and still facing the corridor. `seatFacing` is the same answer
  /// without the race; somebody's own direction is the fallback for a chair that
  /// names no orientation.
  ({Pose pose, Facing facing}) _posture(MapPerson person, Duration now) {
    final facing = Facing.of(person.direction);
    if (motion?.walking(person, now) ?? false) {
      return (pose: Pose.walking, facing: facing);
    }
    final x = person.x.round();
    final y = person.y.round();
    if (map.isSeat(x, y)) {
      final chair = map.seatFacing(x, y);
      return (
        pose: person.speaking ? Pose.talkingSitting : Pose.sitting,
        facing: chair == null ? facing : Facing.of(chair),
      );
    }
    return (pose: person.speaking ? Pose.talking : Pose.standing, facing: facing);
  }

  /// Team-area names and name plates, laid out on the glass and scaled into the map.
  ///
  /// Everything here is measured in screen pixels at a fixed type size and the canvas
  /// is scaled to put it down on the map, rather than the type being sized in map
  /// pixels against the zoom. That buys two things. A label is exactly the same size
  /// on the glass at every zoom, which is what a label is for; and because the font
  /// size never changes, a name's [TextPainter] is laid out once and kept, instead of
  /// every person on the map being re-laid-out on every frame of a pinch.
  void _paintLabels(
    Canvas canvas,
    Rect visible,
    double onGlass,
    Map<String, Offset> where,
    Duration now,
  ) {
    // Map pixels per screen pixel — the factor that undoes the zoom.
    final scale = 1 / onGlass;

    // Only the team areas. The floor also names fourteen meeting rooms, three commons
    // and a lobby, and writing all of them across it turned the office into a contents
    // page — the zones people sit in are what you navigate by, and the room you are
    // standing in is already in the app bar. On the measured space this is ten labels
    // instead of twenty-eight.
    //
    // Unlike a name, a zone label is gated on there being room to read it: at 124
    // tiles across a phone "Frontend" is wider than the desks it names.
    if (onGlass * _tile >= _zonesAbove) {
      for (final area in map.rooms) {
        final name = area.name;
        if (name == null || area.type != _sectionType) continue;
        final rect = Rect.fromLTWH(
          area.x * _tile.toDouble(),
          area.y * _tile.toDouble(),
          area.width * _tile.toDouble(),
          area.height * _tile.toDouble(),
        );
        if (!rect.overlaps(visible)) continue;
        // White, and only two-thirds of it: a zone name is a thing you read when you
        // are looking for it, not a thing that should compete with the people.
        final label = _text(name, tokens.primaryForeground.withValues(alpha: 0.66));
        if (_plateWidth(label) * scale > rect.width) continue;
        // Floating above the zone rather than lying on it: a team area is full of the
        // desks it exists to group, and a label inside it covers one of them.
        _plate(
          canvas,
          Offset(rect.center.dx, rect.top - (_plateHeight(label) / 2 + _zoneGap) * scale),
          label,
          scale,
          fill: tokens.background.withValues(alpha: 0.62),
        );
      }
    }

    // Names last, and at every zoom. They are drawn after the zones deliberately: a
    // person standing at the top edge of their team area puts the two plates in the
    // same place, and the one naming somebody who is actually there wins.
    for (final person in people) {
      if (person.label.isEmpty) continue;
      final label = _text(person.label, person.isMe ? tokens.primaryForeground : tokens.foreground);
      // Above the head, which is half a tile above the body's own tile: an avatar
      // frame is 64 tall and hung 32 above its tile, and across the sheets sampled the
      // highest hat still starts 14 pixels below that tile's top edge.
      final body = where[person.id] ?? Offset(person.x, person.y);
      final at = Offset(
        (body.dx + 0.5) * _tile,
        body.dy * _tile - _tile * 0.5 - _plateHeight(label) / 2 * scale,
      );
      if (!visible.contains(at)) continue;
      // A plate arrives with the body it names. Faded through a layer rather than by
      // tinting the text: a colour is part of a [TextPainter]'s cache key, so fading
      // one that way would lay a name out afresh on every frame of the effect.
      final arriving = motion?.flashOf(person, now)?.alpha ?? 1;
      if (arriving < 1) {
        canvas.saveLayer(
          Rect.fromCenter(
            center: at,
            width: (_plateWidth(label, dot: true) + 2) * scale,
            height: (_plateHeight(label) + 2) * scale,
          ),
          Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: arriving.clamp(0.0, 1.0)),
        );
      }
      _plate(
        canvas,
        at,
        label,
        scale,
        // Mine in the brand colour, everybody else's on the app's own ground — the
        // same two-tier distinction Gather draws, and the same one the follower cards
        // make, so "which one is me" is answered without a ring around anybody.
        // Opaque, so a plate that lands on a zone label covers it rather than mixing
        // two names into one smudge.
        fill: person.isMe ? tokens.brand : tokens.background,
        dot: availabilityColor(tokens, person.availability),
      );
      if (arriving < 1) canvas.restore();
    }
  }

  /// The `mapAreaType` of the zones people mean when they say where they sit.
  static const _sectionType = 'Team';

  /// Screen pixels per tile below which the zone names come off. Names have no such
  /// floor: "where is everybody" is the question this screen exists to answer, and it
  /// is worth answering from across the office.
  static const _zonesAbove = 9;

  // The plate, in screen pixels. The proportions are Gather's, read off its own.
  static const _size = 11.0;
  static const _padX = _size * 0.62;
  static const _padY = _size * 0.34;
  static const _dotRadius = _size * 0.30;
  static const _dotGap = _size * 0.34;

  /// The gap between a zone's top edge and the bottom of its label.
  static const _zoneGap = _size * 0.5;

  double _plateWidth(TextPainter label, {bool dot = false}) =>
      label.width + _padX * 2 + (dot ? _dotRadius * 2 + _dotGap : 0);

  double _plateHeight(TextPainter label) => label.height + _padY * 2;

  /// Gather's own label: text on a dark lozenge, rounded to a capsule, with an
  /// availability dot in front of it when there is somebody to be available.
  ///
  /// [centre] is the middle of the plate in *map* pixels, so callers position it by
  /// whichever edge they actually care about; [scale] is map pixels per screen pixel,
  /// and everything inside is drawn on the glass.
  void _plate(
    Canvas canvas,
    Offset centre,
    TextPainter label,
    double scale, {
    required Color fill,
    Color? dot,
  }) {
    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.scale(scale);

    final lead = dot == null ? 0.0 : _dotRadius * 2 + _dotGap;
    final box = Rect.fromCenter(
      center: Offset.zero,
      width: _plateWidth(label, dot: dot != null),
      height: _plateHeight(label),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(box, Radius.circular(box.height / 2)),
      Paint()..color = fill,
    );
    if (dot != null) {
      canvas.drawCircle(
        Offset(box.left + _padX + _dotRadius, 0),
        _dotRadius,
        Paint()..color = dot,
      );
    }
    label.paint(canvas, Offset(box.left + _padX + lead, -label.height / 2));

    canvas.restore();
  }

  /// Laid-out text, kept between frames.
  ///
  /// A [TextPainter] lays out on construction and the map has ninety-odd rooms and a
  /// hundred people; re-laying all of that out sixty times a second is real work for
  /// a string that has not changed. It only works because the type size is fixed —
  /// while labels were sized in map pixels the key changed on every frame of a pinch
  /// and the cache was a cache of one frame.
  static final Map<String, TextPainter> _labels = {};

  TextPainter _text(String value, Color colour) {
    final key = '$value/${colour.toARGB32()}';
    final cached = _labels[key];
    if (cached != null) return cached;
    // Bounded: a space can churn through names, and this must not become a leak.
    if (_labels.length > 400) _labels.clear();
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          fontSize: _size,
          height: 1.1,
          color: colour,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout();
    return _labels[key] = painter;
  }

  @override
  bool shouldRepaint(_OfficePainter old) =>
      old.map != map ||
      old.art != art ||
      old.partyActive != partyActive ||
      old.people.length != people.length ||
      // Positions change without the count changing, which is most of the time.
      !_samePlaces(old.people, people);

  static bool _samePlaces(List<MapPerson> a, List<MapPerson> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i].x != b[i].x ||
          a[i].y != b[i].y ||
          a[i].speaking != b[i].speaking ||
          // The dot on the name plate: going busy moves nothing and still changes
          // what the map says about you.
          a[i].availability != b[i].availability) {
        return false;
      }
    }
    return true;
  }
}
