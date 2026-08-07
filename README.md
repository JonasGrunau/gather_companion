<div align="center">

<img src="docs/icon.png" width="104" alt="Gather Companion — a proximity ping on a pixel grid">

# Gather Companion

**Know when someone walks up to you — or starts following you — in your live Gather V2 session.**

[![npm](https://img.shields.io/npm/v/gather-app-bridge?label=gather-app-bridge)](https://www.npmjs.com/package/gather-app-bridge)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![node](https://img.shields.io/badge/node-%E2%89%A5%2022-brightgreen)](package.json)
[![dependencies](https://img.shields.io/badge/dependencies-0-brightgreen)](bridge/)

*Not affiliated with Gather.* A third-party companion that connects to Gather V2
with your own session, from your own computer, and tells your phone what it sees.

</div>

---

## 🧭 How the pieces fit

| | what it is | where it runs |
|---|---|---|
| 🖥️ `bridge/` | `npx gather-app-bridge` — a zero-dependency background daemon that connects to Gather as you and serves events over your LAN | your **computer** |
| 📱 `lib/`, `ios/` | **Gather Companion** — a Flutter app showing a live event log and who is around you right now | your **phone** |

The bridge talks to Gather's own servers, as you. Everything about people comes
from there. One narrow thing does not, and cannot: Gather's *own* desktop
notifications — a wave, a meeting invite, an event reminder — are decisions its
client makes and hands to macOS, so those are still read from its log.

```
        ┌─────────────────────────┐      ┌─────────────────────────┐
        │   Gather's own servers  │      │  Gather V2 desktop app  │
        └────────────┬────────────┘      └────────────┬────────────┘
                     │ authenticated                  │
                     ▼ observer socket                ▼
          ┌─────────────────────┐          ┌─────────────────────┐
          │   game socket       │          │      main.log       │
          │  (the whole space)  │          │ (waves, invites,    │
          │                     │          │  event reminders)   │
          └──────────┬──────────┘          └──────────┬──────────┘
                     │ names, tiles, clusters,        │
                     │ real follows, voice activity   │
                     └───────────────┬────────────────┘
                                     ▼
                        ┌─────────────────────────┐
                        │    gather-app-bridge    │  ← your computer
                        │          :7799          │
                        └────────────┬────────────┘
                                     │ WebSocket over your LAN
                                     ▼
                        ┌─────────────────────────┐
                        │    Gather Companion     │  ← your phone
                        └─────────────────────────┘
```

---

## 🚀 Quick start

**1.** On the computer that has Gather open:

```sh
npx gather-app-bridge
```

That installs it as a background service — starts at login, restarts if it dies,
survives sleep.

**2.** Pair your phone:

```sh
npx gather-app-bridge pair
```

It draws a QR square in the terminal. Scan it in the app and you are done; the
code and address are printed underneath for a phone whose camera is refused.

**3.** Let it into Gather. This is not optional — without it the bridge can see
nothing:

```sh
npx gather-app-bridge adopt
npx gather-app-bridge restart
```

This reuses the Gather session your desktop app is already signed in with. No
login, no second account, nothing visible to your colleagues. See
[How it connects](#-how-it-connects).

**4.** Check what it can actually see:

```sh
npx gather-app-bridge doctor
```

---

## 🛰️ How it connects

```sh
npx gather-app-bridge adopt
npx gather-app-bridge restart
```

`adopt` copies the Gather session the desktop app is *already signed in with* —
Firebase keeps it in the renderer's IndexedDB — into the bridge's own config. There
is no login to perform and no second account to create. Refresh tokens are
long-lived, so this is a one-time read: afterwards the bridge mints its own ID
tokens and never touches the desktop client again.

It then opens its own game socket in **observer mode**. The distinction that makes
this safe is that Gather splits joining a space into two actions: `loadSpaceUser`
starts the state dump, and `enterSpace` puts an avatar in the room. The bridge
sends the first and never the second, so it receives the entire roster — names,
tile coordinates, clusters, `followTargetId`, live voice activity — while
remaining invisible to everyone in the space, with `Connection.entered: false`.

It also does **not** disturb your own session. That was the long-standing fear:
Gather's gateway was believed to evict a duplicate `spaceId` + `authUserId` with
close code 4031. Measured on 2026-08-06 against a live 111-person space, with the
desktop client joined and watched throughout: the client's socket was never closed
and never dropped a frame. The structural reason is that `Connection` is
per-connection while `SpaceUser` is per-person-per-space — both connections drive
the same avatar, so there is no second you to collide with.

And because the full state dump is sent once per *connection*, and the connection
is ours, `resync` is just a reconnect.

Protocol details, the REST surface, and what is still unverified:
[`docs/gather-api.md`](docs/gather-api.md).

**What you get:**

- 🎯 **who is following you**, read from the field that actually means it, not
  guessed from movement. Reported as `confidence: "observed"`.
- 🧩 **who is standing next to you**, via Gather's own cluster model, falling back
  to tile distance on the same floor.
- 🏷️ display names, tile coordinates, real distances
- 🔊 **who is talking** — `SpaceUser.speaking`, which on a live 111-person space
  was the most frequent update of any kind
- ✋ waves, meeting invites and event reminders, from the desktop client's log

**What nothing can give you:** ❌ mic, camera and screenshare state. Those were
IPC state inside the desktop client and appear in no Gather model, no REST route
and no delta patch. `speaking` is the honest replacement — it says who is
*talking*, which is what you wanted to know anyway.

### 📄 The one remaining scrape

Presence needs no desktop client at all. Gather's own notifications do, because
they exist nowhere else:

| | source | needs the desktop app? |
|---|---|---|
| Someone next to you, following you, talking | game socket | no |
| Names, coordinates, clusters, space name | game socket | no |
| Wave, meeting invite, event reminder | `main.log` | **yes** |
| Mic / camera / screenshare | — | not available at all |

One nicety falls out of this: Gather suppresses its own notification when its
window has focus, and the bridge deliberately does not. Looking at Gather on your
Mac is no reason to withhold a wave from the screen in your pocket.

---

## 🔔 Notifications, and reaching a phone that is asleep

There are two delivery paths and they cover different moments.

**Local notifications** fire from the app itself, and only while it is running —
in the foreground, or during the short window iOS grants a backgrounded app
before it suspends the WebSocket. After that the socket is gone.

**Push** is what survives that. The bridge sends through Firebase Cloud
Messaging, so a wave reaches a locked or killed phone. Four reasons wake it:

| reason | on by default | why |
|---|---|---|
| wave | ✅ | rare, deliberate, always means somebody wants you |
| meeting invite | ✅ | scheduled and time-bound |
| event reminder | ✅ | scheduled and time-bound |
| someone follows you | ✅ | rare and unambiguous |
| someone next to you | ❌ | the noisiest by far — a colleague pacing near your desk crosses the threshold repeatedly. Enable with `push.kinds.proximity` in `~/.gather-app-bridge.json`; a ten-minute per-person cooldown applies |

No double-ups: iOS does not display a push while the app is frontmost unless the
app asks it to, and this one does not. So the local notification is what you see
when the app is open, and the push is the only one when it is not.

### Setting it up

Push is optional. Everything else works without it; you simply do not get woken
when the app is closed.

**1. An APNs key from Apple.** Developer portal → Certificates, Identifiers &
Profiles → **Keys** → new key → tick *Apple Push Notifications service (APNs)*.
Download the `.p8` — Apple lets you do that exactly once — and note the Key ID.
This is **not** the App Store Connect API key used to upload builds; different
section, different key.

**2. Enable the capability on the App ID**, then **regenerate the
`Gather Companion App Store` provisioning profile**. This is the step that bites:
signing here is manual (see `ios/ExportOptions.plist`), so an existing profile
without the push entitlement fails the build rather than quietly updating itself.

**3. Give the key to Firebase.** Console → Project settings → **Cloud Messaging**
→ APNs Authentication Key → upload the `.p8` with its Key ID and team `JQ4STVWTQ3`.

**4. Give the bridge a service account.** Console → Project settings → **Service
accounts** → *Generate new private key* → a JSON download. Then:

```sh
npx gather-app-bridge push setup ~/Downloads/gather-companion-....json
npx gather-app-bridge restart
```

That validates the file, copies it to `~/.gather-app-bridge-fcm.json` and chmods
it `0600`. Open the app once so the phone registers, then:

```sh
npx gather-app-bridge push test
```

> [!WARNING]
> **`aps-environment` is the classic silent failure.** A build signed for
> development gets a *sandbox* device token, and the production APNs gateway does
> not know it — the phone registers, the bridge sends, FCM answers `200`, and
> nothing arrives, with no error anywhere. That is why there are two entitlements
> files (`Runner.entitlements`, `RunnerRelease.entitlements`) wired per build
> configuration rather than one file Xcode rewrites, which it only does under
> automatic signing.

---

## 🪩 Party mode

The one control in the app, and the only thing in this project that *writes* to
Gather. Switch it on and the bridge teleports your avatar to a random tile four
times a second until you switch it off.

Two things make that less trivial than picking coordinates.

**Gather's server does not check walkability.** Every tile on the grid is
accepted — walls, scenery, the void outside the map. Collision is enforced
client-side only, so uniform random coordinates put you inside furniture about as
often as not. Rather than rebuild the collision map out of `MapObject` and
`CatalogItemVariant.collision`, the bridge takes the empirical route: **a tile
somebody has stood on is a tile you can stand on.** The state dump carries every
member of the space with their last position — 111 of them in the space this was
built against, most parked at a desk — and the pool grows as people walk around.

**Landing next to someone opens the video bubble on their screen.** Doing that
four times a second, to a different colleague each time, would be a genuinely
antisocial thing to inflict on an office. So every candidate tile is held at
least **8 tiles** from everyone currently connected — more than double the
3 tiles at which Gather connects media, with the margin covering the fact that
the roster is always a beat behind. Offline rows donate their tile without
defending it: a parked avatar is proof a body fits there and proof nobody is on
it.

When nothing clears, the hop is **skipped** rather than approximated, and the
card says why. A party that pauses is a smaller problem than a party that walks
into someone.

Measured live against a 111-person space: 16 hops in 4 seconds, closest approach
8.1 tiles.

It ends on its own after **15 minutes**. The toggle is on a phone and the hopping
happens on a computer that will happily keep going for days; between a flat
battery and a phone left in a drawer, "on until told otherwise" eventually means
"on all week". The app reads party state from the snapshot rather than
remembering what it asked for, so the button goes dark by itself when that timer
fires, when the bridge loses Gather, or when the daemon stops.

```sh
curl -X POST "localhost:7799/party?on=1&token=$TOKEN"   # if the phone is flat
curl -X POST "localhost:7799/party?on=0&token=$TOKEN"
```

Entering the space is **not** required to move — `SpaceUser` is
per-person-per-space, so an observer connection drives the same avatar the
desktop client draws. That is what keeps this free: `numTimesEnteredSpace`, the
one counter that cannot be undone, is never touched. See
[`docs/gather-api.md`](docs/gather-api.md).

---

## 🔬 How it reads the protocol

The bridge holds one binary WebSocket to
`wss://game-router.v2.gather.town/gather-game-v2`, decodes the msgpack, and
interprets the model deltas.

It used to read those same frames sideways, off the desktop client's devtools
port, because there was no other way in. There is now, and it is better in every
respect: no debug port left open on a live session, no dependency on the client
running, and a fresh state dump on every connect.

The handshake, in order — captured from the desktop client's *own* outbound
frames, so these shapes are observed rather than guessed:

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

- 🎯 **following** — a `replace` on *their* row's `/followTargetId` set to *my*
  id. There is no "follow started" server event; the official client derives it
  the same way (`SpaceUser.followers` filters by `followTargetId === this.id`).
  `followTargetId` and `clusterId` are optional columns, so they are *absent*
  rather than null when unset.
- 📐 **adjacency** — `position` compared with my own, requiring the same
  `floorId`. Position mutates component-wise, so walking arrives as `/position/x`
  and `/position/y`; a teleport replaces `/position` wholesale with an ext-0
  `Position` value object. Both shapes are handled.

Identity — which row is mine — comes from the `Connection` model, which carries
both halves:

```js
{ model: 'Connection', data: { authUserId: '<firebase uid>', spaceUserId: '<my SpaceUser id>' } }
```

The Firebase uid comes out of our own ID token, so no lookup is needed.
`UserAccount.firebaseAuthId` plus `SpaceUser.userAccountId` is a second route.

Bots and recording clients (`isBot`, `type: 'RecordingClient'`) are filtered out —
every real space has them and they are not people standing next to you.

### ❄️ Cold start, and `resync`

The full state dump is sent **once per connection** — which used to be a real
problem, because the connection belonged to somebody else. Attaching to a client
that had been running for days yielded heartbeats and nothing else until somebody
moved, and people who never moved stayed invisible; shaking the dump loose meant
reloading the Gather renderer.

The connection is ours now, so every connect is a fresh dump and `resync` is
simply a reconnect. The bridge still refuses to report itself healthy while it
holds no state — an empty roster presented confidently would let the app say
"nobody is following you" out of nothing.

---

## ⌨️ Commands

```
npx gather-app-bridge                install as a background service and pair
npx gather-app-bridge run            run in the foreground instead
npx gather-app-bridge status         is it alive, and who is around right now
npx gather-app-bridge pair           show a QR square for the phone to scan
npx gather-app-bridge adopt          reuse your Gather session (required, once)
npx gather-app-bridge doctor         what can it see, and how to see more
npx gather-app-bridge resync         force a full state resync
npx gather-app-bridge logs -f        follow the daemon log
npx gather-app-bridge token          show the pairing details again
npx gather-app-bridge restart|stop|start|uninstall
npx gather-app-bridge replay [file]  re-check the notification regex on a log
npx gather-app-bridge push           is push set up, and who is registered
npx gather-app-bridge push setup <f> install the Firebase service account JSON
npx gather-app-bridge push test      send a test notification to every phone
```

**Options:** `--port <n>` (default `7799`), `--token <s>`, `--log-file <path>`,
`--space <uuid>` (watch a specific space, rather than the last one you opened).

### 👁️ Watching the stream from a terminal

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
| `PresenceTracker` | anything that is not a *state change*: repeated proximity reports, and voice activity, which is recorded in state but never announced — `speaking` toggles every few seconds while somebody talks |
| `GameProtocolReader` | 43 of ~47 models — calendar events, chat metadata, catalog items, map areas, GitHub PRs. Only `SpaceUser`, `Connection`, `UserAccount` and `Space` are kept |
| the collector | heartbeats, bots, recording clients |

That filtering is deliberate — a feed that announced every flicker of voice
activity would be useless — but it means the published stream understates what is
available. `--raw` subscribes to the firehose before the tracker sees it. Frames
marked `kind: "raw"` rather than `kind: "event"`.

For what is being decoded but *discarded entirely* (the other 43 models, frame
type counts), look at `stats` in `GET /collectors`.

### ♾️ Staying up

On macOS it installs as a `LaunchAgent` (`com.jonasgrunau.gather-app-bridge`) with
`RunAtLoad` and `KeepAlive`, so it starts at login and comes back if it crashes.
Two details that matter over months of uptime:

- 📦 The package is **copied into `~/.gather-app-bridge/bridge`** at install time.
  `npx` runs out of a cache npm may prune, and a global install disappears on the
  next `npm uninstall` — either would leave launchd pointing at nothing.
- 🔗 It resolves a **version-independent `node`** (`/opt/homebrew/bin/node` and
  friends) rather than `process.execPath`, which under nvm/asdf points at a
  version-pinned path that vanishes on the next Node upgrade.

Across a sleep the game socket reconnects with backoff — and gets a fresh state
dump for free — while the notification tailer re-stats the log file, because it
polls rather than trusting `fs.watch`, which stops delivering events after a
suspend without erroring.

---

## 📡 HTTP / WebSocket API

Everything except `/health` needs `?token=<token>`.

| endpoint | what |
|---|---|
| `GET /health` | liveness, no token, nothing sensitive |
| `GET /state` | current snapshot: self, players, collector health |
| `GET /events?since=<seq>` | replay recent events |
| `GET /collectors` | what is connected, and why not |
| `WS /ws?since=<seq>` | snapshot frame, then live events |
| `WS /ws?raw=1` | additionally the unfiltered firehose, as `kind: "raw"` frames |
| `GET /resync` | force a full state resync (reconnects the game socket) |
| `POST /push/register` | phone hands over its FCM token (idempotent) |
| `POST /party?on=1\|0` | party mode on/off; `GET /party` reads it |
| `GET /pair/offer` | mint a pairing code (used by `pair`) |
| `GET /pair/claim?code=` | **no token** — trade a code for the token, once |

Every event carries `type`, `at`, `source` (`gather` \| `log` \| `bridge`) and
`confidence` (`observed` \| `inferred`). Frames are
`{kind:'snapshot'|'event', seq, ...}`; reconnecting with `?since=<lastSeq>`
replays exactly what was missed, which is what keeps the phone's log complete
across screen locks.

**Event types:** `proximity.entered/left`, `follow.started/stopped`,
`player.moved`, `self.changed`, `space.changed`, `notification.shown`,
`bridge.status`. The Dart package still decodes several types the bridge no
longer emits (`media.changed`, `audio.range`, `player.joinedSpace/leftSpace`,
`chat.message`), so a phone can read an older bridge.

The Dart definitions in `packages/gather_events` are the same contract, so the
app decodes these into a sealed class hierarchy.

---

## 📱 The app — Gather Companion

The bridge is the computer half; Gather Companion is the phone half. It says so
wherever there is room to — in-app header, `MaterialApp.title`, permission copy —
because "Gather" alone would read as Gather's own client. The one exception is
the home-screen label, which the launcher clips to about ten characters:
"Gather Companion" came out as "GatherCom…", so the tile says **Gather** and the
app introduces itself properly once opened.

Nothing in `lib/` is platform-specific: it is plain Flutter over an HTTP and
WebSocket contract, so the same code targets phones and desktops. Only the iOS
runner is scaffolded so far — `flutter create --platforms=android,windows,linux .`
at the repository root adds the rest, and the icon generator needs a matching output path
per platform.

```sh
flutter run -d <device>
```

To sideload on iOS: open `ios/Runner.xcodeproj` in Xcode, set a signing team
on the `Runner` target, then `flutter run -d <device>`. A free Apple ID works for
personal device installs.

**Build notes worth knowing:**

- 📐 **iOS 15.5 minimum**, required by `mobile_scanner`. The same package needs
  Android 5.0 / API 21 and camera permission in the manifest.
- 📦 **Swift Package Manager, not CocoaPods** on the iOS side. `mobile_scanner`
  7.x is a Swift package, and leaving the old CocoaPods integration in place
  breaks the build with a misleading *"missing expected TARGET_BUILD_DIR"*. If you
  ever re-add a pod-based plugin, expect to sort that out. Version 7 also dropped
  GoogleMLKit, which had no arm64 simulator slices — on 6.x the app simply could
  not run on an arm64 simulator at all.
- 🖥️ **Desktop targets have no camera scanner.** `mobile_scanner` is mobile-only,
  so a desktop build has to fall back to the type-the-code path, which already
  exists and is a first-class route rather than a fallback.

While working on the feed, `--dart-define=GATHER_PAIR=host:port:token` skips the
scanner, which a simulator or emulator has no camera for:

```sh
flutter run -d <device> --dart-define=GATHER_PAIR=127.0.0.1:7799:<token>
```

Your phone and computer have to be on the same network. Phone platforms ask for
local-network permission the first time, and for the camera the first time you
scan.

### 🔗 Pairing

Modelled on Superset's flow: scan the square, or type the eight characters. The
long token is never typed or shown — the QR carries a short code which the app
trades for the token exactly once (`GET /pair/claim`). The code lives for fifteen
minutes, only after somebody ran `pair`, and a few wrong guesses destroy it.

The alphabet excludes `0`, `1`, `I`, `L` and `O`, so there is nothing to misread.
A character outside it is refused rather than guessed at — pairing on a
misread code would be worse than asking someone to look again.

### 📋 What the feed shows

Only what is worth reading. Events are classified into three tiers:

| tier | what | shown |
|---|---|---|
| 🔵 **alert** | someone started following you | yes, on a Gather-blue card |
| ⚪ **notable** | someone arrived next to you or moved away, Gather's own notifications | yes |
| ▫️ **ambient** | mic and camera toggles, transport state, roster churn, your own device state | behind "Show N background events" |

The top of the screen answers *now* — who is next to you, who is following you —
straight from the bridge's snapshot, so it is right even if the app was closed
when it happened. The list underneath is history.

### 🎨 Palette and icon

The palette is Gather's own: `#4257DA`, read out of `app.v2.gather.town`'s
stylesheet (`--theme-color-accent`) rather than picked by eye, with the tint ramp
around it and Inter to match.

**The icon** is a proximity ping on a 32×32 pixel grid: you are the white block
in the middle, the ring is the radius the bridge watches, and the green marker on
it is somebody who just walked into range. Pixel geometry nods at the medium — a
tile-grid virtual office — while borrowing nothing from Gather's own mark; the
dark indigo tile is the app's own `background`, not Gather's blue square. It is
drawn by `tool/make_icons.mjs` (zero-dep: `node:zlib` plus a CRC table, same
spirit as the bridge's hand-rolled `qr.js`), which writes three sets from one
source of truth: all fifteen asset-catalog sizes, the launch mark on alpha, and
the squircled `docs/icon.png` at the top of this page.

```sh
node tool/make_icons.mjs --preview
```

The catalogue sizes stay full-bleed squares because iOS applies the squircle
itself — a tile that arrived pre-rounded would be masked twice and come out with
chewed corners. The documentation copy carries the mask in its pixels instead,
since GitHub strips the CSS that would otherwise round it.

### 🔔 Notifications, honestly

Local notifications fire while the app is running — foreground, or the short
window the OS allows after backgrounding. Once the OS suspends the app the
WebSocket is gone and nothing can be delivered until you open it again, at which
point the bridge replays everything missed, so the *log* stays complete even
though the *alerts* do not. Waking a locked phone would need a push service driven
from the computer, which means a developer account and push credentials on each
platform.

---

## 🧪 Tests

```sh
npm test          # bridge: parser, msgpack, protocol, end-to-end over a real WS
flutter analyze && flutter test
```

The parser tests use log lines copied verbatim from a real
`~/Library/Logs/GatherV2/main.log`, and `replay` re-checks the regexes against a
whole log file after a client update:

```sh
npx gather-app-bridge replay ~/Library/Logs/GatherV2/main.log
```

---

## 🏷️ Releasing

One tag ships both halves. Bump the version in `package.json`, commit, then:

```sh
git tag -a v0.2.0 -m "gather-app-bridge 0.2.0"
git push --tags
```

`.github/workflows/publish.yml` runs the bridge tests and `flutter analyze`/
`flutter test` as a gate, then — only if both are green — publishes
`gather-app-bridge` to npm and uploads a signed build to TestFlight. The tag is
the version for both: `v0.2.0` becomes `0.2.0` on npm and `0.2.0` in App Store
Connect, with the workflow's run number as the build number. **`version:` in
`pubspec.yaml` is not read by a release** — it only affects a local
`flutter run`.

A failed run can be re-run from the Actions tab, or re-dispatched with
`gh workflow run publish.yml`; npm skips a version that already shipped, and a
re-run gets a fresh build number, so neither half objects to going twice.

**Things worth knowing before touching any of this:**

- 📛 **The workflow file must stay `publish.yml`.** npm's trusted-publisher entry
  matches the file *path*, not the workflow's `name:`. Renaming it fails the
  publish with `404 … package not found`, which reads like a missing package.
- 🔑 **Six repository secrets.** npm needs none — it authenticates with OIDC.
  The app needs the App Store Connect key for the upload (`ASC_KEY_ID`,
  `ASC_ISSUER_ID`, `ASC_KEY_P8`) and its signing assets
  (`APPLE_DIST_CERT_P12` — base64 of a `.p12`, `APPLE_DIST_CERT_PASSWORD`,
  `APPLE_PROVISIONING_PROFILE` — base64 of a `.mobileprovision`).
- ✍️ **Signing is manual, on purpose.** Automatic signing wants to update the
  Xcode-managed profile during export, which is a *cloud signing* operation, and
  an App Store Connect API key is never permitted to do one — it fails with
  `Cloud signing permission error` however the key is scoped. It works on a Mac
  only because Xcode has an Apple ID session, which a runner does not. Naming an
  explicit certificate and profile in `ios/ExportOptions.plist` removes the
  problem: nothing has to be created at build time.
- 📅 **The certificate and profile expire 2027-08-05** and are reissued together
  — `Apple Distribution` for team `JQ4STVWTQ3`, and the App Store profile
  *Gather Companion App Store* bound to it. Reissue both, refresh the three
  `APPLE_*` secrets, and re-import the `.p12` locally.
- 📱 **To upload from your own Mac instead**, `tool/upload-testflight.sh
  --build` does the same thing, reading the issuer from
  `~/.appstoreconnect/issuer_id` and exporting through the same
  `ExportOptions.plist`. CI runs that same script. It needs the distribution
  certificate in your login keychain and the profile in
  `~/Library/MobileDevice/Provisioning Profiles`.

---

## ⚠️ Scope and caveats

- 🖥️ **The bridge runs on macOS today.** It reads macOS log paths and installs a
  LaunchAgent. Everything above that line — the wire format, the collectors, the
  app — is platform-neutral; porting means new log/config paths and a service
  installer per platform, not a new protocol.
- 🙈 **Without a Gather session the bridge sees nothing.** `run` refuses to start
  rather than serving an empty room, and the app says so too, so a quiet screen is
  never mistaken for "nobody is following me".
- ✅ **The wire format is verified, not inferred.** Captured from a live
  authenticated session: the handshake order, the three patch ops, both envelope
  keys (`fullStatePatches`, `patches`), the `Connection` identity row and the
  `SpaceUser` field set. Replaying that capture resolves the right own-row id and
  yields the correct set of nearby people, by name. What has *not* been observed
  on the wire is a follow actually starting — `followTargetId` is an optional
  column and nobody was following during capture — so that one path rests on the
  SDK's own model definition rather than an observation.
- 📊 `GameProtocolReader.stats()` reports frame types and unrecognised-frame
  counts, so a future format change shows up as a number rather than as silence.
  Check it via `GET /collectors` (`stats`).
- 🌊 **Wire-format drift.** The web app redeploys constantly. The *field* names
  (`followTargetId`, `position`, `clusterId`, `floorId`) are Prisma columns and
  change rarely; the msgpack framing and patch envelope are internal and could
  change with any deploy. `bridge.status` events tell the app when a collector goes
  quiet, so drift shows up as a visibly degraded state rather than silence.
- 🚩 **Waves depend on a log line Gather never promised to keep.** The one thing
  still scraped is `IPC Event: SHOW_NOTIFICATION`, written by the Electron main
  process. If Gather changes it, `npx gather-app-bridge replay` on a log you know
  contained a wave will report zero and say so. Presence is unaffected — it comes
  from the protocol, not the log.
- ✍️ **The bridge does write to the socket** — this used to say "read-only", and
  that is no longer the whole truth. `DirectCollector` sends five frame shapes and
  nothing else: `Authenticate`, `ConnectToSpace`, `Subscribe`, one
  `Action{loadSpaceUser}`, and a heartbeat every ten seconds. It mutates no game
  state: it does not move, chat, follow, or change any setting, and it never sends
  `enterSpace`, so no avatar appears. The desktop client itself is still never
  modified — `app.asar` integrity validation is enabled, so patching it is not
  possible anyway.
- 🔑 **The bridge stores a Gather credential.** `adopt` copies a Firebase refresh
  token out of the desktop client's IndexedDB into `~/.gather-app-bridge.json` at
  `0600` — the same file and permissions as the pairing token. It is your own
  session, on your own machine, and grants the bridge no more than the desktop app
  beside it already has; it is sent only to Google's token endpoint and Gather's own
  hosts. It is still a credential on disk, which is worth knowing before you run
  `adopt` on a shared machine.
- 🔎 Reverse-engineered from your own installed client for interoperability, and
  written up in [`docs/gather-api.md`](docs/gather-api.md) — 217 REST endpoints, the
  auth flow, the game protocol, and an explicit list of what is still unverified.
  There is still no *public* Gather 2.0 API that exposes presence: the documented
  HTTP API is Classic-only and explicitly unsupported, `@gathertown/gather-game-client`
  was last published in 2023 and does not speak v2, and the private v2 REST API —
  though now mapped — contains no roster, no positions and no presence of any kind.
  The game socket is the only route, which is why both rich collectors use it.

---

<div align="center">

MIT · not affiliated with Gather · built for the people who keep walking up behind you

</div>
