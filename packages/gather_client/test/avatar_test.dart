/// The avatar hash, which is not a hash, and the frame table.
///
/// Every expectation here is transcribed from `SpriteService.hashOutfit` and the
/// client's own animation table, and the shape was checked against the live sprite
/// service: a wrong slot order, a wrong delimiter or a wrong timestamp format all
/// produce a 404 rather than a wrong-looking person, so these are the difference
/// between avatars and nothing.
library;

import 'package:gather_client/gather_client.dart';
import 'package:test/test.dart';

DateTime _at(String iso) => DateTime.parse(iso);

void main() {
  group('hashOutfit', () {
    test('joins the worn slots with dots and stamps the newest wearable', () {
      final hash = hashOutfit(
        {'skin': 'skin-1', 'hair': 'hair-1', 'top': 'top-1'},
        (id) => switch (id) {
          'skin-1' => _at('2026-01-02T03:04:05.000Z'),
          'hair-1' => _at('2026-08-04T08:17:37.478Z'),
          _ => _at('2025-12-31T23:59:59.000Z'),
        },
      );

      // Seconds, UTC, no punctuation — Luxon's `yyyyMMdd'T'HHmmss'Z'`. The
      // milliseconds on the newest wearable are dropped, not rounded.
      expect(hash, 'skin-1.hair-1.top-1.20260804T081737Z');
    });

    test('slot order is the client\'s pick order, not the map\'s', () {
      // `toOutfit()` picks skin, hair, facialHair, top, bottom, shoes, … and the
      // hash is `Object.values` of that pick. Handing the fields over in another
      // order has to make no difference, or half the space renders as a 404.
      final ordered = hashOutfit(
        {'skin': 'a', 'hair': 'b', 'top': 'c', 'shoes': 'd'},
        (_) => null,
      );
      final shuffled = hashOutfit(
        {'shoes': 'd', 'top': 'c', 'skin': 'a', 'hair': 'b'},
        (_) => null,
      );

      expect(ordered, shuffled);
      expect(ordered, startsWith('a.b.c.d.'));
    });

    test('empty slots are dropped, not sent as blanks', () {
      final hash = hashOutfit(
        {'skin': 'a', 'hair': null, 'facialHair': '', 'top': 'b'},
        (_) => null,
      );
      expect(hash, startsWith('a.b.'));
    });

    test('an outfit with nothing on is no avatar rather than an empty one', () {
      expect(hashOutfit(const {}, (_) => null), isNull);
      expect(hashOutfit(const {'skin': null}, (_) => null), isNull);
    });

    test('wearables we have never seen leave the stamp at the epoch', () {
      // `new Date(0)` in the client. It still produces a URL; whether the service
      // knows it is the service's business.
      expect(hashOutfit({'skin': 'a'}, (_) => null), 'a.19700101T000000Z');
    });

    test('the sprite URLs are the sprite service, not the asset host', () {
      expect(
        avatarSpriteUrl('a.b.19700101T000000Z'),
        'https://sprite.v2.gather.town/v2/sprite/avatar-a.b.19700101T000000Z.png',
      );
      expect(avatarPortraitUrl('a'), contains('/v2/sprite-profile/avatar-a.png'));
    });
  });

  group('frames', () {
    test('standing faces the way the wire says', () {
      // `idle-s`:[0] `idle-w`:[9] `idle-n`:[18] `idle-e`:[23].
      expect(avatarFrame(facing: Facing.of('Down')), 0);
      expect(avatarFrame(facing: Facing.of('Left')), 9);
      expect(avatarFrame(facing: Facing.of('Up')), 18);
      expect(avatarFrame(facing: Facing.of('Right')), 23);
    });

    test('an unknown or missing direction faces south, as the client does', () {
      expect(Facing.of(null), Facing.south);
      expect(Facing.of('Sideways'), Facing.south);
      expect(avatarFrame(facing: Facing.of(null)), 0);
    });

    test('sitting, walking and dancing have their own frames', () {
      expect(avatarFrame(facing: Facing.south, pose: Pose.sitting), 5);
      expect(avatarFrame(facing: Facing.north, pose: Pose.sitting), 21);
      // walk-s is 32–35, and the tick wraps inside that run rather than past it.
      expect(avatarFrame(facing: Facing.south, pose: Pose.walking, tick: 0), 32);
      expect(avatarFrame(facing: Facing.south, pose: Pose.walking, tick: 5), 33);
      expect(avatarFrame(facing: Facing.east, pose: Pose.walking, tick: 3), 59);
      expect(avatarFrame(facing: Facing.south, pose: Pose.dancing, tick: 2), 14);
    });

    test('a sheet is 72 frames of 32×64, hung a tile above the body', () {
      expect(avatarFrameWidth, 32);
      expect(avatarFrameHeight, 64);
      // `defaultAvatarOffsetY = -32`: the feet go on the tile, not the head.
      expect(avatarOffsetY, -32);
    });
  });

  group('animations', () {
    test('the walk cycle runs at seven frames a second and loops', () {
      // `{loop:true,frameRate:7,sequence:[32,35],useSequenceAsRange:true}`. Seven is
      // also how many tiles a second Gather walks at, so a body advances exactly one
      // frame per tile it crosses.
      final walk = avatarAnimation(facing: Facing.south, pose: Pose.walking);
      expect(walk.frames, [32, 33, 34, 35]);
      expect(walk.fps, 7);
      expect(walk.loop, isTrue);

      expect(walk.frameAt(Duration.zero), 32);
      expect(walk.frameAt(const Duration(milliseconds: 143)), 33);
      expect(walk.frameAt(const Duration(milliseconds: 500)), 35);
      // Round the loop and back to the start rather than off the end of the sheet.
      expect(walk.frameAt(const Duration(milliseconds: 572)), 32);
    });

    test('a still pose ignores the clock', () {
      // The client declares these as single-frame animations at 60fps, which is a
      // roundabout way of saying they do not move.
      final idle = avatarAnimation(facing: Facing.east, pose: Pose.standing);
      expect(idle.frames, [23]);
      expect(idle.frameAt(const Duration(hours: 3)), 23);
      expect(avatarAnimation(facing: Facing.west, pose: Pose.sitting).frames, [14]);
    });

    test('talking is the idle frame with the mouth opening on it', () {
      // `talking-idle-s-1` is [1,0,0,1,0,0,1,0,0,0,1,0,1,0], and all eight of the
      // client's first-variant talking loops are that same mask over the pose's own
      // idle frame. Four frames a second, not seven.
      final talking = avatarAnimation(facing: Facing.south, pose: Pose.talking);
      expect(talking.fps, 4);
      expect(talking.frames, [1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0]);
      // Sitting is the same mask over frame 5, which is `idle-sit-s`.
      expect(
        avatarAnimation(facing: Facing.south, pose: Pose.talkingSitting).frames,
        [6, 5, 5, 6, 5, 5, 6, 5, 5, 5, 6, 5, 6, 5],
      );
      // North talks with frames 18 and 19, west with 9 and 10, east with 23 and 24.
      expect(avatarAnimation(facing: Facing.north, pose: Pose.talking).frames.first, 19);
      expect(avatarAnimation(facing: Facing.west, pose: Pose.talking).frames.first, 10);
      expect(avatarAnimation(facing: Facing.east, pose: Pose.talking).frames.first, 24);
    });

    test('the longest run of shut mouths is three, which is what the map relies on', () {
      // The map samples the talking loop when it repaints rather than when the
      // animation says to, so what matters is that no long stretch of it is
      // indistinguishable from standing still.
      final mask = avatarAnimation(facing: Facing.south, pose: Pose.talking).frames;
      var run = 0;
      var longest = 0;
      for (final frame in [...mask, ...mask]) {
        run = frame == 0 ? run + 1 : 0;
        longest = run > longest ? run : longest;
      }
      expect(longest, 3);
    });
  });
}
