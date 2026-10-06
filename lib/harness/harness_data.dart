/// The fake cast the simulator harness puts in a call.
///
/// The one invariant that makes the call screen light up: a person's media id
/// ([CallPerson.accountId]) is what a [CallParticipant.srcId] carries, and the
/// same string is the roster row's `userAccountId`. That is the bridge
/// `AppState.rowForSrcId` walks to put a name and a speaking ring on a tile —
/// see `lib/ui/call_screen.dart` `_tiles`. Get it wrong and every tile is
/// "Someone", mute and silent.
///
/// Everybody here, me included, shares one [kHuddleCluster]. The speaking-ring
/// notify in `AppState._noteSpeakers` only fires for rows whose `clusterId`
/// matches mine, and the big-view auto mode only follows people in my cluster,
/// so a split cluster would leave the scenario driver talking to nobody.
library;

import 'package:gather_client/gather_client.dart';

import '../src/media/call.dart';

/// One made-up colleague.
class CallPerson {
  const CallPerson({
    required this.spaceId,
    required this.accountId,
    required this.name,
  });

  /// `SpaceUser.id` — the roster identity, and the tile's key.
  final String spaceId;

  /// `UserAccount.id` — the media identity. Doubles as the roster row's
  /// `userAccountId` so the two planes agree on who this is.
  final String accountId;

  final String name;
}

/// My own roster id. The call is drawn from my point of view.
const String kSelfId = 'me';

/// The conversation everybody in the harness call is standing in.
const String kHuddleCluster = 'huddle';

/// The bench. The driver seats the first N of them, so order is the cast list.
const List<CallPerson> kCast = [
  CallPerson(spaceId: 'space-ada', accountId: 'acc-ada', name: 'Ada'),
  CallPerson(spaceId: 'space-grace', accountId: 'acc-grace', name: 'Grace'),
  CallPerson(spaceId: 'space-kat', accountId: 'acc-kat', name: 'Katherine'),
  CallPerson(spaceId: 'space-mira', accountId: 'acc-mira', name: 'Mira'),
  CallPerson(spaceId: 'space-dot', accountId: 'acc-dot', name: 'Dorothy'),
  CallPerson(spaceId: 'space-alan', accountId: 'acc-alan', name: 'Alan'),
  CallPerson(spaceId: 'space-edsger', accountId: 'acc-edsger', name: 'Edsger'),
  CallPerson(spaceId: 'space-linus', accountId: 'acc-linus', name: 'Linus'),
];

/// The most people the cast can seat.
int get castSize => kCast.length;

/// The first [count] of the cast, clamped to what exists.
List<CallPerson> seated(int count) =>
    kCast.take(count.clamp(0, kCast.length)).toList();

/// The media-plane view of the call: who the SFU is sending us.
///
/// Audio on, video off — the harness draws avatars, not textures, so no stream
/// is ever attached (the call screen only reaches for one behind a `LiveCall`).
List<CallParticipant> participantsFor(int count) => [
      for (final p in seated(count))
        CallParticipant(srcId: p.accountId, hasAudio: true),
    ];

/// The game-plane view: the roster Gather would have sent, with the given
/// account ids marked as speaking.
///
/// Includes me, in the same cluster, so `myCluster` and the speaking notify both
/// see the group. [speakingAccountIds] is keyed by `accountId` to match what the
/// scenario driver reasons about.
Roster rosterFor(int count, {Set<String> speakingAccountIds = const {}}) {
  return Roster(
    selfId: kSelfId,
    rows: [
      const RosterRow(id: kSelfId, name: 'You', clusterId: kHuddleCluster),
      for (final p in seated(count))
        RosterRow(
          id: p.spaceId,
          name: p.name,
          clusterId: kHuddleCluster,
          userAccountId: p.accountId,
          speaking: speakingAccountIds.contains(p.accountId),
        ),
    ],
  );
}
