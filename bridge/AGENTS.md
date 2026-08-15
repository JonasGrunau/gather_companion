<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-05 | Updated: 2026-08-05 -->

# bridge

## Purpose

`gather-app-bridge` — the computer half. A zero-dependency Node daemon,
installed as a macOS LaunchAgent by default, so it starts at login and survives
crashes and sleep.

**It is no longer how the app sees Gather.** The phone holds its own authenticated
socket (`packages/gather_client`), so this daemon is down to two jobs:

1. **Pairing.** `/pair/claim` hands the phone the bridge token *and the Gather
   session*, which is the only moment the phone can be given one. Because it is
   the only moment, `pair` re-reads the desktop client's session first
   (`refreshSessionForPairing`) and refuses to issue a code without a live one — a
   dead credential cannot be repaired from the phone's end, which can only ask to
   pair again, which is where it already is. `logout` is the way back out.
2. **Push.** Something has to be awake when the app is not, notice a follow or a
   wave, and hand it to FCM. That is the whole reason this still connects to
   Gather at all.

```
  Gather's game server ─────────────▶ DirectCollector ────────────┐
                                                                  ├─▶ PresenceTracker ─▶ push
  ~/Library/Logs/GatherV2/main.log ─▶ DesktopNotificationReader ──┘        └─▶ WS (operators)
```

The HTTP and WebSocket surface still exists and still works — `watch`, `replay`,
`resync` and `doctor` are built on it — but nothing on a phone uses it except one
idempotent `POST /push/register`. It is dormant when nothing is attached.

- **`DirectCollector` is the whole presence story.** It authenticates with the
  session `gather-app-bridge adopt` copied out of the desktop client, then opens
  its own game socket in observer mode: full roster, names, tile coordinates,
  cluster adjacency, real `followTargetId` follow detection and live voice
  activity. No debug port, and it keeps working with the desktop app closed. Every
  connection replays the full state dump, so `resync` is just a reconnect.
- **`DesktopNotificationReader` is the last scraper, and it is nearly gone.** It
  reads one line shape (`IPC Event: SHOW_NOTIFICATION`) and is down to **event
  reminders**. It used to carry waves and meeting invites too, on the belief that
  those were decisions Gather's *client* made and handed to macOS, appearing in no
  model or patch. That was wrong on both counts:
  - a **wave** arrives on `DeltaState.events[]`, Gather's own event bus, with a
    `senderId` — see `lib/game-protocol.js`;
  - a **meeting invite** is `MeetingParticipant{spaceUserId, inviterId}` in state.

  Both now come from the socket, which is better in every way: earlier, attributed
  to a person, and working with the desktop app closed. An event reminder is
  derivable too (`BaseCombinedCalendarEvent.startDateTime`) and nobody has done it
  yet, which is the only reason this file survives.

Two collectors were deleted in favour of this, and should not come back:
`CdpCollector` (attached to the desktop renderer's devtools port — required a
debug port open on a live authenticated session, and could not get a state dump
without reloading the renderer) and the broad `GatherLogParser` (regexes over
`main.log` for adjacency, media and roster churn — none of which is read that way
any more: following comes from the protocol, and proximity was dropped outright).

**Mic, camera and screenshare are gone and are not recoverable.** They were IPC
state inside the desktop client and appear in no Gather model. `SpaceUser.speaking`
— live voice activity, and the most frequent delta on the wire — is the
replacement, and is a better signal anyway.

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| `bin/` | The CLI entry point and every subcommand (see `bin/AGENTS.md`) |
| `lib/` | Collectors, protocol decoders, server, pairing, launchd (see `lib/AGENTS.md`) |
| `test/` | `node --test` suites over real captured data (see `test/AGENTS.md`) |

There are no files directly in `bridge/`; `package.json` lives at the repository
root and ships exactly `bridge/bin` and `bridge/lib`.

## For AI Agents

### Working In This Directory

- **Never add a dependency.** `launchd.install()` copies `lib/` and `bin/` into
  `~/.gather-app-bridge/bridge` and runs them from there with no `node_modules`.
  Everything non-trivial is therefore hand-written: `msgpack.js`, `ws.js`,
  `qr.js`. This is a hard constraint, not a preference.
- The installed copy is one directory level shallower than the repo layout.
  Anything resolving paths relative to the module must handle both — see
  `findPackageRoot` in `lib/launchd.js` and the `bridge/lib` existence check in
  `install`.
- **Wire-format changes are user-visible.** Event shapes in `lib/events.js` are
  the contract with `packages/gather_events` on the Dart side.
- The daemon runs for months. Any new long-lived resource needs the same care
  the existing ones got: poll rather than trust `fs.watch` across sleep, reconnect
  with backoff, `unref()` timers.

### Testing Requirements

```sh
npm test        # from the repository root
```

`test/bridge.test.js` boots a real `BridgeServer` on a temp log file and drives a
real WebSocket, so it covers the transport as well as the parsing.

### Common Patterns

- ESM throughout, `node:`-prefixed builtins, `export class` / `export function`.
- Collectors are `EventEmitter`s emitting `roster` / `status` / `line`.
- Every module opens with a doc comment explaining the failure mode that shaped
  it.

## Dependencies

### Internal

- Consumed by `packages/gather_events` on the Dart side (contract only, no code
  sharing).
- `test/live_bridge_test.dart` at the repository root can run the real daemon.

### External

None. Node 22+ builtins only.

<!-- MANUAL: -->
