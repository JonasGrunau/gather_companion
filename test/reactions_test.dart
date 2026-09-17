/// [Reactions] — everything currently in the air.
///
/// The expiry is this app's invention rather than the protocol's: `EmoteEvent`
/// says a reaction started and nothing ever says it ended, so if this forgets to
/// forget, an emoji stays over somebody's face for the rest of the call.
///
/// Driven through `tester.pump` rather than through an injected clock, because
/// the timer *is* the expiry — there is deliberately no second opinion about the
/// time for a test to hold a stopwatch against. See the note in `reactions.dart`
/// about the version that had one.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/reactions.dart';

void main() {
  const linger = Duration(seconds: 3);

  late Reactions reactions;
  late int changes;

  setUp(() {
    changes = 0;
    reactions = Reactions(linger: linger)..addListener(() => changes++);
  });

  tearDown(() => reactions.dispose());

  List<String> emotes(String who) =>
      [for (final flight in reactions.forPerson(who)) flight.emote];

  testWidgets('a reaction is shown to whoever sent it, and to nobody else',
      (tester) async {
    reactions.note('luca', '🎉');

    expect(emotes('luca'), ['🎉']);
    expect(reactions.forPerson('jonas'), isEmpty);
    expect(changes, 1);

    // The framework fails a test that ends with a timer still pending, and it
    // checks before `tearDown` runs. Which is a fair thing to insist on: a
    // reaction that outlives what created it is exactly the bug here.
    reactions.clear();
  });

  testWidgets('an unknown person, and nobody at all, are both not reacting',
      (tester) async {
    expect(reactions.forPerson(null), isEmpty);
    expect(reactions.forPerson('nobody'), isEmpty);
    expect(reactions.isEmpty, isTrue);
  });

  testWidgets('it takes itself down once it has been up for its full time',
      (tester) async {
    reactions.note('luca', '🎉');

    await tester.pump(linger - const Duration(milliseconds: 1));
    expect(emotes('luca'), ['🎉']);

    await tester.pump(const Duration(milliseconds: 1));
    expect(reactions.isEmpty, isTrue);
    expect(changes, 2, reason: 'the press and the expiry, and nothing between');
  });

  testWidgets('every press is its own emoji, and they overlap', (tester) async {
    // The thing the first version got wrong. Three taps mean three of them in
    // the air at once, not one that keeps restarting — that is the difference
    // between applause and a stuttering timer.
    reactions.note('luca', '👏');
    await tester.pump(const Duration(milliseconds: 400));
    reactions.note('luca', '👏');
    await tester.pump(const Duration(milliseconds: 400));
    reactions.note('luca', '👏');

    expect(emotes('luca'), ['👏', '👏', '👏']);
    expect(reactions.forPerson('luca').map((f) => f.id).toSet(), hasLength(3),
        reason: 'each one needs its own identity to animate separately');

    await tester.pump(linger);
  });

  testWidgets('each one expires on its own clock, oldest first', (tester) async {
    reactions.note('luca', '👋');
    await tester.pump(const Duration(seconds: 1));
    reactions.note('luca', '🔥');

    // A later press must not extend the earlier one's life, and must not be cut
    // short by it.
    await tester.pump(const Duration(seconds: 2, milliseconds: 1));
    expect(emotes('luca'), ['🔥']);

    await tester.pump(const Duration(seconds: 1));
    expect(reactions.isEmpty, isTrue);
  });

  testWidgets('a held button stays bounded, dropping the oldest', (tester) async {
    final capped = Reactions(linger: linger, maxInFlight: 3);

    for (final emote in ['1', '2', '3', '4', '5']) {
      capped.note('luca', emote);
    }

    // The ones already furthest through their climb go, so the stream stays live
    // rather than refusing new presses — and the face stays visible behind it.
    expect([for (final f in capped.forPerson('luca')) f.emote], ['3', '4', '5']);

    // And the two that were dropped took their timers with them, rather than
    // leaving two shots still queued to fire at a list they are no longer in.
    capped.clear();
  });

  testWidgets('several people react at once and expire independently',
      (tester) async {
    reactions.note('luca', '👋');
    await tester.pump(const Duration(milliseconds: 1500));
    reactions.note('jonas', '💯');

    await tester.pump(const Duration(milliseconds: 1500));
    expect(reactions.forPerson('luca'), isEmpty);
    expect(emotes('jonas'), ['💯']);

    // The cap is per person, not per room: one enthusiastic colleague must not
    // push everybody else's off the screen.
    await tester.pump(const Duration(milliseconds: 1500));
    expect(reactions.isEmpty, isTrue);
  });

  testWidgets('an empty id or an empty emoji is not a reaction', (tester) async {
    reactions
      ..note('', '🎉')
      ..note('luca', '');

    expect(reactions.isEmpty, isTrue);
    expect(changes, 0, reason: 'nothing changed, so nothing should be redrawn');
  });

  testWidgets('clearing forgets the room', (tester) async {
    reactions
      ..note('luca', '👋')
      ..note('jonas', '💯');
    changes = 0;

    reactions.clear();

    expect(reactions.isEmpty, isTrue);
    expect(changes, 1);

    // And says nothing the second time, so unpairing twice is not two rebuilds.
    reactions.clear();
    expect(changes, 1);

    // The timers went with it. One still running would fire into a notifier
    // whose listeners have moved on, or — after a dispose — into a disposed one.
    await tester.pump(linger);
    expect(changes, 1);
  });

  group('off the event bus', () {
    /// An `EmoteEvent` as `DeltaState.events[]` carries it.
    ///
    /// The sender is `senderUserId` and not `senderId` — the field name is not
    /// stable across event types on this protocol, and `game_protocol.dart`
    /// normalises three spellings for exactly this reason. Spelling it the
    /// event's own way here is what makes this a test of the path rather than of
    /// the fixture.
    BusEvent emote(String from, String what, {List<String>? to}) => BusEvent(
          name: 'EmoteEvent',
          senderId: from,
          sentTime: null,
          targetUserIds: to ?? [from, 'me'],
          payload: {'eventName': 'EmoteEvent', 'senderUserId': from, 'emote': what, 'count': 1},
        );

    AppState wired() {
      final state = AppState();
      addTearDown(state.dispose);
      return state;
    }

    testWidgets('somebody else reacting shows over their tile', (tester) async {
      final state = wired()..debugNoteEvent(emote('luca', '🎉'));

      expect(state.reactions.forPerson('luca').single.emote, '🎉');

      await tester.pump(reactionLinger);
      expect(state.reactions.isEmpty, isTrue);
    });

    testWidgets('our own comes back to us and is shown too', (tester) async {
      // `broadcastEmote` addresses the event to everyone in range **and to the
      // sender**, so seeing our own needs no special case. This is what the
      // optimistic draw in `sendEmoteLocalFirst` is joined by.
      final state = wired()..debugNoteEvent(emote('me', '👏'));

      expect(state.reactions.forPerson('me').single.emote, '👏');

      await tester.pump(reactionLinger);
    });

    testWidgets('an event with no emoji in it draws nothing', (tester) async {
      final state = wired()
        ..debugNoteEvent(BusEvent(
          name: 'EmoteEvent',
          senderId: 'luca',
          sentTime: null,
          targetUserIds: const ['me'],
          payload: const {'eventName': 'EmoteEvent', 'senderUserId': 'luca'},
        ));

      expect(state.reactions.isEmpty, isTrue);
    });

    testWidgets('a wave is not a reaction', (tester) async {
      // The bus carries everything. Waves have their own home on the activity
      // tab, and drawing one over a face would be a second, quieter notification
      // nobody asked for.
      final state = wired()
        ..debugNoteEvent(const BusEvent(
          name: 'WaveEvent',
          senderId: 'luca',
          sentTime: null,
          targetUserIds: ['me'],
          payload: {'eventName': 'WaveEvent', 'senderId': 'luca'},
        ));

      expect(state.reactions.isEmpty, isTrue);
    });
  });
}
