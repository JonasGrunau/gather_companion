<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-05 | Updated: 2026-08-05 -->

# test

## Purpose

`node --test` suites for the bridge. The distinguishing property: fixtures are
**real captured data**, not invented shapes. Log lines are copied verbatim from a
live `~/Library/Logs/GatherV2/main.log`, and the protocol frames were captured
from an authenticated session and then rewritten with synthetic ids and names.
That is what makes these tests evidence that the reverse-engineering is right,
rather than evidence that the code matches its own assumptions.

## Key Files

| File | Description |
|------|-------------|
| `bridge.test.js` | End-to-end: boots a real `BridgeServer` against the fake Gather server, drives it with real model patches, appends real log lines to a temp log, and reads the results over a real WebSocket. Covers auth, snapshot-then-events framing, follows, waves, that walking about produces nothing at all, and `?since=` catch-up. |
| `game-protocol.test.js` | The largest suite. Model patches (`addmodel` / `deletemodel` / `replace`), both envelope keys, identity resolution via `Connection` and via `UserAccount`, component-wise position updates, teleports, follow detection, bot filtering — feeding `GameProtocolReader` into `PresenceTracker`. |
| `bridge.test.js` | The daemon end to end against a fake Gather: the socket wave (with sender, targeting and the per-sender cooldown), meeting invites and knocks, the pairing handover of *both* credentials, push, and the operator endpoints. The dump-versus-delta test spins its own server, because the point is what a state dump full of old invites does. |
| `desktop-notifications.test.js` | The last scraper, against verbatim log lines. Includes the suppressed-notification case (which decides which line to key off) and the assertion that a `wave` in the log is now *ignored*, because the socket reports it better. |
| `fake-gather.js` | **Not a suite.** A fake Gather game server shared by `bridge.test.js` and `direct.test.js`: real op names and envelope keys, synthetic ids. |
| `msgpack.test.js` | Decoder coverage. Ships a **test-only encoder** so fixtures are built in code rather than pasted as hex — the library itself is decode-only on purpose. |
| `pairing.test.js` | Code lifecycle (single use, expiry, attempt limit), the unambiguous alphabet, and the QR encoder. |

## For AI Agents

### Working In This Directory

- **Do not fabricate log lines.** If a new pattern needs covering, take the line
  from a real log. The whole point of these fixtures is that they prove the
  parser handles what Gather actually writes, whitespace and all.
- Protocol fixtures must keep the real op names, envelope keys and field
  spellings; only ids and display names are synthetic (uuids of repeated digits,
  a Firebase-shaped uid that belongs to nobody).
- `bridge.test.js` uses a temp directory and a fixed test token, and drives the
  server over the loopback interface. It is a real integration test — if it gets
  slow or flaky, fix the cause rather than mocking the transport.
- `msgpack.test.js`'s `enc()` helper is still test-only, but the reason has
  narrowed. `lib/msgpack.js` now exports a real `encode`, because `DirectCollector`
  does write to Gather's socket. `enc()` survives only because it can build
  *extension-type* fixtures, which the library encoder deliberately refuses. Test
  the library `encode` for anything the bridge actually sends.
- **Tests must never leave the machine.** Both `bridge.test.js` and
  `direct.test.js` inject `getToken` and point `socketUrl` at the local fake game
  server, so nothing authenticates to Gather or reads the developer's adopted
  session. A test whose result depends on whether the developer has run `adopt` is
  broken, however green it looks.
- `fake-gather.js` hand-rolls its WebSocket framing on purpose: `lib/ws.js`
  surfaces only *text* frames, since it exists to serve JSON to phones, and the
  game protocol is binary. Do not add binary support to `ws.js` for tests' sake.

### Testing Requirements

```sh
npm test                                   # all suites
node --test bridge/test/direct.test.js     # one suite
```

These run in CI on `macos-latest` as the gate for both halves of a release.

### Common Patterns

- `node:test` (`test`, `before`, `after`) with `node:assert/strict`. No test
  framework, matching the zero-dependency rule.
- Test names are sentences describing the guarantee ("a minted code can be
  claimed exactly once"), not method names.
- Fixture builders (`line.near(id)`, `spaceUser(id, name, x, y)`) at the top of
  the file, assertions below.

## Dependencies

### Internal

`../lib/server.js`, `../lib/game-protocol.js`, `../lib/presence.js`,
`../lib/direct.js`, `../lib/desktop-notifications.js`, `../lib/gather-auth.js`,
`../lib/msgpack.js`, `../lib/pairing.js`, `../lib/qr.js`.

### External

Node builtins only.

<!-- MANUAL: -->
