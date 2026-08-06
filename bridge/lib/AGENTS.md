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
| `server.js` | `BridgeServer` — owns both collectors, the HTTP routes, the WS fan-out, the sequence numbers and the 500-event history buffer. The composition root. |
| `presence.js` | `PresenceTracker` (folds events into current state, suppresses duplicates, decides what a human should see) and `FollowDetector` (infers following from movement when `followTargetId` is unavailable). Exports `ADJACENT_TILES` / `LEAVE_TILES`. |
| `events.js` | Every event constructor, and therefore the wire format. `{type, at, source, confidence, ...payload}`. Also `newPlayer()` / `emptySelf()` snapshot shapes. |
| `cdp.js` | `CdpCollector` — attaches to the Chrome DevTools browser endpoint, discovers every target, enables the Network domain, and routes binary WebSocket frames to the protocol reader. Also `probeCdp()`. |
| `game-protocol.js` | `GameProtocolReader` — interprets Gather's model-patch protocol into a `SpaceUser` roster and resolves which row is *me*. |
| `msgpack.js` | Hand-written MessagePack **decoder**, including Gather's five extension types. |
| `log-parser.js` | `GatherLogParser` — regexes over `main.log`, both the `(webapp)` and `(main)` scopes, plus `parseInspect()` for `util.inspect` bodies. |
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
- **`events.js` is a published contract.** Field names are mirrored in
  `packages/gather_events/lib/src/events.dart` and documented in the root
  `README.md`. Renaming one breaks the app with no compile error.
- **`log-parser.js` has an id-namespace trap.** `GameMediaController.*` and
  `[Vol]` lines carry **player ids**; `*SFU`, `participantUserAccountIdMap` and
  `[BitM]` lines carry a **different participant id** namespace with zero
  overlap, despite the method names saying "player". Proximity must only ever be
  derived from the former. This was established empirically over ~2.5 MB of real
  logs.
- **`game-protocol.js` patch paths are addressed to the row**, so the field is
  the *first* segment (`/position/x` → `position`). Reading the last segment
  would silently drop every walking patch. `followTargetId` and `clusterId` are
  optional columns — absent, not null — so only touch them when the key is
  actually present.
- **`presence.js` hysteresis is deliberate.** `ADJACENT_TILES` (3) for arriving,
  `LEAVE_TILES` (4.5) for leaving. Collapsing them to one threshold makes anyone
  loitering at the boundary flap forever, and every flap is a phone notification.
- **`cdp.js` distinguishes "attached" from "holding state".** The full state dump
  is sent once per client connection, so a bridge that attaches to a long-running
  client sees only heartbeats. `hasState` gates health for that reason; do not
  report healthy without it.
- `log-tail.js` polls `stat` as the primary trigger and uses `fs.watch` only as
  an accelerator, because `fs.watch` stops delivering events after a macOS
  suspend *without erroring*. Do not invert that.
- Filtering happens in three places (`PresenceTracker` drops non-state-changes,
  `GameProtocolReader` keeps 3 of ~45 models, both collectors drop heartbeats and
  bots). `?raw=1` subscribers bypass the first. Keep the firehose reachable.

### Testing Requirements

```sh
npm test
```

`log-parser`, `msgpack`, `game-protocol` and `pairing`/`qr` have dedicated
suites; `server.js`, `presence.js` and `ws.js` are covered end-to-end by
`../test/bridge.test.js`. Fixtures are real captured data — add to them in the
same style rather than inventing plausible-looking lines.

### Common Patterns

- `EventEmitter` subclasses for collectors; `start()` / `stop()` lifecycle;
  exponential backoff capped at 15–30s; `timer.unref?.()` everywhere.
- Pure functions and constructors in `events.js`; no classes for data.
- Defensive decoding: unknown shapes are counted in `stats()` rather than thrown,
  so wire-format drift surfaces as a number instead of silence.

## Dependencies

### Internal

`server.js` composes `cdp`, `log-parser`, `log-tail`, `presence`, `pairing`,
`paths`, `ws` and `events`. `cdp.js` uses `game-protocol` and `msgpack`.
`launchd.js` uses `paths`. Consumed by `../bin/gather-bridge.js`.

### External

Node 22+ builtins only: `node:http`, `node:crypto`, `node:fs`, `node:os`,
`node:path`, `node:zlib`, `node:child_process`, plus global `fetch` and
`WebSocket`.

<!-- MANUAL: -->
