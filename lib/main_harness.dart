/// Simulator harness entrypoint. Boots straight into a scripted scene with no
/// microphone, camera, network or Gather backend behind it, so the app can be
/// watched by eye and driven with `idb` on a bare simulator.
///
/// Two targets, chosen with `--dart-define=TARGET`:
///
///  * **`call`** (default) — straight into [CallScreen] on a scripted multi-party
///    call. [ScriptedCall] + [CallScenarioDriver] animate who is talking, for the
///    spotlight. This is the original harness, untouched.
///
///  * **`app`** — the whole app: it boots through the real pair→home flow into
///    [HomeShell] with a [FakeCollector] standing in for the Gather socket, so the
///    Office is walkable, party mode runs, and the Activity feed fills — all with
///    no network. [AppScenarioDriver] mills the cast about and lands waves.
///
/// ```
/// # the call screen (spotlight)
/// flutter run -t lib/main_harness.dart -d <sim> \
///   --dart-define=TARGET=call --dart-define=SCENARIO=roundrobin --dart-define=PARTICIPANTS=4
///
/// # the whole app
/// flutter run -t lib/main_harness.dart -d <sim> \
///   --dart-define=TARGET=app --dart-define=SCENARIO=office --dart-define=PARTICIPANTS=4
/// ```
///
/// `SCENARIO` is a [Scenario] (call) or [AppScenario] (app) name; `PARTICIPANTS`
/// is how many of the cast to seat (default 4). See `docs/sim_harness.md`.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'harness/call_scenarios.dart';
import 'harness/fake_collector.dart';
import 'harness/scripted_call.dart';
import 'src/app_state.dart';
import 'src/credentials.dart';
import 'theme/gather_theme.dart';
import 'ui/call_screen.dart';
import 'ui/home_shell.dart';
import 'ui/pair_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);

  const target = String.fromEnvironment('TARGET', defaultValue: 'call');
  const scenarioName = String.fromEnvironment('SCENARIO', defaultValue: 'group');
  const participantsRaw = int.fromEnvironment('PARTICIPANTS');
  final participants = participantsRaw == 0 ? 4 : participantsRaw;

  runApp(target == 'app' ? _buildApp(scenarioName, participants) : _buildCall(scenarioName, participants));
}

// ---- the call target --------------------------------------------------------

Widget _buildCall(String scenarioName, int participants) {
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

  return _CallHarness(state: state, driver: driver);
}

class _CallHarness extends StatefulWidget {
  const _CallHarness({required this.state, required this.driver});

  final AppState state;
  final CallScenarioDriver driver;

  @override
  State<_CallHarness> createState() => _CallHarnessState();
}

class _CallHarnessState extends State<_CallHarness> {
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

// ---- the app target ---------------------------------------------------------

Widget _buildApp(String scenarioName, int participants) {
  final fake = FakeCollector(participants: participants);
  final state = AppState(
    // The two seams that make the whole app run without a wire: a [Collector]
    // that is not a socket, and a [Call] that is not a microphone.
    buildCollector: (auth, spaceId) => fake,
    buildCall: (auth, spaceId, srcId) => ScriptedCall(),
    // A store that reports a complete credential, so `boot()` takes the pair→home
    // path into [HomeShell] rather than stopping at the pairing screen. Nothing
    // on the credential is ever used — no fetch runs — it only has to be complete.
    credentials: _HarnessCredentials(),
  );
  final driver = AppScenarioDriver(
    state: state,
    collector: fake,
    scenario: AppScenario.fromName(scenarioName),
  );
  return _AppHarness(state: state, driver: driver);
}

/// A credential store that is always "paired", with no keychain behind it.
class _HarnessCredentials extends GatherCredentialStore {
  @override
  Future<GatherCredentials> load() async => const GatherCredentials(refreshToken: 'sim-harness');

  @override
  Future<String?> loadSpaceId() async => null;
}

class _AppHarness extends StatefulWidget {
  const _AppHarness({required this.state, required this.driver});

  final AppState state;
  final AppScenarioDriver driver;

  @override
  State<_AppHarness> createState() => _AppHarnessState();
}

class _AppHarnessState extends State<_AppHarness> {
  @override
  void initState() {
    super.initState();
    // Boot the real flow, then animate once the collector is subscribed. `boot`
    // runs `_attach`, which calls `FakeCollector.start()` and wires the streams;
    // starting the driver after keeps the first scripted roster from being
    // emitted into a broadcast stream nobody is listening to yet.
    widget.state.boot().then((_) {
      if (mounted) widget.driver.start();
    });
  }

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
      home: ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          // The same phase switch as `main.dart`, so the harness exercises the
          // real booting→pairing→home handover rather than jumping past it.
          final screen = switch (widget.state) {
            AppState(isLoaded: false) => ColoredBox(
                color: GatherTokens.dark.background,
                child: const SizedBox.expand(),
              ),
            AppState(isConfigured: false) => PairScreen(state: widget.state),
            _ => HomeShell(state: widget.state, onUnpair: widget.state.unpair),
          };
          return screen;
        },
      ),
    );
  }
}
