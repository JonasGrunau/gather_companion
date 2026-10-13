/// The call target's way out.
///
/// `main_harness.dart`'s `_buildCall` seats you in a huddle (every `rosterFor`
/// row shares [kHuddleCluster]) and renders [CallScreen], whose control bar now
/// carries the real Leave door over a pop-able office beneath. The door runs the
/// production `leaveHuddle()`, so the call-target state needs a collector behind
/// it — otherwise the leave resolves to "Not connected to Gather." and the one
/// documented harness exit reports itself as a failure.
///
/// These pin that: with the collector the harness attaches, the door is there to
/// leave with (so the roster really did seat us in a huddle), it leaves cleanly
/// and pops; without it, the same tap pops a snackbar — so the attach in
/// `_buildCall` cannot be dropped without a red test.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/harness/fake_collector.dart';
import 'package:gather_companion/harness/harness_data.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/media/call.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/call_screen.dart';

void main() {
  // A tile with no WebRTC behind it — `RTCVideoRenderer.initialize()` has no
  // method channel under `flutter test`, so the real tile cannot build.
  Widget inertTile(BuildContext context, CallTile tile) => TileFrame(tile: tile);

  // The call-target state shape: seated in a huddle, a call to render, and
  // (optionally) the collector `_buildCall` attaches.
  AppState callTargetState({required bool withCollector}) {
    final state = AppState()..debugCall = const CallState(publishingAudio: true);
    // ignore: invalid_use_of_visible_for_testing_member
    state.debugApplyRoster(rosterFor(3));
    if (withCollector) {
      // ignore: invalid_use_of_visible_for_testing_member
      state.debugAttachCollector(FakeCollector(participants: 3));
    }
    return state;
  }

  // Mirrors the harness: the call pushed over an office beneath, so Leave has
  // somewhere to pop to. Returns with the call on screen and the cluster-forming
  // debounce the roster apply arms already flushed, so no timer outlives the test.
  Future<void> showOverOffice(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildGatherTheme(),
      home: Builder(
        builder: (context) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => CallScreen(state: state, buildTile: inertTile),
            ));
          });
          return const Scaffold(body: Center(child: Text('Office (sim)')));
        },
      ),
    ));
    // Past the forming debounce (1500ms) so the cluster-media timer has fired and
    // is not left pending; it hands its set to a null real call and does nothing.
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  }

  testWidgets('with the collector attached, the Leave door leaves cleanly', (tester) async {
    final state = callTargetState(withCollector: true);
    addTearDown(state.dispose);
    await showOverOffice(tester, state);
    expect(find.byType(CallScreen), findsOneWidget);
    // The roster seated us in a huddle, so the door is a Leave the door exists to be.
    expect(find.byIcon(Icons.logout_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.logout_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Not connected to Gather.'), findsNothing);
    expect(find.byType(CallScreen), findsNothing, reason: 'the door should pop back to the office');
    expect(find.text('Office (sim)'), findsOneWidget);
  });

  testWidgets('without a collector the same door errors — proving the attach is what prevents it', (tester) async {
    final state = callTargetState(withCollector: false);
    addTearDown(state.dispose);
    await showOverOffice(tester, state);

    await tester.tap(find.byIcon(Icons.logout_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Not connected to Gather.'), findsOneWidget);
  });
}
