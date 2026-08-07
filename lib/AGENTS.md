<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-05 | Updated: 2026-08-05 -->

# lib

## Purpose

The Flutter app, **Gather Companion** — the phone half. It pairs with a bridge on
your computer *once*, is handed your Gather session, and from then on holds its
own authenticated socket to Gather's game server (`packages/gather_client`). It
shows who is following you right now, and what has happened.

The computer is not in the loop after pairing: presence works on cellular with the
Mac shut. The bridge is needed only to push while this app is not running, which
is the one thing a suspended app cannot do for itself.

Nothing here is platform-specific. The one mobile-only dependency is the QR
scanner, and typing the code is already a first-class alternative rather than a
fallback.

## Key Files

| File | Description |
|------|-------------|
| `main.dart` | `GatherCompanionApp` — owns the single `AppState`, sets the dark-only status bar style, reconnects on `AppLifecycleState.resumed`, and switches between three phases (booting / pairing / feed) through an `AnimatedSwitcher`. |

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| `src/` | State, transport, pairing, settings, notifications, feed classification (see `src/AGENTS.md`) |
| `ui/` | The three screens (see `ui/AGENTS.md`) |
| `theme/` | Design tokens and `ThemeData` (see `theme/AGENTS.md`) |

## For AI Agents

### Working In This Directory

- **One `AppState`, one `ListenableBuilder`.** The whole app rebuilds from a
  single notifier, which is why the feed classification in `AppState` is cached
  and invalidated explicitly. Anything expensive that runs per build will run on
  every socket frame.
- **The phase key must stay a phase, not an identity.** `AnimatedSwitcher` is
  keyed by `_Phase`; keying it by anything that changes per notification would
  restart the transition on every frame and make the screen strobe.
- The booting phase deliberately renders an empty `ColoredBox` in
  `GatherTokens.dark.background`, matching the launch storyboard. Booting is a
  preferences read — a spinner inside that window is pure flicker.
- **Naming:** the app calls itself "Gather Companion" everywhere there is room —
  in-app header, `MaterialApp.title`, permission copy — because "Gather" alone
  would read as Gather's own client. The one exception is the home-screen label
  (`CFBundleDisplayName`), which the launcher clips at ~10 characters, so the
  tile says "Gather".
- Keep it platform-neutral. Guard anything mobile-only rather than assuming a
  camera exists; `flutter create --platforms=android,windows,linux .` at the
  repository root is the intended path to more targets.

### Testing Requirements

```sh
flutter analyze && flutter test
```

Widget tests use `AppState`'s `@visibleForTesting` seams (`debugApplySnapshot`,
`debugApplyEvent`, `debugApplyLink`) rather than a fake bridge. See
`../test/AGENTS.md`.

While working on the feed, skip the scanner (a simulator has no camera):

```sh
flutter run -d <device> --dart-define=GATHER_PAIR=127.0.0.1:7799:<token>
```

### Common Patterns

- Sealed classes with exhaustive `switch` expressions and pattern destructuring
  (`case FollowEvent(targetIsSelf: true, :final followerId)`).
- `ChangeNotifier` + `ListenableBuilder`. No state-management package.
- Private widgets (`_TopBar`, `_Avatar`) in the same file as the screen that uses
  them; only screens and entry points are public.
- Doc comments explain the *user-visible* reason for a decision, often naming the
  bug that motivated it.

## Dependencies

### Internal

- `packages/gather_events` — the wire models, via a path dependency.
- The bridge's HTTP/WS API at `bridge/lib/server.js`.

### External

`flutter_local_notifications`, `mobile_scanner` (7.x, SPM), `shared_preferences`,
`web_socket_channel`, `cupertino_icons`.

<!-- MANUAL: -->
