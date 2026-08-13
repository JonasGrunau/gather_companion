/// The people, drawn: outfits, the sprite service, and which frame to show.
///
/// Gather composites an avatar server-side. The client never assembles one out of
/// layers — it names the outfit and asks `sprite.v2.gather.town` for the finished
/// spritesheet:
///
///     https://sprite.v2.gather.town/v2/sprite/avatar-<hash>.png
///
/// 2304×64 comes back: **72 frames of 32×64**, in one row. Public, no credentials.
///
/// ## The hash is not a hash
///
/// `SpriteService.hashOutfit` reads like one and is not. It is the outfit's wearable
/// ids joined with `.`, plus the newest `lastSyncAuthoredAt` among those wearables:
///
/// ```js
/// hashOutfit(A){
///   const e = compactNil(A);                    // drop the empty slots
///   let g = DateTimeExt.fromJSDate(new Date(0));
///   for (const A of Object.values(e)) {
///     const e = Wearable.get(A); if (!e) continue;
///     if (e.lastSyncAuthoredAt > g) g = e.lastSyncAuthoredAt;
///   }
///   return `${Object.values(e).join(SPRITESHEET_DELIMITER)}.${g.toStrippedUtcIsoString()}`;
/// }
/// ```
///
/// Three things about that are load-bearing, and each was checked against the live
/// service rather than assumed:
///
///  - **`SPRITESHEET_DELIMITER` is `"."`**, so a hash is a run of UUIDs separated by
///    dots and the trailing timestamp is just one more field.
///  - **Order is `toOutfit()`'s order** — `pick(['skin','hair','facialHair','top',
///    'bottom','shoes','hat','glasses','other','costume','mobility','jacket'])` — and
///    it is `Object.values` of that pick, so the order is the pick's, not the wire's.
///  - **The timestamp is `yyyyMMdd'T'HHmmss'Z'`**, UTC, seconds — Luxon's format
///    string, not an ISO-8601 round trip.
///
/// Get any of the three wrong and the service answers 404, so a rendered avatar is
/// the proof this is right.
///
/// ## Frames
///
/// Read out of the client's own animation table (`Ae` in the essentials sprite
/// class), which is why standing still faces the right way and sitting down does not
/// look like standing on a chair.
library;

import 'dart:math' as math;

/// One frame of an avatar sheet, in pixels.
const avatarFrameWidth = 32;
const avatarFrameHeight = 64;

/// Sprites are two tiles tall and hang one tile above the body's own tile —
/// `defaultAvatarOffsetY = -32 * scale` in the client.
const avatarOffsetY = -32;

/// Which way somebody is facing, as `SpaceUser.direction` spells it.
///
/// The wire words are `Up`, `Down`, `Left`, `Right`; the client maps them to the
/// `n`/`s`/`w`/`e` suffixes its animation names use, and defaults to south for
/// anything missing or unrecognised.
enum Facing {
  south('Down'),
  north('Up'),
  west('Left'),
  east('Right');

  const Facing(this.wire);

  final String wire;

  static Facing of(String? direction) => switch (direction) {
        'Up' => Facing.north,
        'Left' => Facing.west,
        'Right' => Facing.east,
        _ => Facing.south,
      };
}

/// What somebody is doing, as far as it changes which frame they are drawn on.
///
/// These are the client's own animation states minus the ones nothing on the wire
/// can tell us about. It has emotes too — clapping, waving, laughing, confetti — but
/// those live on a second *extras* spritesheet and are announced over a channel this
/// app does not listen to, so there is no honest way to draw them.
enum Pose { standing, sitting, walking, dancing, talking, talkingSitting }

/// One animation out of the client's table: which frames, how fast, and whether it
/// loops — `{sequence, frameRate, loop}` in `Ae`, transcribed.
class AvatarAnimation {
  const AvatarAnimation({required this.frames, required this.fps, required this.loop});

  final List<int> frames;

  /// Frames a second. Not always 7: the client declares a still pose as a
  /// single-frame animation at 60, and the talking loops run at 4.
  final double fps;

  final bool loop;

  /// The frame to draw [elapsed] into the animation.
  ///
  /// A looping animation wraps; a one-shot one holds its last frame, which is what
  /// `loop: false` means in Phaser and what makes sitting down end up sat down.
  int frameAt(Duration elapsed) {
    if (frames.length == 1) return frames.first;
    final step = elapsed.inMicroseconds * fps ~/ Duration.microsecondsPerSecond;
    if (step <= 0) return frames.first;
    return loop ? frames[step % frames.length] : frames[math.min(step, frames.length - 1)];
  }
}

/// The animation to play, straight out of the client's `Ae` table.
///
/// ```js
/// "idle-s":{frameRate:60,sequence:[0]}   "idle-n":[18]  "idle-w":[9]  "idle-e":[23]
/// "idle-sit-s":[5]  "idle-sit-n":[21]  "idle-sit-w":[14]  "idle-sit-e":[28]
/// "walk-s":{loop:true,frameRate:7,sequence:[32,35],useSequenceAsRange:true}
/// "walk-w":40-43  "walk-n":48-51  "walk-e":56-59
/// dance:{loop:true,frameRate:7,sequence:[12,15],useSequenceAsRange:true}
/// talking-idle-*: {loop:true,frameRate:4,…}
/// ```
///
/// `run-*` (36-39, 44-47, 52-55, 60-63) is deliberately absent: the client picks it
/// on `speed.modifier > 1`, and on the space this was measured against all 98 rows
/// report a modifier of exactly 1, so nothing here could ever choose it honestly.
AvatarAnimation avatarAnimation({required Facing facing, Pose pose = Pose.standing}) =>
    switch (pose) {
      Pose.standing => _standing[facing]!,
      Pose.sitting => _sitting[facing]!,
      Pose.walking => _walking[facing]!,
      Pose.talking => _talking[facing]!,
      Pose.talkingSitting => _talkingSitting[facing]!,
      Pose.dancing => _dancing,
    };

/// A single frame of [avatarAnimation], for a caller sampling rather than animating.
///
/// [tick] indexes into the sequence and wraps, so a still pose ignores it.
int avatarFrame({
  required Facing facing,
  Pose pose = Pose.standing,
  int tick = 0,
}) {
  final frames = avatarAnimation(facing: facing, pose: pose).frames;
  return frames[tick % frames.length];
}

/// Built once rather than per draw: a hundred people at sixty frames a second is a
/// lot of identical little lists otherwise.
final _standing = {
  for (final MapEntry(key: facing, value: frame) in _idle.entries)
    facing: AvatarAnimation(frames: [frame], fps: 60, loop: false),
};

final _sitting = {
  for (final MapEntry(key: facing, value: frame) in _idleSit.entries)
    facing: AvatarAnimation(frames: [frame], fps: 60, loop: false),
};

final _walking = {
  for (final MapEntry(key: facing, value: start) in const {
    Facing.south: 32,
    Facing.west: 40,
    Facing.north: 48,
    Facing.east: 56,
  }.entries)
    facing: AvatarAnimation(
      frames: [start, start + 1, start + 2, start + 3],
      fps: 7,
      loop: true,
    ),
};

const _dancing = AvatarAnimation(frames: [12, 13, 14, 15], fps: 7, loop: true);

const _idle = {Facing.south: 0, Facing.west: 9, Facing.north: 18, Facing.east: 23};
const _idleSit = {Facing.south: 5, Facing.west: 14, Facing.north: 21, Facing.east: 28};

/// `talking-idle-*-1`: mouth open on the ones, shut on the zeros.
///
/// All eight of the client's first-variant talking loops — four directions, standing
/// and sitting — are this same mask laid over the pose's own idle frame, because the
/// open-mouthed frame is always the idle frame plus one. So it is carried once
/// instead of eight times.
///
/// The client hand-authors three variants of each and picks one at random per
/// utterance, purely so that a table of people talking is not chewing in unison.
/// The map screen gets the same effect by starting each person's clock at a
/// different offset, for one sequence rather than twenty-four.
const _talkMask = [1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0];

final _talking = {
  for (final MapEntry(key: facing, value: frame) in _idle.entries)
    facing: AvatarAnimation(
      frames: [for (final open in _talkMask) frame + open],
      fps: 4,
      loop: true,
    ),
};

final _talkingSitting = {
  for (final MapEntry(key: facing, value: frame) in _idleSit.entries)
    facing: AvatarAnimation(
      frames: [for (final open in _talkMask) frame + open],
      fps: 4,
      loop: true,
    ),
};

/// `SpaceUserOutfit` slots, in `toOutfit()`'s order. The order is the hash.
const outfitSlots = [
  'skin',
  'hair',
  'facialHair',
  'top',
  'bottom',
  'shoes',
  'hat',
  'glasses',
  'other',
  'costume',
  'mobility',
  'jacket',
];

/// `SpriteService.hashOutfit`, transcribed.
///
/// [authoredAt] answers a wearable id with its `lastSyncAuthoredAt`; unknown ids
/// contribute nothing, exactly as `Wearable.get` returning nothing does. Null when
/// the outfit is empty, which is a person with no avatar rather than an error.
String? hashOutfit(
  Map<String, Object?> outfit,
  DateTime? Function(String wearableId) authoredAt,
) {
  final worn = [
    for (final slot in outfitSlots)
      if (outfit[slot] case final String id when id.isNotEmpty) id,
  ];
  if (worn.isEmpty) return null;

  // `new Date(0)`, so an outfit whose wearables are all unknown still hashes — to
  // the epoch — rather than dropping out.
  var newest = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  for (final id in worn) {
    final at = authoredAt(id);
    if (at != null && at.isAfter(newest)) newest = at;
  }
  return '${worn.join('.')}.${_stamp(newest)}';
}

/// The finished spritesheet: 72 frames of 32×64 in one row.
String avatarSpriteUrl(String hash) => '$_spriteHost/v2/sprite/avatar-$hash.png';

/// The same outfit as a single portrait, for a face beside a name.
String avatarPortraitUrl(String hash) => '$_spriteHost/v2/sprite-profile/avatar-$hash.png';

const _spriteHost = 'https://sprite.v2.gather.town';

/// `DateTimeExt.toStrippedUtcIsoString` — Luxon's `yyyyMMdd'T'HHmmss'Z'`, in UTC.
String _stamp(DateTime at) {
  final utc = at.toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}${two(utc.month)}${two(utc.day)}'
      'T${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
}
