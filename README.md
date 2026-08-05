# Gather Companion

Know when someone walks up to you — or starts following you — in your live
Gather V2 session, on your phone.

Not affiliated with Gather. This is a third-party companion that reads the
Gather V2 desktop client running on your own computer.

Two pieces:

| | what it is | where it runs |
|---|---|---|
| `bridge/` | `npx gather-app-bridge` — a background daemon that watches the Gather desktop client and serves events over your LAN | your computer |
| `app/` | **Gather Companion** — a Flutter app showing a live event log and who is around you | your phone |

```
 Gather desktop ──▶ log file      ──▶┐
 (running on                         ├─▶ gather-app-bridge ──WS──▶ phone app
  your computer) ──▶ devtools (CDP) ──▶┘        :7799
```

---

## Quick start

On the computer that has Gather open:

```sh
npx gather-app-bridge
```

That installs it as a background service — starts at login, restarts if it dies,
survives sleep. Then pair your phone:

```sh
npx gather-app-bridge pair
```

It draws a QR square in the terminal. Scan it in the app and you are done; the
code and address are printed underneath for a phone whose camera is refused.

Then check what it can see:

```sh
npx gather-app-bridge doctor
```

---

## The two fidelity levels

This is the one thing worth understanding, because it decides whether
"*someone is following me*" works.

### Log-only mode — works immediately, no setup

The desktop client forwards its renderer's console output into
`~/Library/Logs/GatherV2/main.log`, and the Electron main process traces every
IPC message it receives. The bridge tails that file. No flags, no injection, no
configuration.

You get:

- **who came near you** — Gather only opens audio/video with people close enough
  to hear you, so remote-participant join/leave is a faithful proximity signal.
  In a sample session 29 people joined the space but only 13 ever got a media
  connection: those 13 are the ones who actually walked up. Reported as
  `confidence: "inferred"`.
- who joined and left the space
- who muted, unmuted, or started sharing their screen
- your own mic/camera/screenshare state
- the *type* of every notification Gather raised

You do **not** get: display names (only uuids), coordinates, or reliable
follow detection. Following lives in the web app's state and never reaches the
log — the only follow-related line the client writes is its own pathfinding when
*you* follow someone else.

### Full mode — one extra flag on the Gather client

Quit Gather completely — it holds a single-instance lock, so launching a second
copy just focuses the first — then start it with a devtools port. On macOS:

```sh
"/Applications/GatherV2.app/Contents/MacOS/GatherV2" \
  --remote-debugging-port=9222 --remote-allow-origins='*' &
```

Sign in as usual. The bridge attaches on its own within a few seconds.

`--remote-debugging-port` is a stock Chromium switch. Electron passes it straight
through, and Gather's own `DesktopCliEnableDebugSwitches` feature gate does *not*
apply to it, because Chromium parses `argv` before any app code runs. Nothing is
patched and nothing is modified — `app.asar` is integrity-checked and could not be
patched even if we wanted to.

> **Know the tradeoff before you leave this on.** While that port is open, *any*
> local process can drive your authenticated Gather session over `127.0.0.1:9222`
> — read the space, move your avatar, send chat as you. It binds to loopback only;
> never add `--remote-allow-origins` beyond what you need and never
> `--remote-debugging-address`. If you would not trust every process on the
> machine with your Gather account, run in log-only mode instead.

Now you additionally get:

- **who is following you**, read from the field that actually means it, not
  guessed. Reported as `confidence: "observed"`.
- display names
- tile coordinates and real distances
- adjacency via Gather's own cluster model

---

## How full mode reads the protocol

The bridge does **not** poke at the app's internals. The production bundle
deliberately keeps its MobX stores off `window` (`exposeManagers: {prod: false}`),
so scraping them would be guesswork that breaks on every redeploy.

Instead it enables CDP's Network domain and reads the WebSocket frames the client
is **already exchanging** with `wss://game-router.v2.gather.town/gather-game-v2`,
decodes the msgpack, and interprets the model deltas.

Consequences worth stating: no second session is opened, no credentials are
handled, and you do not appear twice in the space. The bridge is a passive
reader of a stream that already exists.

This was captured and verified against a live authenticated session. The
handshake, in order:

```
Authenticate → ConnectToSpace → Subscribe → SpaceStatus
→ FullStateChunk ×N   (the initial dump, ~1500 patches per chunk, ~45 models)
→ DeltaState, Action  (everything after)
→ Heartbeat           (~1/s, and the bulk of the traffic)
```

State arrives as patches against model rows. They are *not* JSON-Patch — there
are exactly three ops:

```js
{ op: 'addmodel',    model: 'SpaceUser', data: {...} }              // whole row; id is inside data
{ op: 'deletemodel', model: 'SpaceUser', id: '<id>' }               // row removed
{ op: 'replace',     model: 'SpaceUser', id, path, data }           // one field
```

- **following** — a `replace` on *their* row's `/followTargetId` set to *my* id.
  There is no "follow started" server event; the official client derives it the
  same way (`SpaceUser.followers` filters by `followTargetId === this.id`).
  `followTargetId` and `clusterId` are optional columns, so they are *absent*
  rather than null when unset.
- **adjacency** — `position` compared with my own, requiring the same `floorId`.
  Position mutates component-wise, so walking arrives as `/position/x` and
  `/position/y`; a teleport replaces `/position` wholesale with an ext-0
  `Position` value object. Both shapes are handled.

Identity — which row is mine — comes from the `Connection` model, which carries
both halves:

```js
{ model: 'Connection', data: { authUserId: '<firebase uid>', spaceUserId: '<my SpaceUser id>' } }
```

The Firebase uid itself is read from Firebase's own IndexedDB store
(`firebaseLocalStorageDb`), which is SDK-standard rather than Gather-specific.
`UserAccount.firebaseAuthId` plus `SpaceUser.userAccountId` is a second route.

Bots and recording clients (`isBot`, `type: 'RecordingClient'`) are filtered out —
every real space has them and they are not people standing next to you.

### Cold start, and `resync`

The full state dump is sent **once per connection**. A bridge that attaches to a
client which has been running for days therefore sees heartbeats and nothing else
until somebody moves, and people who never move stay invisible.

The bridge is honest about this rather than showing an empty room: until it holds
real state it reports the CDP collector as *not* healthy, with
`attached but holding no state (heartbeats only)`. To fix it immediately:

```sh
npx gather-app-bridge resync
```

That reloads the Gather renderer, costing about two seconds of reconnect, and the
server resends the whole dump while the bridge is watching. It also happens by
itself on any natural reconnect — a sleep, a network blip, a Gather restart.

---

## Commands

```
npx gather-app-bridge                install as a background service and pair
npx gather-app-bridge run            run in the foreground instead
npx gather-app-bridge status         is it alive, and who is around right now
npx gather-app-bridge pair           show a QR square for the phone to scan
npx gather-app-bridge doctor         what can it see, and how to see more
npx gather-app-bridge resync         force a full state resync (reloads the renderer)
npx gather-app-bridge logs -f        follow the daemon log
npx gather-app-bridge token          show the pairing details again
npx gather-app-bridge restart|stop|start|uninstall
npx gather-app-bridge replay [file]  parse a log file and summarise it
```

Options: `--port <n>` (default 7799), `--cdp-port <n>` (default 9222),
`--token <s>`, `--log-file <path>`.

### Watching the stream from a terminal

You do not need the phone to see what the bridge is doing:

```sh
npx gather-app-bridge watch                        # attach to the live feed
npx gather-app-bridge watch --history 20           # last 20 events, then follow
npx gather-app-bridge watch --filter follow,proximity
npx gather-app-bridge watch --json | jq .          # one event per line, pipeable
npx gather-app-bridge watch --raw                  # everything, unfiltered
npx gather-app-bridge watch --host 192.168.1.20    # a bridge on another machine
```

It uses the same contract as the app — snapshot first, then live events, resuming
by sequence number after a dropped connection — so nothing is lost while it
reconnects.

**`--raw` matters, because the normal stream is not everything the bridge sees.**
Three layers sit between interception and publication:

| dropped where | what gets dropped |
|---|---|
| `PresenceTracker` | anything that is not a *state change*: repeated proximity reports, mic and camera toggles (recorded in state, never announced), all `media.connection` transport chatter |
| `GameProtocolReader` | 42 of ~45 models — calendar events, chat metadata, catalog items, map areas, GitHub PRs. Only `SpaceUser`, `Connection` and `UserAccount` are kept |
| both collectors | heartbeats, bots, recording clients |

That filtering is deliberate — a feed that announced every mic flicker would be
useless — but it means the published stream understates what is available. `--raw`
subscribes to the firehose before the tracker sees it, so a mute you would never
be notified about still shows up. Frames marked `kind: "raw"` rather than
`kind: "event"`.

For what is being decoded but *discarded entirely* (the other 42 models, frame
type counts), look at `cdpStats` in `GET /collectors`.

### Staying up

On macOS it installs as a `LaunchAgent` (`com.jonasgrunau.gather-app-bridge`) with
`RunAtLoad` and `KeepAlive`, so it starts at login and comes back if it crashes.
Two details that matter over months of uptime:

- The package is **copied into `~/.gather-app-bridge/bridge`** at install time. `npx`
  runs out of a cache npm may prune, and a global install disappears on the next
  `npm uninstall` — either would leave launchd pointing at nothing.
- It resolves a **version-independent `node`** (`/opt/homebrew/bin/node` and
  friends) rather than `process.execPath`, which under nvm/asdf points at a
  version-pinned path that vanishes on the next Node upgrade.

Across a sleep the log tailer re-stats the file (it polls rather than trusting
`fs.watch`, which stops delivering events after a suspend without erroring) and
the CDP collector reconnects with backoff.

---

## HTTP / WebSocket API

Everything except `/health` needs `?token=<token>`.

| endpoint | what |
|---|---|
| `GET /health` | liveness, no token, nothing sensitive |
| `GET /state` | current snapshot: self, players, collector health |
| `GET /events?since=<seq>` | replay recent events |
| `GET /collectors` | which collectors are live, and why not |
| `WS /ws?since=<seq>` | snapshot frame, then live events |
| `WS /ws?raw=1` | additionally the unfiltered firehose, as `kind: "raw"` frames |
| `GET /resync` | force a full state resync (reloads the renderer) |
| `GET /pair/offer` | mint a pairing code (used by `pair`) |
| `GET /pair/claim?code=` | **no token** — trade a code for the token, once |

Every event carries `type`, `at`, `source` (`log` \| `cdp` \| `bridge`) and
`confidence` (`observed` \| `inferred`). Frames are
`{kind:'snapshot'|'event', seq, ...}`; reconnecting with `?since=<lastSeq>`
replays exactly what was missed, which is what keeps the phone's log complete
across screen locks.

Event types: `proximity.entered/left`, `follow.started/stopped`,
`player.joinedSpace/leftSpace`, `audio.range`, `media.changed`,
`media.connection`, `player.moved`, `chat.message`, `self.changed`,
`space.changed`, `notification.shown`, `bridge.status`.

The Dart definitions in `packages/gather_events` are the same contract, so the
app decodes these into a sealed class hierarchy.

---

## The app — Gather Companion

The bridge is the computer half; Gather Companion is the phone half. It says so
wherever there is room to — in-app header, `MaterialApp.title`, permission copy —
because "Gather" alone would read as Gather's own client. The one exception is
the home-screen label, which the launcher clips to about ten characters:
"Gather Companion" came out as "GatherCom…", so the tile says **Gather** and the
app introduces itself properly once opened.

Nothing in `lib/` is platform-specific: it is plain Flutter over an HTTP and
WebSocket contract, so the same code targets phones and desktops. Only the iOS
runner is scaffolded so far — `flutter create --platforms=android,windows,linux .`
from `app/` adds the rest, and the icon generator needs a matching output path
per platform.

```sh
cd app && flutter run -d <device>
```

To sideload on iOS: open `app/ios/Runner.xcodeproj` in Xcode, set a signing team
on the `Runner` target, then `flutter run -d <device>`. A free Apple ID works for
personal device installs.

Build notes worth knowing:

- **iOS 15.5 minimum**, required by `mobile_scanner`. The same package needs
  Android 5.0 / API 21 and camera permission in the manifest.
- **Swift Package Manager, not CocoaPods** on the iOS side. `mobile_scanner` 7.x
  is a Swift package, and leaving the old CocoaPods integration in place breaks
  the build with a misleading *"missing expected TARGET_BUILD_DIR"*. If you ever
  re-add a pod-based plugin, expect to sort that out. Version 7 also dropped
  GoogleMLKit, which had no arm64 simulator slices — on 6.x the app simply could
  not run on an arm64 simulator at all.
- **Desktop targets have no camera scanner.** `mobile_scanner` is mobile-only, so
  a desktop build has to fall back to the type-the-code path, which already
  exists and is a first-class route rather than a fallback.

While working on the feed, `--dart-define=GATHER_PAIR=host:port:token` skips the
scanner, which a simulator or emulator has no camera for:

```sh
flutter run -d <device> --dart-define=GATHER_PAIR=127.0.0.1:7799:<token>
```

Your phone and computer have to be on the same network. Phone platforms ask for
local-network permission the first time, and for the camera the first time you
scan.

### Pairing

Modelled on Superset's flow: scan the square, or type the eight characters. The
long token is never typed or shown — the QR carries a short code which the app
trades for the token exactly once (`GET /pair/claim`). The code lives for fifteen
minutes, only after somebody ran `pair`, and a few wrong guesses destroy it.

The alphabet excludes `0`, `1`, `I`, `L` and `O`, so there is nothing to misread.
A character outside it is refused rather than guessed at — pairing on a
misread code would be worse than asking someone to look again.

### What the feed shows

Only what is worth reading. Events are classified into three tiers:

| tier | what | shown |
|---|---|---|
| **alert** | someone started following you | yes, on a Gather-blue card |
| **notable** | someone arrived next to you or moved away, screen sharing, chat, Gather's own notifications | yes |
| **ambient** | mic and camera toggles, transport state, roster churn, your own device state | behind "Show N background events" |

The top of the screen answers *now* — who is next to you, who is following you —
straight from the bridge's snapshot, so it is right even if the app was closed
when it happened. The list underneath is history.

The palette is Gather's own: `#4257DA`, read out of `app.v2.gather.town`'s
stylesheet (`--theme-color-accent`) rather than picked by eye, with the tint ramp
around it and Inter to match.

**The icon** is a proximity ping on a 32×32 pixel grid: you are the white block
in the middle, the ring is the radius the bridge watches, and the green marker on
it is somebody who just walked into range. Pixel geometry nods at the medium — a
tile-grid virtual office — while borrowing nothing from Gather's own mark; the
dark indigo tile is the app's own `background`, not Gather's blue square. It is
drawn by `app/tool/make_icons.mjs` (zero-dep: `node:zlib` plus a CRC table, same
spirit as the bridge's hand-rolled `qr.js`), which writes all fifteen asset-catalog
sizes from one source of truth:

```sh
node app/tool/make_icons.mjs --preview
```

**Notifications, honestly:** local notifications fire while the app is running —
foreground, or the short window the OS allows after backgrounding. Once the OS
suspends the app the WebSocket is gone and nothing can be delivered until you open
it again, at which point the bridge replays everything missed, so the *log* stays
complete even though the *alerts* do not. Waking a locked phone would need a push
service driven from the computer, which means a developer account and push
credentials on each platform.

---

## Tests

```sh
npm test          # bridge: parser, msgpack, protocol, end-to-end over a real WS
cd app && flutter analyze
```

The parser tests use log lines copied verbatim from a real
`~/Library/Logs/GatherV2/main.log`, and `replay` re-checks the regexes against a
whole log file after a client update:

```sh
npx gather-app-bridge replay ~/Library/Logs/GatherV2/main.log
```

---

## Scope and caveats

- **The bridge runs on macOS today.** It reads macOS log paths and installs a
  LaunchAgent. Everything above that line — the wire format, the collectors, the
  app — is platform-neutral; porting means new log/config paths and a service
  installer per platform, not a new protocol.
- **Log-only mode cannot detect being followed.** Stated in the app UI too, so a
  quiet screen is never mistaken for "nobody is following me".
- **The wire format is verified, not inferred.** Captured from a live
  authenticated session: the handshake order, the three patch ops, both envelope
  keys (`fullStatePatches`, `patches`), the `Connection` identity row and the
  `SpaceUser` field set. Replaying that capture resolves the right own-row id and
  yields the correct set of nearby people, by name. What has *not* been observed
  on the wire is a follow actually starting — `followTargetId` is an optional
  column and nobody was following during capture — so that one path rests on the
  SDK's own model definition rather than an observation.
- `GameProtocolReader.stats()` reports frame types and unrecognised-frame counts,
  so a future format change shows up as a number rather than as silence. Check it
  via `GET /collectors` (`cdpStats`).
- **Wire-format drift.** The web app redeploys constantly. The *field* names
  (`followTargetId`, `position`, `clusterId`, `floorId`) are Prisma columns and
  change rarely; the msgpack framing and patch envelope are internal and could
  change with any deploy. `bridge.status` events tell the app when a collector goes
  quiet, so drift shows up as a visibly degraded state rather than silence.
- **Cold start needs a resync in full mode.** The state dump is sent once per
  connection, so a freshly attached bridge holds nothing until the client
  reconnects. It reports itself unhealthy rather than showing an empty room, and
  `npx gather-app-bridge resync` fixes it in about two seconds. The log collector is
  unaffected, which is a reason to leave it running rather than treat it as a mere
  fallback.
- **Log-only mode depends on flags Gather controls.** The verbose renderer stream
  exists because `disable_logger_info: false` and `DesktopDetailedDiagnosticLogs`
  are set in `flags.json`, and those are server-pushed gates. If Gather turns them
  off, `replay` will show the event counts collapse.
- **Read-only.** Nothing here writes to Gather, sends actions, or modifies the
  desktop client. `app.asar` integrity validation is enabled, so patching the
  client is not possible anyway.
- Reverse-engineered from your own installed client for interoperability. There
  is no public Gather 2.0 API that exposes presence: the documented HTTP API is
  Classic-only and explicitly unsupported, and `@gathertown/gather-game-client`
  was last published in 2023 and does not speak v2.
