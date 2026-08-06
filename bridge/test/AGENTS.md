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
| `bridge.test.js` | End-to-end: boots a real `BridgeServer` on a temp log file, appends real log lines to it, and reads the results over a real WebSocket. Covers auth, snapshot-then-events framing, and `?since=` catch-up. |
| `game-protocol.test.js` | The largest suite. Model patches (`addmodel` / `deletemodel` / `replace`), both envelope keys, identity resolution via `Connection` and via `UserAccount`, component-wise position updates, teleports, follow detection, bot filtering — feeding `GameProtocolReader` into `PresenceTracker`. |
| `log-parser.test.js` | Every regex, against verbatim log lines. Includes the participant-vs-player id-namespace trap. |
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
- `msgpack.test.js`'s `enc()` helper is deliberately test-only. Do not promote it
  into `lib/` — the bridge never writes to Gather's socket, and an encoder in the
  shipped tree would invite someone to.

### Testing Requirements

```sh
npm test                                   # all suites
node --test bridge/test/log-parser.test.js # one suite
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
`../lib/log-parser.js`, `../lib/msgpack.js`, `../lib/pairing.js`, `../lib/qr.js`.

### External

Node builtins only.

<!-- MANUAL: -->
