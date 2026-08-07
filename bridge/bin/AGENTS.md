<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-05 | Updated: 2026-08-05 -->

# bin

## Purpose

The `gather-app-bridge` command. One executable holding every subcommand, the
terminal rendering for all of them, and nothing else — all logic lives in
`../lib`.

## Key Files

| File | Description |
|------|-------------|
| `gather-bridge.js` | The whole CLI: command dispatch, install/run/status/doctor/pair/watch/resync/replay, plus the ANSI helpers and the `describe()` event formatter used by `watch`. |

## Commands

| Command | What it does |
|---|---|
| *(default)* `install` | Copies the package to `~/.gather-app-bridge/bridge`, installs the LaunchAgent, waits for the daemon, prints pairing details |
| `run` | Foreground daemon. What launchd actually executes |
| `status` | launchd state, liveness, collector health, who is near and who is following |
| `doctor` | What the bridge can see right now, and the exact command to enable full mode |
| `pair` | Mints a code, draws the QR square, then blocks until it is claimed or expires |
| `token` | Reprints the pairing details |
| `resync` | Reloads the Gather renderer so the server resends its full state dump |
| `watch` | Attaches to the live feed and prints it — `--history`, `--filter`, `--json`, `--raw`, `--host` |
| `replay [file]` | Runs a log file through the parser and summarises the event counts |
| `logs [-f]`, `start`, `stop`, `restart`, `uninstall` | Daemon housekeeping |

## For AI Agents

### Working In This Directory

- **Argument parsing has two real bugs baked into its tests.** `parseCommand`
  skips the values of value-taking flags (`--port 7789` must not be read as the
  command `7789`), and `--version` / `--help` are checked *before* dispatch
  because the default command is `install` — otherwise asking for the version
  reinstalls the daemon. Do not simplify either.
- Adding a flag that takes a value means adding it to `VALUE_FLAGS` in
  `../lib/cli-args.js`, or it will be mistaken for a command.
- `cmdRun` treats `EADDRINUSE` from another *bridge* as success and exits 0, so
  launchd does not respawn in a loop. Keep that distinction from "something else
  has the port".
- `describe()` is the terminal's own phrasing of an event. The app has its own in
  `lib/src/relevance.dart`; they are intentionally separate and need not agree
  word for word, but a new event type should be handled in both.
- In `cmdWatch`, the WebSocket `message` listener parameter must not be named
  `raw` — it would shadow the `--raw` flag and silently print nothing. There is a
  comment saying so; leave it.

### Testing Requirements

No direct unit tests for the CLI itself — argument parsing is covered through
`../lib/cli-args.js`, and behaviour through `../test/bridge.test.js`. Exercise
changes by hand:

```sh
node bridge/bin/gather-bridge.js run --port 7830 --token t --log-file /tmp/f.log
node bridge/bin/gather-bridge.js watch --port 7830 --token t --history 20
node bridge/bin/gather-bridge.js replay ~/Library/Logs/GatherV2/main.log
```

### Common Patterns

- `line(label, value)` for aligned key/value output; `dim`/`bold`/`green`/`red`/
  `yellow` for colour. Two-space indentation on every printed line.
- Commands are `async function cmdX()`, thrown errors are caught by the top-level
  handler and printed in red with exit 1.
- Output is written for a person reading a terminal, not for a log: complete
  sentences, and a concrete next command whenever something is wrong.

## Dependencies

### Internal

Everything in `../lib`: `cli-args`, `desktop-notifications`, `gather-auth`,
`launchd`, `pairing`, `qr`, `paths`, `server`.

### External

Node builtins only — `node:child_process` (`pgrep`, `tail`), `node:fs`,
`node:readline`, plus the global `fetch` and `WebSocket`.

<!-- MANUAL: -->
