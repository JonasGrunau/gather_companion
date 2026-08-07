import 'package:flutter/material.dart';
import 'package:gather_client/gather_client.dart';

import '../src/app_state.dart';
import '../src/map_person.dart';
import '../theme/gather_theme.dart';

/// The office, drawn.
///
/// This exists because the map turned out to be free. Gather never serves it over
/// REST, but every state dump carries it in full — rooms, furniture and the
/// collision shapes behind them — and this client used to discard all of it. Once
/// [SpaceMap] decodes that into tiles, a screen showing them is a few hundred lines
/// away, and it answers the question the follower card cannot: *where is everyone*.
///
/// It is a floor plan, not a game view. There are no sprites, no scrolling camera
/// and no attempt to look like Gather — a 124×82 grid on a phone is about three
/// pixels a tile, so anything more detailed than a block of colour is a smudge. The
/// job is: where are the rooms, where are the people, and where am I.
class MapScreen extends StatelessWidget {
  const MapScreen({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final map = state.map;

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.background,
        title: const Text('The office'),
        titleTextStyle: Theme.of(context).textTheme.titleLarge,
      ),
      body: SafeArea(
        top: false,
        child: map == null ? _Waiting(connected: state.link.isLive) : _Plan(state: state, map: map),
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

class _Plan extends StatelessWidget {
  const _Plan({required this.state, required this.map});

  final AppState state;
  final SpaceMap map;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final people = state.peopleOnMap;
    final me = state.myTile;
    final here = me == null ? null : map.roomAt(me.x, me.y);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  here?.name ?? '${map.width}×${map.height} tiles',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: t.mutedForeground),
                ),
              ),
              Text(
                '${people.length} here',
                style: TextStyle(fontSize: 12, color: t.faint),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            // The whole floor at once, pannable and zoomable. A phone screen across
            // 124 tiles is unreadable at 1:1, and a map you cannot get closer to is
            // decoration.
            child: InteractiveViewer(
              maxScale: 8,
              boundaryMargin: const EdgeInsets.all(60),
              child: Center(
                child: AspectRatio(
                  aspectRatio: map.width / map.height,
                  child: CustomPaint(
                    painter: _PlanPainter(
                      map: map,
                      people: people,
                      me: me,
                      partyActive: state.party.active,
                      tokens: t,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              _Key(color: t.brand, label: 'You'),
              _Key(color: t.ok, label: 'Following you'),
              _Key(color: t.mutedForeground, label: 'Someone else'),
              _Key(color: t.border, label: 'Furniture'),
            ],
          ),
        ),
      ],
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(fontSize: 11.5, color: t.faint)),
      ],
    );
  }
}

class _PlanPainter extends CustomPainter {
  _PlanPainter({
    required this.map,
    required this.people,
    required this.me,
    required this.partyActive,
    required this.tokens,
  });

  final SpaceMap map;
  final List<MapPerson> people;
  final ({int x, int y})? me;
  final bool partyActive;
  final GatherTokens tokens;

  @override
  void paint(Canvas canvas, Size size) {
    final tile = size.width / map.width;

    // 1. The floor.
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = tokens.card,
    );

    // 2. Named rooms, as tinted blocks under everything else. Drawn largest first
    // so a desk inside a team zone still reads as its own thing.
    final rooms = [...map.rooms.where((r) => r.name != null)]
      ..sort((a, b) => (b.width * b.height).compareTo(a.width * a.height));
    for (final room in rooms) {
      canvas.drawRect(
        Rect.fromLTWH(room.x * tile, room.y * tile, room.width * tile, room.height * tile),
        Paint()..color = tokens.brand.withValues(alpha: room.walled ? 0.10 : 0.05),
      );
    }

    // 3. Furniture. One rect per blocked tile is several hundred draw calls;
    // batching them into a single path keeps this cheap enough to repaint on every
    // roster.
    final blocked = Path();
    for (var y = 0; y < map.height; y++) {
      for (var x = 0; x < map.width; x++) {
        if (map.isWalkable(x, y)) continue;
        blocked.addRect(Rect.fromLTWH(x * tile, y * tile, tile, tile));
      }
    }
    canvas.drawPath(blocked, Paint()..color = tokens.border);

    // 4. Walls, as outlines rather than filled tiles — which is what they actually
    // are. Gather blocks *movement between* a room's edge and the tile outside it,
    // not the edge tile itself, so a wall is a line on a boundary and you can stand
    // on it.
    final walls = Path();
    for (final room in map.rooms) {
      // Not `rooms`: that list is filtered to the named ones, and a private desk is
      // walled without being named.
      if (!room.walled) continue;
      walls.addRect(
        Rect.fromLTWH(room.x * tile, room.y * tile, room.width * tile, room.height * tile),
      );
    }
    canvas.drawPath(
      walls,
      Paint()
        ..color = tokens.mutedForeground
        ..style = PaintingStyle.stroke
        ..strokeWidth = (tile * 0.5).clamp(1.0, 3.0),
    );

    // 5. People. Never smaller than a finger-visible dot, however far out we are.
    final r = (tile * 1.6).clamp(2.5, 9.0);
    for (final person in people) {
      canvas.drawCircle(
        Offset((person.x + 0.5) * tile, (person.y + 0.5) * tile),
        r,
        Paint()..color = person.isFollowingMe ? tokens.ok : tokens.mutedForeground,
      );
      if (person.speaking) {
        canvas.drawCircle(
          Offset((person.x + 0.5) * tile, (person.y + 0.5) * tile),
          r + 2.5,
          Paint()
            ..color = tokens.ok
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4,
        );
      }
    }

    // 6. Me, last and largest, with a ring while the party is on — which is the one
    // time this screen is worth watching rather than glancing at.
    final here = me;
    if (here != null) {
      final at = Offset((here.x + 0.5) * tile, (here.y + 0.5) * tile);
      if (partyActive) {
        canvas.drawCircle(
          at,
          r + 5,
          Paint()
            ..color = tokens.brand.withValues(alpha: 0.35)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
      canvas.drawCircle(at, r + 1.5, Paint()..color = Colors.white);
      canvas.drawCircle(at, r, Paint()..color = tokens.brand);
    }
  }

  @override
  bool shouldRepaint(_PlanPainter old) =>
      old.map != map ||
      old.me != me ||
      old.partyActive != partyActive ||
      old.people.length != people.length ||
      // Positions change without the count changing, which is most of the time.
      !_samePlaces(old.people, people);

  static bool _samePlaces(List<MapPerson> a, List<MapPerson> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i].x != b[i].x || a[i].y != b[i].y || a[i].speaking != b[i].speaking) return false;
    }
    return true;
  }
}
