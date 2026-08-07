<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-05 | Updated: 2026-08-05 -->

# ui

## Purpose

The three screens. Each file holds one public entry point plus the private
widgets it composes — there is no shared widget library, because nothing has
needed to be shared twice yet.

## Key Files

| File | Description |
|------|-------------|
| `feed_screen.dart` | The main screen. `_TopBar`, `_LinkStrip`, `_AroundYou`, `_PartyCard`, `_FollowerCard`, `_PersonChip`, `_Avatar`, `_SectionLabel`, `_EventRow`, `_BackgroundToggle`, `_EmptyFeed`. Answers "is anyone following me" at the top from the snapshot, history underneath. |
| `pair_screen.dart` | Camera pairing. `_Header`, `_Viewfinder`, `_CornersPainter`, `_CameraUnavailable`, `_Hint`, `_Command`. Opens the camera immediately and keeps the typed route available throughout. |
| `type_code_dialog.dart` | `showTypeCode()` — a modal sheet with two fields (code and address), plus `UpperCaseFormatter`. The route when the camera is refused, unavailable, or on desktop. |

## For AI Agents

### Working In This Directory

- **The split in `feed_screen.dart` is the design.** The top answers a question
  you have *right now*, straight from the bridge's snapshot, so it is correct
  even if the app was closed when it happened. The list underneath is history and
  carries only what is worth reading; the ambient tier sits behind
  "Show N background events".
- `CustomScrollView` needs `AlwaysScrollableScrollPhysics` or a short feed cannot
  be over-scrolled and pull-to-refresh silently does nothing on a quiet screen.
- **`_PartyCard` renders the snapshot, never its own memory.** The bridge stops
  party mode by itself — on its 15-minute timer, when it loses Gather, when the
  daemon exits — so a button holding local state would keep glowing through all
  three. `AppState.partyMode` overrides the snapshot only while a tap is in
  flight, and that override is cleared by the snapshot that agrees with it rather
  than by the HTTP response, because the two race.
- **The gradient animates only while it is actually hopping.** This is the one
  moving thing in an interface that otherwise deliberately sits still, which is
  what makes it read as a status light rather than as decoration; the controller
  is stopped when the card is off, and `MediaQuery.disableAnimationsOf` is
  honoured.
- **An empty feed has two different meanings** and must say which: "nothing has
  happened" versus "not connected". `_EmptyFeed` reads `AppState.link` and
  `isPriming` to tell them apart, and there is a test for each.
- **A degraded bridge is admitted in the UI.** When `hasRichData` is false the
  screen says being-followed cannot be detected, so a quiet screen is never
  mistaken for "nobody is following me". It now means the bridge has no Gather
  session or its socket is down, rather than the old log-only mode. A healthy
  bridge does not nag. Both are tested.
- `pair_screen.dart` opens the camera without asking first: the screen is only
  ever reached when there is a computer to pair with, so a confirmation tap sits
  in front of the only thing anyone came here for. The instruction goes *under*
  the frame — the person who already ran the command needs the viewfinder, the
  person who has not needs the sentence.
- The scanner is configured for `BarcodeFormat.qrCode` and
  `DetectionSpeed.noDuplicates` only, and `_claiming` gates the detector while a
  claim is in flight. A reader that reacts to every label in the room is noise.
- `mobile_scanner` is mobile-only. Any desktop target must fall back to
  `showTypeCode`, which is a first-class route, not a consolation.
- Colours come from `context.tokens` — never a literal `Color` and never
  `Theme.of(context).colorScheme` directly.

### Testing Requirements

```sh
flutter test test/feed_screen_test.dart
```

Widget tests drive real screens through `AppState`'s debug seams. Being followed
requires a colleague to actually follow you around a real space, so the follower
card would otherwise never be seen in development — that is why it is pinned by a
test.

Wrap screens in the real theme (`buildGatherTheme()`) in tests; the widgets read
`context.tokens` and will throw without it.

### Common Patterns

- `final t = context.tokens;` as the first line of `build`.
- Private `StatelessWidget`s over helper methods, so Flutter can rebuild them
  independently.
- Copy is written as sentences a person would say, and states limitations
  plainly rather than hiding them.

## Dependencies

### Internal

`../src/app_state.dart`, `../src/relevance.dart`, `../src/pairing.dart`,
`../src/bridge_client.dart`, `../theme/gather_theme.dart`,
`package:gather_events`.

### External

`mobile_scanner` (pair screen only), `flutter/material`, `flutter/services`.

<!-- MANUAL: -->
