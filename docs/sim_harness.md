# Simulator mock harness — multi-party call & spotlight

A second `flutter run` target that boots straight into a **scripted multi-party
call** on the iOS simulator — no login, no WebRTC, no Gather backend. Use it to
watch and drive the call screen (and the `feature/call-spotlight` big-view auto
mode) without standing up a real room full of people.

It is the gather equivalent of `beacon_manager`'s `example/lib/main.dart` harness.

## What it is

| File | Role |
|------|------|
| `lib/main_harness.dart` | Entrypoint. Builds `AppState`, attaches a `ScriptedCall`, starts the driver, mounts `CallScreen` as the home route. |
| `lib/harness/scripted_call.dart` | `ScriptedCall implements Call` — a drivable fake: `emit(CallState)` and `speak(bool)`, every hardware/SFU method a recorded no-op. |
| `lib/harness/harness_data.dart` | The fake cast and the roster/participant builders. Keeps the one invariant that lights a tile: `CallParticipant.srcId == RosterRow.userAccountId`, all in one `clusterId`. |
| `lib/harness/call_scenarios.dart` | `scenarioFrame()` (pure: time → who's talking) + `CallScenarioDriver` (the timer that pushes each frame into `AppState`). |
| `test/harness/call_scenario_driver_test.dart` | Unit tests for the scenarios and the driver. |

No production file is touched. The harness rides entirely on `AppState`'s existing
`@visibleForTesting` seams (`debugAttachCall`, `debugApplyRoster`) — the same ones
`test/call_screen_test.dart` uses by hand. Tiles are **avatars, not video**: the
call screen only reaches for a texture behind a real `LiveCall`, and the spotlight
logic keys off participants + speaking flags, not pixels.

## Running it

```sh
# list booted simulators
xcrun simctl list devices booted

flutter run -t lib/main_harness.dart -d <sim-udid> \
  --dart-define=SCENARIO=roundrobin \
  --dart-define=PARTICIPANTS=4
```

- `SCENARIO` — one of the names below (default `group`).
- `PARTICIPANTS` — how many of the cast to seat, 1–8 (default `4`).

### Scenarios

| `SCENARIO` | What it exercises |
|------------|-------------------|
| `solo` | Just me. Spotlight has nobody to follow — the empty baseline. |
| `pair` | Me + 1, talking in 2.5s bursts. |
| `group` | N people, nobody talking. Manual-mode grid at rest. |
| `roundrobin` | Each person holds the floor 3s in turn. **Auto mode should follow, one promotion per turn, no jump.** |
| `debate` | Two speakers: one holds, the other talks over without stealing (sticky), then the first stops and the second earns it. |
| `briefnoise` | Blips shorter than the 1.5s dwell. **Auto mode must stay on the overview** — the cough / chair-scrape rejection test. |
| `churn` | People join and leave mid-call. Tiles and the strip track it; the spotlight target survives or re-floors. |

The dwell the auto spotlight gates on is **1.5s** (`SpotlightDirector.dwell`);
scenario timings are chosen around it.

> **Spotlight note.** The big-view auto mode lives on `feature/call-spotlight`
> (worktree `../gather_companion-spotlight`). The harness files only use public
> seams, so they build on any branch — but to *exercise spotlight* run from that
> branch. On launch the screen opens in **Manual**; tap the header toggle to
> **Auto** to see the scenario drive the big view.

## Driving it with `idb` (autonomous taps + screenshots)

Same loop as `beacon_manager` — describe the accessibility tree, tap by
coordinate, screenshot to verify.

**One-time install** (from `beacon_manager/AGENTS.md`):

```sh
# client — MUST be system python 3.9, not 3.14 (fb-idb 1.1.7 calls
# asyncio.get_event_loop(), a hard error on 3.14). Lands in ~/Library/Python/3.9/bin.
/usr/bin/python3 -m pip install --user fb-idb

# companion (third-party tap — trust the source when brew prompts)
brew tap facebook/fb
brew install idb-companion
```

**Invocation gotcha:** if `asdf` is on PATH its `idb` shim dies with *"No version
is set for command idb"*, and its `python3` shim resolves to 3.14 (which fb-idb
1.1.7 cannot run). Call the real binary directly:

```sh
IDB=~/Library/Python/3.9/bin/idb
```

**The loop:**

```sh
SIM=<sim-udid>
$IDB ui describe-all --udid $SIM                 # dump AXLabels + frames
$IDB ui tap --udid $SIM <X> <Y>                  # tap in LOGICAL points
xcrun simctl io $SIM screenshot /tmp/shot.png    # verify (pixels)
```

Verified end-to-end on an iPhone 17 Pro sim: `--dart-define=SCENARIO=roundrobin`
boots the call with four avatar tiles + a live speaking ring; tapping **Auto**
promotes the active speaker into the big view with the strip below.

**Coordinate units:** `idb ui tap` takes **logical points**; `simctl` screenshots
are **pixels** (×3 on a 3× device, so `point = px / 3`). Read coordinates straight
from `describe-all` frames to skip the math.

### Targets on the call screen

These widgets carry stable keys/labels (see `call_screen.dart`), so `describe-all`
finds them:

- **Mode toggle** — the `Manual` / `Auto` segmented pill in the header
  (`_ModeToggle`, segment labels `"Manual"` / `"Auto"`). Tap `Auto` to hand the
  big view to the scenario.
- **A face** — grid tiles key `ValueKey(<tile.id>)`; in the big view the strip
  tiles key `ValueKey('strip-<tile.id>')` and the enlarged face
  `ValueKey('big-<tile.id>')`. Tapping a face enlarges (manual) or pins it (auto).
- **`Everyone`** — the return button (`_OverviewButton`, label `"Everyone"`) back
  to the grid.

### What to check

- `roundrobin` + Auto: the big view follows each talker, promotes once per turn,
  doesn't jump between speakers.
- `debate` + Auto: the holder keeps the floor while talked over; handover only
  after they stop and the other clears the dwell. No thrash.
- `briefnoise` + Auto: the big view never appears — every blip is under the dwell.
- Manual: tap the toggle to `Manual`, tap a strip/grid face → it enlarges; tap
  `Everyone` → back to the grid.
