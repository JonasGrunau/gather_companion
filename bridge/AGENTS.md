<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-05 | Updated: 2026-08-05 -->

# bridge

## Purpose

`gather-app-bridge` — the computer half. A zero-dependency Node daemon that
watches the Gather V2 desktop client running on the same machine and serves what
it sees over the LAN as HTTP and WebSocket. Installed as a macOS LaunchAgent by
default, so it starts at login and survives crashes and sleep.

Two collectors read the same client at different fidelities and feed one
`PresenceTracker`:

```
  ~/Library/Logs/GatherV2/main.log ──▶ LogTail ──▶ GatherLogParser ──┐
                                                                     ├─▶ PresenceTracker ──▶ WS clients
  Gather renderer (CDP, optional) ───▶ CdpCollector ─────────────────┘
```

- **Log-only mode** works with no setup. Proximity is *inferred* from Gather's
  proximity-gated media connections. No names, no coordinates, and being followed
  cannot be detected at all.
- **Full mode** needs the client started with `--remote-debugging-port`. The
  collector reads the msgpack game-protocol frames the client is already
  exchanging and gets names, tile coordinates, cluster adjacency, and real
  `followTargetId`-based follow detection.

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
