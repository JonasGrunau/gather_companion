<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-05 | Updated: 2026-08-05 -->

# bridge

## Purpose

`gather-app-bridge` — the computer half. A zero-dependency Node daemon that
connects to Gather V2 with the user's own session and serves what it sees over
the LAN as HTTP and WebSocket. Installed as a macOS LaunchAgent by default, so it
starts at login and survives crashes and sleep.

```
  Gather's game server ─────────────▶ DirectCollector ────────────┐
                                                                  ├─▶ PresenceTracker ─▶ WS clients
  ~/Library/Logs/GatherV2/main.log ─▶ DesktopNotificationReader ──┘
```

- **`DirectCollector` is the whole presence story.** It authenticates with the
  session `gather-app-bridge adopt` copied out of the desktop client, then opens
  its own game socket in observer mode: full roster, names, tile coordinates,
  cluster adjacency, real `followTargetId` follow detection and live voice
  activity. No debug port, and it keeps working with the desktop app closed. Every
  connection replays the full state dump, so `resync` is just a reconnect.
- **`DesktopNotificationReader` is the only thing still scraped**, and it reads
  exactly one line shape: `IPC Event: SHOW_NOTIFICATION`. Waves, meeting invites
  and event reminders are decisions Gather's *client* makes and hands to macOS —
  they are in no model, no REST route and no delta patch. They are also precisely
  the events worth waking a phone for, which is why the dependency is worth
  keeping. Presence does not depend on it.

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
