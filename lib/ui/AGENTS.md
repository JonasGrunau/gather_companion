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
| `feed_screen.dart` | The main screen. `_TopBar`, `_LinkStrip`, `_AroundYou`, `_PartyCard`, `_FollowerCard`, `_PersonChip`, `_Avatar`. Answers "is anyone following me" from the snapshot, and carries the party switch. Named for the scrolling activity feed it used to have; the name outlived it. |
| `map_screen.dart` | The office, drawn. `_Waiting`, `_Plan`, `_Key`, `_PlanPainter`. A floor plan rather than a game view — at 124 tiles across a phone there are about three pixels a tile, so it is blocks of colour, pannable and zoomable. |
| `pair_screen.dart` | Camera pairing. `_Header`, `_Viewfinder`, `_CornersPainter`, `_CameraUnavailable`, `_Hint`, `_Command`. Opens the camera immediately and keeps the typed route available throughout. |
| `type_code_dialog.dart` | `showTypeCode()` — a modal sheet with two fields (code and address), plus `UpperCaseFormatter`. The route when the camera is refused, unavailable, or on desktop. |

## For AI Agents

### Working In This Directory

- **The screen only says what it can currently answer.** It used to be a snapshot
  card over a scrolling history. The history is gone — once the app talked to
  Gather itself, the log only recorded what happened while the app was open, so it
  was empty exactly when it mattered. Push notifications carry that job now.
  `_SectionLabel`, `_EventRow`, `_EmptyFeed` and `_BackgroundToggle` went with it.
- `CustomScrollView` needs `AlwaysScrollableScrollPhysics` or the screen — now
  shorter than the viewport — cannot be over-scrolled, and pull-to-refresh
  silently does nothing.
- **`_PartyCard` renders the snapshot, never its own memory.** The bridge stops
  party mode by itself — on its 15-minute timer, when it loses Gather, when the
  daemon exits — so a button holding local state would keep glowing through all
  three. `AppState.partyMode` now reads the local party mode directly, so a tap is
  flight, and that override is cleared by the snapshot that agrees with it rather
  than by the HTTP response, because the two race.
- **The gradient animates only while it is actually hopping.** This is the one
  moving thing in an interface that otherwise deliberately sits still, which is
  what makes it read as a status light rather than as decoration; the controller
  is stopped when the card is off, and `MediaQuery.disableAnimationsOf` is
  honoured.
- **The follower card no longer hedges.** It used to carry a "log-only mode"
  notice for when the bridge could only tail the desktop log and had to guess at
  being followed. The app reads follow state from its own Gather socket now, so
  there is no degraded tier left to admit to: either the socket is up and the
  card is authoritative, or the link strip already says it is not.
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

`../src/app_state.dart`, `../src/pairing.dart`,
`../src/link_status.dart`, `../theme/gather_theme.dart`,
`package:gather_events`.

### External

`mobile_scanner` (pair screen only), `flutter/material`, `flutter/services`.

<!-- MANUAL: -->
