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
| `app_state.dart` | `AppState extends ChangeNotifier` — the one object the UI reads. Drives the **Gather** connection (`DirectCollector` + `PresenceTracker` + `PartyMode` from `package:gather_client`), and owns the presence snapshot, the link status, and the lifecycle (`boot`, `pair`, `unpair`, `reconnect`, `_attach`/`_detach`). Events are not stored: `_onFold` hands each one to `Notifier` and drops it. No socket to the computer: the bridge is reached only by an opportunistic `POST /push/register`. Carries a second `Listenable`, **`positions`**, which ticks on every roster: movement is not a presence event, so `notifyListeners` never fires for it, and the map would otherwise freeze — while waking the whole tree at 4Hz would rebuild the feed on a stranger's footstep. |
| `map_person.dart` | `MapPerson` — somebody to draw on the map. Separate from `PlayerRef` on purpose: that model has no coordinates, because proximity is exactly the thing this app refuses to treat as meaning something. |
| `link_status.dart` | `LinkState` / `LinkStatus` — how good our connection to **Gather** is. Carries `needsPairing`, the one state that asks the user to act rather than wait. |
| `credentials.dart` | `GatherCredentialStore` — the Gather refresh token, in the platform keychain. Not `SharedPreferences`: this is the user's whole Gather identity and backups include plists. |
| `pairing.dart` | `PairPayload` parsing (`HOST:PORT:CODE`), `normaliseCode()`, `parseAddress()`, and `claimPairing()` — the one unauthenticated call in the API. |
| `settings.dart` | `BridgeSettings` — host, port, token in `SharedPreferences`, plus `wsUri()` / `httpUri()` construction and the bridge's friendly name. |
| `notifications.dart` | `Notifier` — local notifications for the two events worth interrupting someone for, with permission requested *after* pairing rather than at launch. |
| `media/media_engine.dart` | `MediaEngine`, `LocalMediaState`, `MediaFailure` — the seam between call logic and hardware. **Imports no `flutter_webrtc`**, which is what lets the call logic be tested on a machine with no camera. Talks in state and track ids, never native objects. |
| `media/webrtc_media_engine.dart` | `WebrtcMediaEngine` — the only file in the app that imports `flutter_webrtc`. `getUserMedia`, camera switching, teardown. Exposes `localStream` concretely for the renderer, deliberately off the interface. Mute goes to the **audio device** (`Helper.setMicrophoneMuted` in `voiceProcessing` mode), not to `track.enabled`: disabling the track stops the frames while the capture session runs on, leaving iOS's orange microphone indicator lit for the whole mute. The file's header explains the trade in full, including the platform mute tone it accepts to get muted-talker detection. |
| `media/mediasoup_ice.dart` | Three lines that re-export `RTCIceServer` / `RTCIceTransportPolicy` / `RTCIceCredentialType` from `mediasfu_mediasoup_client`'s unexported `src/handlers/`. The **only** `implementation_imports` ignore in the app, deliberately kept to one file: those types are the declared parameters of every API that accepts TURN servers, so the real choice is this or no TURN. Read the header before touching it. |
| `media/sfu_session.dart` | `SfuSession` — the media plane's client half: router `get-addr` → node connect → `get-rtp-capabilities` → `Device.load()` → send transport → `produce`. Owns the mediasoup `Device`; `sfu_signalling.dart` in `gather_client` owns the socket beneath it. **Not exercised against the live SFU yet**, and it carries one uncaptured assumption — the `transport-create` *response* shape — named in the file. |

## For AI Agents

### Working In This Directory

- **Events are not kept anywhere.** There was an on-phone `EventLogStore` and a
  `relevance.dart` classifier behind a scrolling activity feed. Both are gone. Once
  the app held its own Gather socket the log could only record what happened while
  the app was open — the one window in which the user was already looking — so it
  was empty exactly when it would have been useful. What it was for is push
  notifications, which do not need it: `_onFold` calls `Notifier.consider` and lets
  the event go. Do not reintroduce a store without solving the closed-app case
  first.
- **`_detach()` must stay synchronous.** It was once `async` with `_client = null`
  after an `await`, so the null landed a microtask after `_attach()` had installed
  the replacement and quietly wiped it. Disposal can finish in the background; the
  bookkeeping cannot.
- **`whenLive()` plus a 450 ms floor** is what makes pull-to-refresh feel like an
  action. A local bridge answers in ~50 ms and an indicator that vanishes inside
  two frames reads as a rendering fault. The floor is outside the null check on
  purpose, so the gesture feels the same with or without a socket.
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
flutter test                            # everything
```

Adding an event type means adding a case to the switch in `notifications.dart`,
which decides its title and body — that is now the only place an event is phrased,
and the only place one is judged worth interrupting someone for.

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
layer stays free of widgets entirely.

### External

`shared_preferences`, `web_socket_channel` (`IOWebSocketChannel`),
`flutter_local_notifications`, `dart:io` (`HttpClient`).

<!-- MANUAL: -->
