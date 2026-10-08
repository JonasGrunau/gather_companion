# In-app test plan — spotlight & office, driven by the sim harness

Run on the iOS simulator through `lib/main_harness.dart` (no network, no WebRTC,
no Gather backend). Each row is one scenario launch; verify with `idb` taps +
`simctl` screenshots. Gates: `SpotlightDirector.dwell = 1.5s`, `linger = 5s`.

## Call target (`TARGET=call`) — spotlight behaviour

| # | Scenario | Mode | Steps | Expected |
|---|----------|------|-------|----------|
| C1 | `solo` | Auto | Launch, flip to Auto | Only "You" tile. Big view never appears — nobody to follow. No crash on empty room. |
| C2 | `pair` | Auto | Launch, flip to Auto, watch 2 cycles (3.5s each: 2.5s on / 1s off) | Speaker clears 1.5s dwell → promoted to big view. Stays big through the 1s silence gap (< 5s linger). No drop to grid between bursts. |
| C3 | `group` | Manual | Launch (opens Manual), tap a grid face, tap `Everyone` | N avatar tiles, no speaking rings. Tapping a face enlarges it; `Everyone` returns to grid. Resting baseline. |
| C4 | `roundRobin` | Auto | Launch, flip to Auto, watch ≥ N×3s | Each talker holds 3s (2× dwell) → big view follows, **one promotion per turn, no jump mid-turn**. Handoff is face-replaces-face, no grid flash. |
| C5 | `debate` | Auto | Launch, flip to Auto, watch a 12s cycle | A holds (0–5s) → A big. B talks over (5–7s) → **A keeps it (sticky)**. A stops, B holds (7–12s) → B earns it only after dwell. No thrash. |
| C6 | `briefNoise` | Auto | Launch, flip to Auto, watch ≥ 5s | Blips are 800ms < 1.5s dwell → **big view never appears**. Grid stays. Cough/chair-scrape rejection. |
| C7 | `churn` | Auto | Launch, flip to Auto, watch people leave/rejoin | Tiles + strip track join/leave. Spotlight target survives, or re-floors cleanly when its holder leaves. No stale tile, no crash. |

## App target (`TARGET=app`) — whole-app presence

| # | Scenario | Steps | Expected |
|---|----------|-------|----------|
| A1 | `office` | Launch, check Activity, open Office, tap an empty tile → "Go here" | Activity opens first: seeded waves + live wave ~5s, unread badge. Office draws schematic floor + ghost avatars milling. Tap-to-walk moves "You" (real `Walk` vs `FakeCollector`). |
| A2 | `still` | Launch, open Office | Resting floor, nobody moves. Seeded activity present, no live churn. One clean frame. |

## Method
- `flutter run -t lib/main_harness.dart -d <udid> --dart-define=TARGET=… --dart-define=SCENARIO=… --dart-define=PARTICIPANTS=4`
- `idb ui describe-all` → tap `Auto` / faces / `Everyone` by frame coords (logical points).
- `simctl io <udid> screenshot` (pixels, ÷3 on 3× device) at each checkpoint.
- Record PASS/FAIL + screenshot per scenario.
