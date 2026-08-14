/// The faces. Everybody the SFU is sending us, plus your own camera.
///
/// ## Why this is a route and not a panel
///
/// Video wants the screen. The map answers "where is everyone", the control bar
/// answers "what am I doing", and neither has room for a person's face at a size
/// worth looking at. Pushing a route also means the renderers exist only while
/// somebody is looking at them, which is the whole ballgame for battery: an
/// `RTCVideoRenderer` that is off-screen still decodes.
///
/// ## The renderer lifecycle is the thing to get right
///
/// `RTCVideoRenderer` is a native texture with a manual lifecycle: `initialize()`
/// before use, `dispose()` after, and `srcObject = null` *before* the stream
/// underneath it goes away. Get the order wrong and you get a black rectangle
/// that never recovers, or a crash in the platform view when a track is stopped
/// while still attached. That is why [_VideoTile] is a `StatefulWidget` holding
/// exactly one renderer, keyed by participant, and why the key matters: a reused
/// element pointed at a different stream would show the last person's frame.
///
/// ## The test seam
///
/// `RTCVideoRenderer.initialize()` needs a `MethodChannel`, which does not exist
/// under `flutter test`. [CallScreen.buildTile] lets a widget test swap the video
/// surface for something inert and assert on layout, naming and the empty states
/// — everything except the pixels, which are the platform's job anyway.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../src/app_state.dart';
import '../src/media/call.dart';
import '../src/media/live_call.dart';
import '../src/media/sfu_session.dart';
import '../theme/gather_theme.dart';
import 'person_avatar.dart';

/// One face to draw, resolved from call state and the roster.
class CallTile {
  const CallTile({
    required this.id,
    required this.label,
    required this.isSelf,
    required this.videoLive,
    required this.muted,
    required this.sharingScreen,
    this.stream,
    this.photoUrl,
    this.availability,
    this.speaking = false,
  });

  /// `SpaceUser.id` when we could place them, otherwise the media `srcId`. Only
  /// ever used for the avatar's colour and the widget key, both of which want
  /// stability rather than meaning.
  final String id;
  final String label;
  final bool isSelf;
  final bool videoLive;
  final bool muted;
  final bool sharingScreen;
  final MediaStream? stream;
  final String? photoUrl;
  final String? availability;
  final bool speaking;
}

typedef CallTileBuilder = Widget Function(BuildContext context, CallTile tile);

/// The call, at the size it is being drawn.
///
/// Stateful for one reason beyond layout: **somebody has to tell the SFU that
/// anyone is looking.** A peer publishes its smallest simulcast layer until a
/// consumer asks for better, so a face filling a phone screen stays a
/// quarter-resolution thumbnail unless this screen says otherwise — and, more
/// usefully, everybody drops back to that thumbnail the moment this route is
/// popped, because the map draws no video and nothing else here wants the
/// bandwidth. That is `consume-set-spatial`, and it is the receive-side half of
/// the simulcast the publisher already implements.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key, required this.state, this.buildTile});

  final AppState state;

  /// Swapped out under `flutter test`, where there is no platform view to make.
  final CallTileBuilder? buildTile;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  List<String> _watching = const [];
  VideoQuality _quality = VideoQuality.thumbnail;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_noteWatching);
    _noteWatching();
  }

  @override
  void dispose() {
    widget.state.removeListener(_noteWatching);
    // Nobody is looking any more. Said on the way out rather than left to a
    // timeout, because until it is said every peer keeps encoding a layer for a
    // screen that has gone — their battery, spent on our behalf.
    unawaited(
      widget.state.callHandle?.setWatching(
            const [],
            quality: VideoQuality.thumbnail,
          ) ??
          Future<void>.value(),
    );
    super.dispose();
  }

  /// Who is on screen and how big, in the same terms [_Grid] lays them out in.
  void _noteWatching() {
    final call = widget.state.call;
    final ids = [for (final person in call.participants) person.srcId];
    // Ourselves included, because the self tile takes a share of the screen
    // without anybody having to send it to us.
    final tiles = ids.length + (call.media.capturing ? 1 : 0);
    final quality = switch (tiles) {
      0 || 1 => VideoQuality.full,
      2 => VideoQuality.half,
      _ => VideoQuality.thumbnail,
    };

    if (quality == _quality &&
        ids.length == _watching.length &&
        Iterable<int>.generate(ids.length).every((i) => ids[i] == _watching[i])) {
      return;
    }
    _watching = ids;
    _quality = quality;
    unawaited(
      widget.state.callHandle?.setWatching(ids, quality: quality) ??
          Future<void>.value(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Scaffold(
      backgroundColor: t.background,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: widget.state,
          builder: (context, _) {
            final tiles = _tiles(widget.state);
            return Column(
              children: [
                _Header(count: tiles.where((tile) => !tile.isSelf).length),
                Expanded(
                  child: tiles.isEmpty
                      ? const _Nobody()
                      : _Grid(
                          tiles: tiles,
                          buildTile: widget.buildTile ?? _defaultTile,
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  static Widget _defaultTile(BuildContext context, CallTile tile) =>
      _VideoTile(tile: tile);
}

/// Call state plus roster, folded into what a tile needs.
///
/// Kept out of the widgets so a test can build the same list without a tree, and
/// so the two-plane identity bridge lives in one readable place rather than
/// scattered through `build`.
@visibleForTesting
List<CallTile> tilesFor(AppState state) => _tiles(state);

List<CallTile> _tiles(AppState state) {
  final call = state.call;
  final handle = state.callHandle;
  final live = handle is LiveCall ? handle : null;

  final tiles = <CallTile>[
    // Ourselves first, and only while the camera is actually open — a self tile
    // showing an avatar when nothing is captured is just a second name badge.
    if (call.media.capturing)
      CallTile(
        id: state.mePerson?.id ?? 'self',
        label: 'You',
        isSelf: true,
        videoLive: call.cameraOn,
        muted: !call.micOn,
        sharingScreen: false,
        stream: live?.localStream,
      ),
  ];

  for (final person in call.participants) {
    final row = state.rowForSrcId(person.srcId);
    final streams = live?.streamFor(person.srcId) ?? const {};
    tiles.add(CallTile(
      id: row?.id ?? person.srcId,
      // Somebody the roster has not placed yet is still in the call and still
      // audible, so they get a tile with an honest placeholder rather than
      // being dropped from a list they are demonstrably part of.
      label: row?.name ?? 'Someone',
      isSelf: false,
      videoLive: person.videoLive,
      muted: person.muted,
      sharingScreen: person.sharingScreen,
      // A screen share is the thing worth looking at when there is one.
      stream: person.sharingScreen
          ? streams[SfuTag.screen] ?? streams[SfuTag.video]
          : streams[SfuTag.video],
      photoUrl: row == null ? null : state.photoUrlFor(row.id),
      availability: row?.availability,
      speaking: row?.speaking ?? false,
    ));
  }
  return tiles;
}

class _Header extends StatelessWidget {
  const _Header({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back),
            color: t.foreground,
            tooltip: 'Back',
          ),
          Expanded(
            child: Text(
              switch (count) {
                0 => 'Nobody else here',
                1 => '1 other person',
                _ => '$count other people',
              },
              style: TextStyle(
                color: t.foreground,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One, two, or a grid.
///
/// Not a `GridView`: the counts that matter are small and each has a shape worth
/// having. One person fills the screen. Two split it, stacked, because a phone is
/// tall and two side-by-side portraits are two slivers. Three or more go to two
/// columns, which is where a grid finally earns its keep.
class _Grid extends StatelessWidget {
  const _Grid({required this.tiles, required this.buildTile});

  final List<CallTile> tiles;
  final CallTileBuilder buildTile;

  @override
  Widget build(BuildContext context) {
    Widget wrap(CallTile tile) => KeyedSubtree(
          key: ValueKey(tile.id),
          child: buildTile(context, tile),
        );

    if (tiles.length == 1) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: wrap(tiles.single),
      );
    }
    if (tiles.length == 2) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            for (final tile in tiles)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: wrap(tile),
                ),
              ),
          ],
        ),
      );
    }
    return GridView.count(
      padding: const EdgeInsets.all(8),
      crossAxisCount: 2,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 3 / 4,
      children: [for (final tile in tiles) wrap(tile)],
    );
  }
}

class _Nobody extends StatelessWidget {
  const _Nobody();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.groups_outlined, size: 40, color: t.faint),
            const SizedBox(height: 12),
            Text(
              'Nobody is in this conversation yet.',
              textAlign: TextAlign.center,
              style: TextStyle(color: t.mutedForeground, fontSize: 14),
            ),
            const SizedBox(height: 6),
            Text(
              'Walk up to someone on the map, and they will appear here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: t.faint, fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }
}

/// One face, with its own renderer.
class _VideoTile extends StatefulWidget {
  const _VideoTile({required this.tile});

  final CallTile tile;

  @override
  State<_VideoTile> createState() => _VideoTileState();
}

class _VideoTileState extends State<_VideoTile> {
  final _renderer = RTCVideoRenderer();
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _renderer.initialize();
    if (!mounted) {
      // Initialised into a widget that has already gone. Dispose it here or the
      // texture leaks with nobody left to free it.
      await _renderer.dispose();
      return;
    }
    setState(() => _ready = true);
    _attach();
  }

  @override
  void didUpdateWidget(_VideoTile old) {
    super.didUpdateWidget(old);
    // `videoLive` as well as the stream. Somebody turning their camera back on
    // keeps the same stream id, so comparing streams alone would leave the
    // renderer detached and show a frozen avatar over a live track.
    if (old.tile.stream?.id != widget.tile.stream?.id ||
        old.tile.videoLive != widget.tile.videoLive) {
      _attach();
    }
  }

  void _attach() {
    if (!_ready) return;
    _renderer.srcObject = widget.tile.videoLive ? widget.tile.stream : null;
  }

  @override
  void dispose() {
    // Detach before disposing. The renderer holding a stream that is being
    // stopped underneath it is the crash this ordering avoids.
    _renderer.srcObject = null;
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tile = widget.tile;
    // Deliberately no `_attach()` here. Assigning `srcObject` is a platform call
    // with a side effect, and `build` can run for reasons that have nothing to do
    // with this tile — a theme change, a parent rebuild — so doing it here would
    // reattach the texture at arbitrary moments. `initState` and
    // `didUpdateWidget` are the two places the stream can actually have changed.
    return _TileFrame(
      tile: tile,
      video: _ready && tile.videoLive && tile.stream != null
          ? RTCVideoView(
              _renderer,
              mirror: tile.isSelf,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            )
          : null,
    );
  }
}

/// The chrome around a tile: the fallback face, the name, the mute pip.
///
/// Split from [_VideoTile] so a widget test can render the whole layout — names,
/// badges, the speaking ring — without a platform view anywhere near it.
@visibleForTesting
class TileFrame extends StatelessWidget {
  const TileFrame({super.key, required this.tile, this.video});

  final CallTile tile;
  final Widget? video;

  @override
  Widget build(BuildContext context) => _TileFrame(tile: tile, video: video);
}

class _TileFrame extends StatelessWidget {
  const _TileFrame({required this.tile, this.video});

  final CallTile tile;
  final Widget? video;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(t.radius),
        border: Border.all(
          // The speaking ring, the same signal the map draws over their head.
          color: tile.speaking ? t.brand : t.border,
          width: tile.speaking ? 2 : 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(t.radius),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (video != null)
              video!
            else
              Center(
                child: PersonAvatar(
                  id: tile.id,
                  label: tile.label,
                  photoUrl: tile.photoUrl,
                  size: 64,
                  availability: tile.availability,
                  dotRing: t.card,
                ),
              ),
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(child: _Plate(text: tile.label)),
                  if (tile.muted) ...[
                    const SizedBox(width: 6),
                    const _Plate(icon: Icons.mic_off, text: ''),
                  ],
                  if (tile.sharingScreen) ...[
                    const SizedBox(width: 6),
                    const _Plate(icon: Icons.screen_share_outlined, text: ''),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Plate extends StatelessWidget {
  const _Plate({this.text = '', this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        // Its own scrim rather than a token: this sits on top of video, whose
        // brightness nothing can predict, and a themed fill would vanish against
        // half the frames it lands on.
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) Icon(icon, size: 13, color: Colors.white),
            if (icon != null && text.isNotEmpty) const SizedBox(width: 4),
            if (text.isNotEmpty)
              Flexible(
                child: Text(
                  text,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
