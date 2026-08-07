<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-05 | Updated: 2026-08-05 -->

# test

## Purpose

Flutter tests for the app. Three files, three levels: the classification rules in
isolation, the feed screen as a widget, and one optional end-to-end test against
a real running bridge.

## Key Files

| File | Description |
|------|-------------|
| `relevance_test.dart` | The feed's editorial policy — which events are alerts, which are notable, which are background — plus the pairing-code and address parsers. The most specified file in the app. |
| `feed_screen_test.dart` | Widget tests for the one thing the screen exists to say: who is following you, and which of them is talking. Also empty states, the background-tier toggle, the fidelity notice, and the refresh duration. Builds `AppState` with `EventLogStore.disabled()`: the real one debounces its writes on a `Timer`, and a timer outliving the widget tree fails the test outright. |
| `live_bridge_test.dart` | End-to-end against a real bridge, exercising the app's own pairing and client code rather than mocks. **Skipped unless configured**, so `flutter test` stays green on a machine with no Gather on it. |

## For AI Agents

### Working In This Directory

- **Use the debug seams, not fakes.** `AppState.debugApplySnapshot`,
  `debugApplyEvent` and `debugApplyLink` are `@visibleForTesting` for exactly this
  reason — the tests drive the real state object.
- **Being followed cannot be produced on demand.** It needs a colleague to
  actually follow you around a real space, so without these tests the follower
  card would only ever be seen by accident. That is why it is pinned here.
- **An empty feed has two meanings** and both are tested: "all quiet" versus "not
  connected". Do not let a change collapse them.
- Screens must be wrapped in `buildGatherTheme()`; they read `context.tokens` and
  throw without it.
- Test names are sentences stating the guarantee ("a quiet feed with no link says
  'not connected', not 'all quiet'"). Keep that style — they are the readable
  index of what the UI promises.

### Running the live test

```sh
node bridge/bin/gather-bridge.js run --port 7830 --token t --log-file /tmp/f.log &
node bridge/bin/gather-bridge.js pair --port 7830   # note the code
GATHER_TEST_PORT=7830 GATHER_TEST_CODE=XXXXXXXX flutter test test/live_bridge_test.dart
```

Without all three environment variables the test skips itself. CI does not run
it.

### Testing Requirements

```sh
flutter analyze && flutter test
```

Both are the release gate — the npm and TestFlight jobs are blocked on them. The
bridge has its own separate suite; see `../bridge/test/AGENTS.md`.

### Common Patterns

- Fixture builders at the top (`snapshotWith`, `stateWith`, a fixed
  `DateTime(2026, 8, 4, 12, 30)`), assertions below.
- `group()` by concern, `testWidgets` for screens, plain `test` for pure logic.
- No mocking package.

## Dependencies

### Internal

`package:gather_companion/...` (the app's own libraries) and
`package:gather_events`. `live_bridge_test.dart` additionally needs the Node
bridge running.

### External

`flutter_test`.

<!-- MANUAL: -->
