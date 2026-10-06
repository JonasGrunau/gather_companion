/// Simulator harness entrypoint: boots straight into a scripted multi-party call.
///
/// The production app (`main.dart`) is untouched — this is a second `-t` target,
/// the gather equivalent of beacon_manager's `example/lib/main.dart`. It wires a
/// [ScriptedCall] into [AppState] through the same `@visibleForTesting` seams the
/// widget tests use, then lets [CallScenarioDriver] animate who is talking, so
/// the spotlight (and the rest of the call screen) can be watched by eye and
/// driven with `idb` on a device that has no microphone, camera or network.
///
/// ```
/// flutter run -t lib/main_harness.dart -d <sim-id> \
///   --dart-define=SCENARIO=roundrobin --dart-define=PARTICIPANTS=4
/// ```
///
/// `SCENARIO` is a [Scenario] name (default `group`); `PARTICIPANTS` is how many
/// of the cast to seat (default 4). See `docs/sim_harness.md`.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'harness/call_scenarios.dart';
import 'harness/scripted_call.dart';
import 'src/app_state.dart';
import 'theme/gather_theme.dart';
import 'ui/call_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);

  const scenarioName = String.fromEnvironment('SCENARIO', defaultValue: 'group');
  const participantsRaw = int.fromEnvironment('PARTICIPANTS');
  final participants = participantsRaw == 0 ? 4 : participantsRaw;
  final scenario = Scenario.fromName(scenarioName);

  final state = AppState();
  final call = ScriptedCall();
  // A handle so the call screen's setWatching / buttons resolve rather than
  // null-crash; the rendered state rides on this same object via `emit`. A test
  // seam, driven here on purpose: this harness target exists for it.
  // ignore: invalid_use_of_visible_for_testing_member
  state.debugAttachCall(call);

  final driver = CallScenarioDriver(
    state: state,
    call: call,
    scenario: scenario,
    participants: participants,
  )..start();

  runApp(_HarnessApp(state: state, driver: driver, label: '${scenario.name} · $participants'));
}

class _HarnessApp extends StatefulWidget {
  const _HarnessApp({
    required this.state,
    required this.driver,
    required this.label,
  });

  final AppState state;
  final CallScenarioDriver driver;
  final String label;

  @override
  State<_HarnessApp> createState() => _HarnessAppState();
}

class _HarnessAppState extends State<_HarnessApp> {
  @override
  void dispose() {
    widget.driver.stop();
    widget.state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gather Companion — Harness',
      debugShowCheckedModeBanner: false,
      theme: buildGatherTheme(),
      // Straight into the faces: no pairing, no home shell, no network boot.
      home: CallScreen(state: widget.state),
    );
  }
}
