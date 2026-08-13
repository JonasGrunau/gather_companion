import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/app_state.dart';
import 'src/media/live_call.dart';
import 'theme/gather_theme.dart';
import 'ui/home_shell.dart';
import 'ui/pair_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // No generated `firebase_options.dart`: on Apple platforms the SDK reads
  // ios/Runner/GoogleService-Info.plist, which is the file the Firebase console
  // hands out and the only place the config should live. One fewer generated
  // file to drift.
  //
  // Wrapped because push is an enhancement, not a requirement. A missing or
  // malformed plist must degrade to "no push" — the feed and follow detection
  // both work without Firebase — rather than crash on launch.
  try {
    await Firebase.initializeApp();
  } catch (error) {
    debugPrint('firebase: not initialised, push disabled — $error');
  }
  runApp(const GatherCompanionApp());
}

class GatherCompanionApp extends StatefulWidget {
  const GatherCompanionApp({super.key});

  @override
  State<GatherCompanionApp> createState() => _GatherCompanionAppState();
}

class _GatherCompanionAppState extends State<GatherCompanionApp> with WidgetsBindingObserver {
  /// The one place the media layer is named.
  ///
  /// `AppState` takes it as a seam rather than importing it, so everything above
  /// the microphone stays testable on a machine that has none — see
  /// `src/media/media_engine.dart`.
  final _state = AppState(
    buildCall: (auth, spaceId, srcId) => LiveCall(
      auth: auth,
      spaceId: spaceId,
      srcId: srcId,
      log: debugPrint,
    ),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The app is dark-only, so the status bar has to be told once rather than
    // inferred from a light theme that does not exist.
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
    _state.boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _state.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    // The OS tears the socket down while the app is suspended, so coming back to
    // the foreground has to end up on a live socket — which also replays
    // everything missed.
    //
    // Asking rather than assuming, though. `resumed` fires for a pulled-down
    // notification banner and for Control Centre too, neither of which touches
    // the socket, and reconnecting unconditionally threw away a working
    // connection every time — a second of "Reconnecting" for nothing, which is
    // most of what made the link look unreliable.
    if (lifecycle == AppLifecycleState.resumed) unawaited(_state.verifyLink());
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gather Companion',
      debugShowCheckedModeBanner: false,
      theme: buildGatherTheme(),
      home: ListenableBuilder(
        listenable: _state,
        builder: (context, _) {
          final (phase, screen) = switch (_state) {
            AppState(isLoaded: false) => (
              // Deliberately empty, and deliberately the same colour as the
              // launch storyboard. Booting is a preferences read — a few frames —
              // and a spinner that appears and disappears inside that window is
              // pure flicker. Holding the launch screen's own surface makes the
              // handover invisible instead.
              _Phase.booting,
              ColoredBox(
                color: GatherTokens.dark.background,
                child: const SizedBox.expand(),
              ),
            ),
            AppState(isConfigured: false) => (_Phase.pairing, PairScreen(state: _state)),
            // The tabs start here and not before: there is nothing to navigate
            // between until there is a Gather credential to navigate with.
            _ => (_Phase.home, HomeShell(state: _state, onUnpair: _state.unpair)),
          };

          // Keyed by phase, never by state identity: a ValueKey that changed on
          // every notification would restart this transition on every socket
          // frame and make the whole screen strobe.
          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOut,
            child: KeyedSubtree(key: ValueKey(phase), child: screen),
          );
        },
      ),
    );
  }
}

enum _Phase { booting, pairing, home }
