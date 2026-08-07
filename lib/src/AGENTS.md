<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-05 | Updated: 2026-08-05 -->

# src

## Purpose

Everything the app does that is not drawing: the single state object the UI reads,
the WebSocket client, pairing, persisted settings, local notifications, and the
rules that decide which events are worth a person's attention.

## Key Files

| File | Description |
|------|-------------|
| `app_state.dart` | `AppState extends ChangeNotifier` — the one object the UI reads. Owns the event log (1000 max, newest first), the presence snapshot, the link status, the classified-feed cache, and the client lifecycle (`boot`, `pair`, `unpair`, `reconnect`, `_attach`/`_detach`). |
| `link_status.dart` | `LinkState` / `LinkStatus` — how good our connection to **Gather** is. Carries `needsPairing`, the one state that asks the user to act rather than wait. |
| `credentials.dart` | `GatherCredentialStore` — the Gather refresh token, in the platform keychain. Not `SharedPreferences`: this is the user's whole Gather identity and backups include plists. |
| `event_log.dart` | `EventLogStore` — the feed, persisted on the phone, debounced. Replaces the bridge's 500-event replay ring. `EventLogStore.disabled()` for widget tests. |
| `relevance.dart` | `Relevance` (alert / notable / ambient), `EventLook`, and `lookOf()` — classifies *and* phrases every event in one exhaustive switch. The feed's editorial policy. |
| `pairing.dart` | `PairPayload` parsing (`HOST:PORT:CODE`), `normaliseCode()`, `parseAddress()`, and `claimPairing()` — the one unauthenticated call in the API. |
| `settings.dart` | `BridgeSettings` — host, port, token in `SharedPreferences`, plus `wsUri()` / `httpUri()` construction and the bridge's friendly name. |
| `notifications.dart` | `Notifier` — local notifications for the two events worth interrupting someone for, with permission requested *after* pairing rather than at launch. |

## For AI Agents

### Working In This Directory

- **The feed cache is a performance fix, not an optimisation.** The whole app
  hangs off one `ListenableBuilder`, so classifying 1000 events per build ran on
  every socket frame and every refresh-indicator frame. `_invalidateFeed()` must
  be called by anything that can change the outcome — including a new snapshot,
  because names are resolved during classification and a late roster relabels
  events already in the log.
- **`_detach()` must stay synchronous.** It was once `async` with `_client = null`
  after an `await`, so the null landed a microtask after `_attach()` had installed
  the replacement and quietly wiped it. Disposal can finish in the background; the
  bookkeeping cannot.
- **`lastSeq` is what keeps the log complete.** A phone drops the socket every
  time it is locked; reconnecting with `?since=` replays exactly what was missed.
  Do not reset it except in `updateSettings`.
- **`whenLive()` plus a 450 ms floor** is what makes pull-to-refresh feel like an
  action. A local bridge answers in ~50 ms and an indicator that vanishes inside
  two frames reads as a rendering fault. The floor is outside the null check on
  purpose, so the gesture feels the same with or without a socket.
- **`isPriming` exists so the feed does not lie.** It starts `true` — a state that
  never attaches has nothing to wait for — and gates the "No activity yet" card
  until the history fetch lands.
- **Pairing refuses rather than guesses.** The alphabet excludes `0`, `1`, `I`,
  `L`, `O`; characters outside it are dropped, which then fails the length check.
  There is no sound way to know whether a reported `O` meant `Q` or `D`, and
  pairing on a misread code is worse than asking someone to look again.
- The `SocketException` copy in `claimPairing` leads with the local-network
  permission prompt on purpose: the *first* connection to a private address is
  what raises that prompt, and that attempt fails while it is still open. "Check
  your Wi-Fi" would be the wrong first thing to say.
- `notifications.dart` deliberately requests no permission during `init()`. A
  permission sheet before the user has even paired is asking for a "no".

### Testing Requirements

```sh
flutter test test/relevance_test.dart   # the classification rules
flutter test                            # everything
```

`relevance.dart` is the most heavily specified file here — every tier decision is
pinned by a named test. Adding an event type means adding a case to `lookOf` (the
switch is exhaustive over the sealed hierarchy, so the analyzer will tell you)
*and* a test asserting which tier it lands in.

Use the `@visibleForTesting` seams on `AppState` — `debugApplySnapshot`,
`debugApplyEvent`, `debugApplyLink` — rather than standing up a fake bridge.

### Common Patterns

- Sealed-class pattern matching with guards (`when notifyOnFollow`) and
  destructuring in `case` clauses.
- Failures degrade rather than throw: `recentHistory()` returns `const []` on any
  error because priming is a nicety, and a failed notification must never break
  the log.
- Every non-obvious decision carries a doc comment naming the symptom it fixes.

## Dependencies

### Internal

`package:gather_events` for every model; `../theme` is *not* imported here (this
layer stays free of widgets except `IconData` in `relevance.dart`).

### External

`shared_preferences`, `web_socket_channel` (`IOWebSocketChannel`),
`flutter_local_notifications`, `dart:io` (`HttpClient`).

<!-- MANUAL: -->
