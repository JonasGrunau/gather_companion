<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-05 | Updated: 2026-08-05 -->

# lib

## Purpose

Everything the bridge actually does: two collectors, the protocol decoders they
need, the state machine that folds their output into "what does the world look
like right now", and the HTTP/WebSocket server that publishes it. Also the
platform plumbing — launchd installation, paths, pairing codes.

## Key Files

| File | Description |
|------|-------------|
| `server.js` | `BridgeServer` — owns the collector, the notification tail, the HTTP routes, the WS fan-out, the sequence numbers and the 500-event history buffer. The composition root. |
| `presence.js` | `PresenceTracker` — folds the roster into current state, suppresses duplicates, decides what a human should see. Answers one question about other people: who is following me. |
| `events.js` | Every event constructor, and therefore the wire format. `{type, at, source, confidence, ...payload}`. Also `newPlayer()` / `emptySelf()` snapshot shapes. |
| `direct.js` | `DirectCollector` — **the only collector.** Authenticates to Gather and opens its own game socket in *observer* mode, so it needs no debug port and no running desktop client. |
| `gather-auth.js` | Gather's own auth: adopts the desktop client's Firebase session out of IndexedDB, refreshes ID tokens, and does authenticated REST calls. |
| `fcm.js` | `FcmSender` — Firebase Cloud Messaging HTTP v1, hand-rolled: RS256 service-account JWT → OAuth2 access token → `messages:send`. Also `readServiceAccount()`. |
| `push.js` | `PushNotifier` (which events deserve waking a locked phone) and `PushRegistry` (the registered devices, persisted in the config file). `describe()` holds the policy and is pure. |
| `game-protocol.js` | `GameProtocolReader` — interprets Gather's model-patch protocol into a `SpaceUser` roster, reads the space name off the `Space` row, resolves which row is *me*, and drains `DeltaState.events[]` (Gather's event bus: waves, chat). Also `MeetingWatch`, which turns `MeetingParticipant` and `MeetingJoinRequest` rows into invites and knocks. |
| `msgpack.js` | Hand-written MessagePack. **Decoder** covers Gather's five extension types; **encoder** covers only what we send (plain maps/strings/numbers) and throws on anything else. |
| `desktop-notifications.js` | `DesktopNotificationReader` — the last scraper, and down to two signals (`meeting invite`, `event reminder`). One line shape (`IPC Event: SHOW_NOTIFICATION`) in the `(main)` scope, plus `parseInspect()` for `util.inspect` bodies. **`wave` is deliberately ignored**: waves come off the game socket's `DeltaState.events[]` bus, with a sender, whether or not the desktop app is running. |
| `log-tail.js` | `LogTail` — follows a growing file across rotation, truncation and machine sleep. |
| `ws.js` | Minimal RFC 6455 **server** (handshake, framing, backpressure limits). |
| `pairing.js` | `PairingCodes` — short-lived single-use codes, the unambiguous 31-character alphabet, `pairPayload()` and `normalise()`. |
| `qr.js` | ISO/IEC 18004 QR encoder for versions 1–3 at EC level M, alphanumeric mode only, rendered as terminal half-blocks. |
| `launchd.js` | LaunchAgent install/uninstall/start/stop, the private copy into `~/.gather-app-bridge`, and stable-`node` resolution. |
| `paths.js` | Every path and the config file: `LABEL`, `stateDir`, `gatherLogFile`, token minting, LAN address discovery, log rotation. |
| `cli-args.js` | `parseCommand`, `flagValue`, `parsePort`, and `VALUE_FLAGS`. |

## For AI Agents

### Working In This Directory

- **No dependencies, ever.** `launchd.install()` copies this directory verbatim
  and runs it with no `node_modules`. `msgpack.js`, `ws.js` and `qr.js` exist
  precisely because of that; each says so in its header.
- **`direct.js` must never send `enterSpace`.** `loadSpaceUser` gets the state
  dump; `enterSpace` is a separate action and is what puts an avatar in the space.
  Omitting it is what makes the collector invisible to colleagues *and* what keeps
  it from colliding with the user's own desktop session. A duplicate connection was
  measured harmless in observer mode only — two *entered* connections were never
  tested. `bridge/test/direct.test.js` guards this.
- **Entering is not a prerequisite for writing.** `teleport` was measured working
  from an observer connection (2026-08-07), because `SpaceUser` is
  per-person-per-space while `Connection.entered` is per-socket. So the rule above
  costs nothing: the app's own party mode moves the avatar without ever incrementing
  `numTimesEnteredSpace`. `teleport` is the *only* write this bridge makes, and a
  second one should have to argue for itself — the gateway would accept anything.
- **Party mode must never publish per hop.** It runs at 4Hz and every `change`
  event sends a snapshot to every connected phone; the hop counter is therefore
  pulled in at `BridgeServer._snapshot()` rather than pushed. This is the same
  failure the collector's health detail once had, where a frame counter in the
  detail string filled the 500-event replay history within minutes.
- **A wrong handshake fails silently.** Gather does not reject a frame it cannot
  parse: it keeps heartbeating and says nothing. So `msgpack.js`'s encoder refuses
  values it cannot represent faithfully rather than emitting something plausible,
  and `direct.js` reports "connected but holding no state" instead of "healthy".
  If the roster is ever empty while frames flow, suspect the frame shape.
- **`health.cdp` is a compatibility alias, not a collector.** The status event
  says `collector: 'gather'`, and `PresenceTracker` mirrors that onto `cdp`
  because app builds already on phones compute `hasRichData` from
  `CollectorHealth.cdp`. Publishing only the honest name would make them show the
  "log-only mode: no names" banner while the bridge held the full roster. Newer
  builds read `gather`. Do not remove the mirror until those builds are gone.
- **Push is the path that survives the app being killed**, so it obeys different
  rules from the local notifications in the app. Four reasons exist and all four
  are on: wave, meeting invite, event reminder, follow. Every one is a deliberate
  act by a person, which is why there is no rate limiting — the cooldown that
  used to exist was there for proximity, and proximity is gone. A new reason that
  needs a cooldown is a reason that does not belong here.
- **`BridgeServer` must be given a `push` in tests.** Left to build its own it
  reads `~/.gather-app-bridge-fcm.json` and the real device list, so a suite on a
  machine where push is set up would fire real notifications at a real phone.
  `PushRegistry` takes `read`/`write` seams for the same reason — registering a
  device for real would rewrite the developer's own config.
- **A push failure must never break the event pipeline.** The phone with a live
  socket already has the event; a Google outage must not take the socket with it.
  `PushNotifier.consider` swallows everything, and `server.js` calls it
  fire-and-forget.
- **`events.js` is a published contract.** Field names are mirrored in
  `packages/gather_events/lib/src/events.dart` and documented in the root
  `README.md`. Renaming one breaks the app with no compile error.
- **`desktop-notifications.js` keys off the IPC line, not the `Showing
  notification` line that follows it.** Gather suppresses its own notification
  when its window has focus, and then the second line never appears — but the
  phone is a different device and should still be told. Keying off the IPC line
  also stops each notification being reported twice.
- **Do not grow `desktop-notifications.js` back into a general log parser.**
  Everything the old one produced — roster churn, media — now comes from the
  protocol, observed rather than inferred. The scrape survives only for what
  genuinely exists nowhere else.
- **`game-protocol.js` patch paths are addressed to the row**, so the field is
  the *first* segment (`/position/x` → `position`). Reading the last segment
  would silently drop every walking patch. `followTargetId` is an optional
  column — absent, not null — so only touch it when the key is actually present;
  `presence.js` tells the two apart to decide whether following is answerable.
- **Proximity was removed deliberately, and is not a missing feature.** Being
  near somebody says nothing about whether they want you: people park at desks,
  walk past, and loiter at thresholds. It produced most of the events and least
  of the meaning, and the thresholds and hysteresis it needed existed only to
  make its own noise bearable. `position` and `floorId` are still decoded, but
  only so the app's party mode knows which tiles a body fits on. Do not reintroduce
  `isNear`, tile distances or adjacency thresholds.
- **`direct.js` distinguishes "connected" from "holding state".** `hasState`
  gates health, because an empty roster reported confidently lets the app render
  "nobody is following you" out of nothing.
- **Keep counters out of the health `detail` string.** `_setHealth` publishes an
  event whenever the detail changes, and a frame counter changes on every 250ms
  flush — that fills the 500-event history the phone replays on reconnect with
  status noise and evicts the real events within minutes. Counters belong in
  `stats()`, which is polled.
- `log-tail.js` polls `stat` as the primary trigger and uses `fs.watch` only as
  an accelerator, because `fs.watch` stops delivering events after a macOS
  suspend *without erroring*. Do not invert that.
- Filtering happens in three places (`PresenceTracker` drops non-state-changes,
  `GameProtocolReader` keeps 4 of ~47 models, the collector drops heartbeats and
  bots). `?raw=1` subscribers bypass the first. Keep the firehose reachable.

### Testing Requirements

```sh
npm test
```

`desktop-notifications`, `msgpack`, `game-protocol`, `direct`, `gather-auth`,
`presence` and `pairing`/`qr` have dedicated suites; `server.js` and `ws.js` are
covered end-to-end by `../test/bridge.test.js`, which drives a real
`BridgeServer` against the fake Gather in `../test/fake-gather.js`. Fixtures are
real captured data — add to them in the same style rather than inventing
plausible-looking lines.

### Common Patterns

- `EventEmitter` subclasses for collectors; `start()` / `stop()` lifecycle;
  exponential backoff capped at 15–30s; `timer.unref?.()` everywhere.
- Pure functions and constructors in `events.js`; no classes for data.
- Defensive decoding: unknown shapes are counted in `stats()` rather than thrown,
  so wire-format drift surfaces as a number instead of silence.

### Two signals that look real and are not

Both of these were shipped, both were wrong, and both are the kind of thing that
gets "fixed" back by someone reading the log and trusting it. `presence.test.js`
pins them.

- **`setStreamPausedState <id> <track> false` does not mean that person is
  sending.** It is logged when the client *subscribes* to a remote track, which
  happens when somebody comes close. Gather never logs the matching `true`: across `main.log`
  and `main.old.log`, 249 such lines, 74 `screen false`, 175 `video false`, zero
  `true` in either direction. The video and screen track sets were the same 17
  people — the client unpauses a participant's whole track set at once. Reading
  it as "on" latches a flag nothing can clear, so everyone who walks past you is
  reported as screen sharing forever. Only a pause is trusted, and it can only
  turn state off. `SpaceUser` carries no media columns at all, so there is no
  second source: **remote mic, camera and screen state are not observable.**
- **A `SpaceUser` row with `connected: false` is furniture.** The full state dump
  carries every member of the space, not just the ones online — 80 rows, 25
  connected, 54 of the rest still holding the coordinates where their owner
  logged off, which is usually their desk. Party mode leans on exactly this: an
  offline row's position is a tile somebody really stood on and nobody is
  standing on now, which makes the parked half of a space the best source of safe
  tiles rather than dead weight. Anything that reasons about *people* must still
  gate on `connected !== false`.

## Dependencies

### Internal

`server.js` composes `direct`, `desktop-notifications`, `log-tail`, `presence`,
`pairing`, `paths`, `ws` and `events`. `direct.js` uses `game-protocol`,
`msgpack`, `gather-auth` and `paths`.
`launchd.js` uses `paths`. Consumed by `../bin/gather-bridge.js`.

### External

Node 22+ builtins only: `node:http`, `node:crypto`, `node:fs`, `node:os`,
`node:path`, `node:zlib`, `node:child_process`, plus global `fetch` and
`WebSocket`.

<!-- MANUAL: -->
