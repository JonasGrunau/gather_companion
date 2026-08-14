/// The call surface, without a camera anywhere near it.
///
/// Every test here swaps [CallScreen.buildTile] for an inert stand-in.
/// `RTCVideoRenderer.initialize()` needs a `MethodChannel` that does not exist
/// under `flutter test`, so the real tile cannot be built — but everything worth
/// asserting about this screen is layout, naming and the empty states, none of
/// which is pixels.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/media/call.dart';
import 'package:gather_companion/src/media/media_engine.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/call_screen.dart';

void main() {
  /// A tile that draws its label and nothing else.
  Widget inertTile(BuildContext context, CallTile tile) => TileFrame(tile: tile);

  Future<void> show(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildGatherTheme(),
      home: CallScreen(state: state, buildTile: inertTile),
    ));
    await tester.pump();
  }

  AppState stateWith(CallState call, {List<RosterRow> rows = const []}) {
    final state = AppState()..debugCall = call;
    if (rows.isNotEmpty) {
      state.debugApplyRoster(Roster(selfId: 'me', rows: rows));
    }
    return state;
  }

  testWidgets('an empty call says so rather than showing a blank screen',
      (tester) async {
    await show(tester, stateWith(const CallState()));

    expect(find.textContaining('Nobody is in this conversation yet'), findsOneWidget);
    expect(find.text('Nobody else here'), findsOneWidget);
  });

  testWidgets('somebody the roster knows gets their name on the tile',
      (tester) async {
    await show(
      tester,
      stateWith(
        const CallState(participants: [
          CallParticipant(srcId: 'account-1', hasAudio: true),
        ]),
        rows: const [
          RosterRow(id: 'space-1', name: 'Mira', userAccountId: 'account-1'),
        ],
      ),
    );

    expect(find.text('Mira'), findsOneWidget);
    expect(find.text('1 other person'), findsOneWidget);
  });

  testWidgets('somebody the roster cannot place is still in the call',
      (tester) async {
    // The two planes are keyed differently and a row can arrive without its
    // `userAccountId`. Dropping the tile would be the wrong repair: we can hear
    // them, so they are demonstrably there.
    await show(
      tester,
      stateWith(const CallState(participants: [
        CallParticipant(srcId: 'account-unknown', hasAudio: true),
      ])),
    );

    expect(find.text('Someone'), findsOneWidget);
    expect(find.text('1 other person'), findsOneWidget);
  });

  testWidgets('a muted person is present, not absent', (tester) async {
    await show(
      tester,
      stateWith(
        const CallState(participants: [
          CallParticipant(srcId: 'account-1', hasAudio: true, audioPaused: true),
        ]),
        rows: const [
          RosterRow(id: 'space-1', name: 'Mira', userAccountId: 'account-1'),
        ],
      ),
    );

    expect(find.text('Mira'), findsOneWidget);
    expect(find.byIcon(Icons.mic_off), findsOneWidget);
  });

  testWidgets('the self tile appears only once the hardware is open',
      (tester) async {
    await show(tester, stateWith(const CallState()));
    expect(find.text('You'), findsNothing);

    await show(
      tester,
      stateWith(const CallState(media: LocalMediaState(capturing: true))),
    );
    expect(find.text('You'), findsOneWidget);
    // Still nobody else — the header counts the room, not the tiles.
    expect(find.text('Nobody else here'), findsOneWidget);
  });

  testWidgets('more than two people go to a grid', (tester) async {
    await show(
      tester,
      stateWith(const CallState(participants: [
        CallParticipant(srcId: 'a', hasAudio: true),
        CallParticipant(srcId: 'b', hasAudio: true),
        CallParticipant(srcId: 'c', hasAudio: true),
      ])),
    );

    expect(find.byType(GridView), findsOneWidget);
    expect(find.text('3 other people'), findsOneWidget);
  });

  test('a screen share is what the tile shows, when there is one', () {
    final state = AppState()
      ..debugCall = const CallState(participants: [
        CallParticipant(
          srcId: 'account-1',
          hasVideo: true,
          sharingScreen: true,
        ),
      ]);

    final tile = tilesFor(state).single;
    expect(tile.sharingScreen, isTrue);
    // No live call behind this state, so there is no stream to pick — the point
    // is that the tile carries the flag the layout reads.
    expect(tile.stream, isNull);
  });
}
