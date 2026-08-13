<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-05 | Updated: 2026-08-05 -->

# ui

## Purpose

The screens. Each file holds one public entry point plus the private
widgets it composes — there is no shared widget library, because nothing has
needed to be shared twice yet.

`home_shell.dart` is the one exception to "one file, one screen": it holds the
three tabs together and is what the app shows once it is paired.

## Key Files

| File | Description |
|------|-------------|
| `home_shell.dart` | `HomeShell` — the three destinations and the rail between them. `_Tab`, `_TabView`, `_Dock`, `_NavItem`. Activity, the office, settings, left to right, opening on Activity. **`_Tab`'s declaration order is the only place that order lives**: the rail and the `IndexedStack` are both built by walking `_Tab.values`, because they were once hand-written as parallel lists and reordering the enum alone silently swapped two tabs' bodies. All three tabs sit in an `IndexedStack` so the map keeps its decoded artwork, its pan and zoom, and its already-played opening shot; each is wrapped in a `TickerMode` so the ones behind are kept without being kept *running*. `AppState.positions` is merged in only while the map is the selected tab. The rail floats over the content rather than docking under it, and the shell adds `kRailInset` to the bottom of every tab's `MediaQuery` padding so each tab's existing `SafeArea(top: false)` clears it without knowing a rail exists. The dock's width never drops below `kRailMinWidth` (320): left to its intrinsic width the nav row alone was a 180-point pill, and the island lurched sideways whenever the office's control row came or went. |
| `activity_screen.dart` | The activity tab: `_History`, which is Gather's *own* activity feed: `_ActivityTile`, `_Glyph`, `_NoHistory`, `_withDayHeaders`. Before the first read answers, `_Skeleton` — bones cut to the real rows' measurements, gated on `AppState.activityFetched` so "nothing yet" is only ever said once it has been checked; a fetched-and-empty feed and a failed fetch stay two different sentences in `_NoHistory`. Waves, mentions, reactions, thread replies and "your meeting notes are ready", read over REST from `../../packages/gather_client/lib/src/activity_feed.dart` and topped up by `WaveEvent` off the socket, so nothing polls; grouped by day, because the list spans months. Pull-to-refresh reads the feed and nothing else — it used to also drop the socket, whose only visible effect was the link strip announcing the reconnect the pull had caused; the strip is gone and the settings tab owns up to a dead connection instead. Mark-all-read is the double-check icon in the app bar, words in its tooltip. Only the subscription-backed kinds are tappable: a memo can be marked read in Gather and a wave cannot — its read state is a chat cursor — so waves show no dot rather than one the screen could not clear. Was `feed_screen.dart` until the rail gave it a name a person would use, and lost its `_TopBar` when the rail and the settings tab took over what was in it. |
| `settings_screen.dart` | `SettingsScreen` — what the app can tell you about itself, and the one switch it owns. `_SectionLabel`, `_Card`, `_Row`, `_PartyRow`, `_PartySwitch`. The connection and the space it is in, a reconnect, party mode, the mic and camera check, the paired computer and whether it can still wake the app, and unpairing. Party mode moved here from the activity tab — it was the one control on a screen of answers — and traded its spinning gradient card for a row with a hand-drawn switch (brand for on; a `Switch` would bring Material's own track colours). Replaced the `PopupMenuButton` on the feed: a menu can only hold verbs, and most of what belongs here is nouns. The `Notifier` flags are deliberately absent until something persists them. |
| `map_screen.dart` | The office, drawn in Gather's own artwork. `_Where`, `_HeadCount`, `_Followers` (the follower count as the head count's accent-tinted sibling pill, absent at zero — moved here from the activity tab), `_Waiting`, `_Plan`, `_Legend`, `_OfficePainter`, plus the `officePainter()` and `framedOn()` test seams. Floors, walls, furniture and avatars, sorted into one depth order; the old schematic is still underneath for while the art is in flight. People walk rather than hop — see `../src/map_motion.dart` — except when they teleport, which is drawn as a teleport: the body dissolves where it stood while a new one fades and grows into place at the destination, two entries in the same depth list so each folds behind the right desk. They are otherwise drawn on the client's own animation table: the walk cycle while they are mid-step, `idle-sit` on a chair, the talking loop while they are speaking. Labels are Gather's own capsules: a name plate above each head with an availability dot, and the ten **team** zones named above themselves — the fourteen meeting rooms are deliberately not written on the floor, since the one you are standing in is already in the app bar. Covers the screen at minimum zoom and cannot be panned off it (`boundaryMargin: EdgeInsets.zero`, and `framedOn` clamps the transforms the screen sets itself); opens centred on you at 3×, pinch/double-tap to 20×. Built by `home_shell.dart` on `Listenable.merge([state, state.positions])` while it is the selected tab; `state` alone leaves it frozen, because walking changes nothing the presence tracker reports. Its body is deliberately not in a `SafeArea` — the floor runs under the home indicator and under the nav rail — while the D-pad, the *Go to* pill and the legend are, which is how they lift clear of the rail without this file knowing about it. **Tapping the floor picks somewhere to go**, and `_GoTo` is the pill that acts on it. The split is Gather's own: on the desktop a single click only highlights and a *double* click moves, so a tap and a button are the two beats of that gesture with a phone's missing hover put back. Which of the two a tap means is `navigatesToTile`, transcribed — the main floor, the lobby and a team's corner select a *tile*, and a meeting room, a desk or a coworking area selects the whole *room*, because "go to the Boardroom" is what somebody means. `_walkableNear` forgives a near miss by a radius that widens as the map zooms out, since a tile is eight points across with the whole floor on screen. `_paintSelection` draws the reticle: four black corner brackets, Gather's own shape (`immersive-tile-highlighter-tl.png`), sized as a *proportion of the tile* with the on-glass figures acting only as ceilings — an earlier version held them to a minimum size on the glass and zoomed out that inflated the mark to over twice the tile it was marking. Static, unlike Gather's, which lerps between tiles and fades after three seconds: `MapMotion`'s ticker stops itself when nobody is moving, and a selection that faded out from under the button still waiting on it would be incoherent. |
| `control_bar.dart` | `ControlBar` — Gather's own bottom bar, adapted: you (tap for the status sheet), your microphone, your camera, the eight reactions, a raised hand, and leaving the conversation you are in. Undecorated rows, because `home_shell.dart`'s `_Dock` paints the island both it and the navigation sit in. `kControlBarInset` is what the map tab pays for it. Gather's screen-share and its *leave* door are deliberately absent — there is nothing on a phone worth sharing, and the socket this app holds **is** its presence, so a door out of the space would switch the product off; `leaveCluster` is the honest replacement. Mic and camera drive a real capture session through `../src/media/call.dart` and publish to the SFU. |
| `status_sheet.dart` | `showStatusSheet()` — Active / Busy / Away, and the line of text under your name. Both halves read back off the roster and are authoritative. The status line was an echo of what this phone last sent until `SpaceUserStatus` was tracked; the join runs from that row's own `spaceUserId`, because `SpaceUser.activeCustomStatusId` and `activeUserGeneratedStatusId` are never set on anybody. What comes back may be one **Gather** wrote from a calendar rather than one you typed. |
| `person_avatar.dart` | `PersonAvatar` — somebody's profile picture over a coloured initial, with an optional availability dot. The one shared widget in this directory, and the bar for adding another is that something is genuinely wanted twice: the control bar draws you, the activity tab draws whoever waved. The initial is drawn first and always, because roughly half a space has no picture (45 of 98 measured) — so a photo that is loading, expired or missing lands on a finished avatar instead of a hole. |
| `dpad.dart` | `DPad` — the pad that walks your own avatar, floating over the lower half of the map. **Currently shelved**: `kShowDPad` is `false`, so the map never mounts it — the pad, its walk plumbing and its tests all stay live, and bringing it back is flipping that one constant. Tapping a tile is what moves you now, and the two share one `Walk`: pressing a direction cancels a route in flight, so the pad coming back does not mean two things steering one avatar. One `Listener` rather than four buttons, so rolling a thumb from one quarter to the next changes direction without the walk ever stopping; the hub in the middle is how you stop without lifting. Each direction owns a full quarter of the disc, split on the same diagonals the hit test uses, so what you aim at is what you get. `../../packages/gather_client/lib/src/walk.dart` does the stepping. |
| `pair_screen.dart` | Camera pairing. `_Header`, `_Viewfinder`, `_CornersPainter`, `_CameraUnavailable`, `_Hint`, `_Command`. Opens the camera immediately and keeps the typed route available throughout. |
| `media_check_screen.dart` | `MediaCheckScreen` — mic and camera, before you need them. `_Preview`, `_Message`, `_Controls`, `_Toggle`. Talks to no server; it opens the hardware, draws it and lets go. Owns an `RTCVideoRenderer`, which is why it is stateful: the texture must be initialised before use and disposed with the widget, and `srcObject` is cleared *before* the engine stops the tracks under it. Three distinct states — starting, permission denied, no camera — because a refused permission is fixed in Settings and a busy camera is not, and neither is a spinner. |
| `type_code_dialog.dart` | `showTypeCode()` — a modal sheet with two fields (code and address), plus `UpperCaseFormatter`. The route when the camera is refused, unavailable, or on desktop. |

## For AI Agents

### Working In This Directory

- **A control that cannot do anything is absent, not dimmed.** The conversation
  button appears when there is a conversation to leave and goes with it; the
  camera flip appears once there is a camera running. This is the same rule the
  D-pad follows for its own visibility, and it is why nothing in the control bar
  is ever greyed out — a bar whose buttons keep changing which of them work is
  one you stop trusting.
- **Off is a colour; pressed is not.** A muted microphone is crossed out in
  `t.danger`, matching the media check and Gather itself. That is a *state*, and
  states are allowed a colour. The D-pad's rule — pressed is a step of opacity,
  never a different paint — is about a control being *pushed* and still holds.
- **Every action answers.** Everything on the control bar and the status sheet
  returns `Future<String?>` — null on success, a sentence on failure — and the
  sentence goes to a `SnackBar`. That is the contract `AppState.setPartyMode`
  set. A tap that silently does nothing is the one outcome not allowed.

- **The history the activity tab shows is Gather's, never the phone's.** The
  app's own `EventLogStore` was deleted and must not come back: it could only
  record what happened while the app was open, which is the one window in which
  the user was already looking, so it was empty exactly when it mattered. That
  was an argument against a log *this app keeps*, not against a history — the
  list under the cards is read from Gather over REST and was there while the
  phone was asleep. `_SectionLabel`, `_EventRow`, `_EmptyFeed` and
  `_BackgroundToggle` are gone for good.
- **The activity tab is a record, not a status board.** The follower card and
  the party switch both started here and both left — party mode to settings,
  the follower answer to the office's app bar (`_Followers` in
  `map_screen.dart`) — because live presence pinned over a history is stale a
  minute later and in the way of the record. The link strip left last — its
  main occasion to appear was the pull-to-refresh reconnect, which is also
  gone. Do not grow cards back above the feed.
- `CustomScrollView` needs `AlwaysScrollableScrollPhysics` or the screen — now
  shorter than the viewport — cannot be over-scrolled, and pull-to-refresh
  silently does nothing.
- **`_PartyRow` (settings) renders the snapshot, never its own memory.** The
  bridge stops party mode by itself — on its 15-minute timer, when it loses
  Gather, when the daemon exits — so a switch holding local state would keep
  glowing through all three. `AppState.partyMode` reads the local party mode
  directly, so a tap is flight, and that override is cleared by the snapshot
  that agrees with it rather than by the HTTP response, because the two race.
  The spinning gradient card this used to be on the activity tab is gone —
  do not bring an animation to the settings screen with it.
- **The follower badge does not hedge, and does not say zero.** Follow state
  comes off the app's own Gather socket, so the badge is authoritative while
  the socket is up — there is no degraded tier left to admit to. It is absent
  when nobody follows rather than reading "0": zero is the permanent normal
  state, and a pill saying so all day is furniture. Same geometry as the head
  count beside it, tinted `brandSoft` at 0.12 fill / 0.3 border.
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
- **Selected is a colour, though.** That rule is about a control being *pushed*; a
  nav item is a control that is *in a state*, so `_NavItem` follows the media
  check's toggles instead and uses `t.brand` on a `t.secondary` plate. The plate is
  what stops three loose glyphs on a floating bar reading as decoration.
- **Tabs are kept alive, and that is a cost as well as the point.** Anything with a
  ticker or a subscription behind a tab keeps running unless something stops it —
  `TickerMode` covers clocks, but a new tab holding hardware or a stream must
  handle its own. `MediaCheckScreen` is pushed from settings rather than made a
  tab for exactly this reason: it opens the camera in `initState` and would hold
  it forever behind another tab.
- **A screen inside a tab does not add bottom padding of its own.** The shell has
  already put the rail's height into `MediaQuery.padding.bottom`, so
  `SafeArea(top: false)` or `MediaQuery.paddingOf(context).bottom` is the way to
  clear it. Hard-coding the rail's height in a second place is how the two drift.

### Testing Requirements

```sh
flutter test test/home_shell_test.dart test/activity_screen_test.dart \
             test/settings_screen_test.dart test/map_screen_test.dart test/dpad_test.dart
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
