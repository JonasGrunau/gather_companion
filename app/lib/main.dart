import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/app_state.dart';
import 'theme/gather_theme.dart';
import 'ui/feed_screen.dart';
import 'ui/pair_screen.dart';

void main() {
  runApp(const GatherCompanionApp());
}

class GatherCompanionApp extends StatefulWidget {
  const GatherCompanionApp({super.key});

  @override
  State<GatherCompanionApp> createState() => _GatherCompanionAppState();
}

class _GatherCompanionAppState extends State<GatherCompanionApp> with WidgetsBindingObserver {
  final _state = AppState();

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
    // iOS tears the socket down while the app is suspended. Coming back to the
    // foreground has to reconnect, which also replays everything missed.
    if (lifecycle == AppLifecycleState.resumed) _state.reconnect();
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
          if (!_state.isLoaded) {
            return Scaffold(
              backgroundColor: GatherTokens.dark.background,
              body: Center(
                child: CircularProgressIndicator(color: GatherTokens.dark.brand),
              ),
            );
          }
          if (!_state.isConfigured) return PairScreen(state: _state);
          return FeedScreen(state: _state, onUnpair: _state.unpair);
        },
      ),
    );
  }
}
