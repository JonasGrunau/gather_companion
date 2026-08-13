<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-05 | Updated: 2026-08-05 -->

# ui

## Purpose

The screens. Each file holds one public entry point plus the private
widgets it composes — there is no shared widget library, because nothing has
needed to be shared twice yet.

## Key Files

| File | Description |
|------|-------------|
| `feed_screen.dart` | The main screen. `_TopBar`, `_LinkStrip`, `_AroundYou`, `_PartyCard`, `_FollowerCard`, `_PersonChip`, `_Avatar`. Answers "is anyone following me" from the snapshot, and carries the party switch. Named for the scrolling activity feed it used to have; the name outlived it. |
| `map_screen.dart` | The office, drawn in Gather's own artwork. `_Where`, `_HeadCount`, `_Waiting`, `_Plan`, `_Legend`, `_OfficePainter`, plus the `officePainter()` and `framedOn()` test seams. Floors, walls, furniture and avatars, sorted into one depth order; the old schematic is still underneath for while the art is in flight. People walk rather than hop — see `../src/map_motion.dart` — except when they teleport, which is drawn as a teleport: the body dissolves where it stood while a new one fades and grows into place at the destination, two entries in the same depth list so each folds behind the right desk. They are otherwise drawn on the client's own animation table: the walk cycle while they are mid-step, `idle-sit` on a chair, the talking loop while they are speaking. Labels are Gather's own capsules: a name plate above each head with an availability dot, and the ten **team** zones named above themselves — the fourteen meeting rooms are deliberately not written on the floor, since the one you are standing in is already in the app bar. Covers the screen at minimum zoom and cannot be panned off it (`boundaryMargin: EdgeInsets.zero`, and `framedOn` clamps the transforms the screen sets itself); opens centred on you at 3×, pinch/double-tap to 20×. Opened by `feed_screen.dart` on `Listenable.merge([state, state.positions])`; `state` alone leaves it frozen, because walking changes nothing the presence tracker reports. |
| `dpad.dart` | `DPad` — the pad that walks your own avatar, floating over the lower half of the map. One `Listener` rather than four buttons, so rolling a thumb from one quarter to the next changes direction without the walk ever stopping; the hub in the middle is how you stop without lifting. Each direction owns a full quarter of the disc, split on the same diagonals the hit test uses, so what you aim at is what you get. `../../packages/gather_client/lib/src/walk.dart` does the stepping. |
| `pair_screen.dart` | Camera pairing. `_Header`, `_Viewfinder`, `_CornersPainter`, `_CameraUnavailable`, `_Hint`, `_Command`. Opens the camera immediately and keeps the typed route available throughout. |
| `media_check_screen.dart` | `MediaCheckScreen` — mic and camera, before you need them. `_Preview`, `_Message`, `_Controls`, `_Toggle`. Talks to no server; it opens the hardware, draws it and lets go. Owns an `RTCVideoRenderer`, which is why it is stateful: the texture must be initialised before use and disposed with the widget, and `srcObject` is cleared *before* the engine stops the tracks under it. Three distinct states — starting, permission denied, no camera — because a refused permission is fixed in Settings and a busy camera is not, and neither is a spinner. |
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
- **Labels are laid out on the glass, not on the map.** The type size is fixed and
  the canvas is scaled down to place it, rather than the size being computed against
  the zoom. Sized against the zoom, a name's `TextPainter` key changed on every frame
  of a pinch and the cache became a cache of one frame — a hundred people re-laid-out
  sixty times a second.
- **The map repaints off `Listenable.merge`, not off `setState`.** The art cache, the
  viewer transform and `MapMotion` all drive the painter directly; a footstep must not
  rebuild the widget tree. `MapMotion`'s ticker stops itself when nobody is moving or
  talking, so an office standing still costs no frames.
- **No arrow on the D-pad is ever greyed out.** An earlier version dimmed the
  directions that led into a wall, using the same rule that decides whether the step
  is sent. It read as a fault: the arrows flickered between live and dead as you
  walked past doorways, and a control that keeps changing which parts of it work is
  one you stop trusting. You find a wall the way you find one in any game — by
  walking into it and stopping.
- **The pad is only shown when it can actually drive something** (`AppState.canWalk`:
  a live collector *and* a tile to judge steps from). A pad that does nothing cannot
  be told apart from a broken one. `debugCanWalk` is the seam, since knowing where you
  are takes a real roster.
- **Pressed is a step of opacity, not a colour.** The brand blue was tried on the held
  quarter and made the pad look like it was reporting something rather than being
  pushed; a heavier dark read as a hole cut in the disc.

### Testing Requirements

```sh
flutter test test/feed_screen_test.dart test/map_screen_test.dart test/dpad_test.dart
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
