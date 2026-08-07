# gather_events

**The wire contract between `gather-app-bridge` and Gather Companion.**

Every event the bridge publishes and every field of the presence snapshot, as a
sealed Dart hierarchy the app can switch over exhaustively.

Plain Dart — no Flutter dependency, and no runtime dependencies at all. Local to
the [gather_companion](../../README.md) repository and not published to pub.dev.

---

## Why it exists

The bridge is Node and the app is Dart, so the same contract is written twice:
once in [`bridge/lib/events.js`](../../bridge/lib/events.js) and once here. There
is no code generation and no shared schema file — the two sides are kept in step
by hand.

Putting the Dart half in its own package rather than in `lib/src` buys one thing:
it cannot accidentally reach for Flutter. The models stay usable outside a widget
tree, and tests over them are fast.

> [!IMPORTANT]
> Renaming a field is a two-sided change. The bridge will keep emitting the old
> name with no error and the app will silently decode nulls. Change
> `bridge/lib/events.js`, this package, and the event-type list in the root
> README together.

## Usage

```dart
import 'package:gather_events/gather_events.dart';
```

Frames arrive from the bridge's WebSocket as JSON, discriminated by `kind`:

```dart
switch (frame['kind']) {
  case 'snapshot':
    final snapshot = PresenceSnapshot.fromJson(frame['snapshot']);
  case 'event':
    final event = GatherEvent.fromJson(frame['event']);
}
```

`GatherEvent` is sealed, so a `switch` over it is exhaustive and the analyzer
points at every place that needs updating when a type is added:

```dart
final line = switch (event) {
  FollowEvent(targetIsSelf: true, started: true, :final followerId) =>
    '$followerId started following you',
  NotificationShownEvent(:final notificationType) => 'Gather: $notificationType',
  _ => event.summary,
};
```

Every event carries `at`, `source` and `confidence`, plus `type` and `summary`
getters and a `payload()` / `toJson()` pair that round-trips it back to the wire.

## The events

| Class | Wire `type` | Notes |
|---|---|---|
| `FollowEvent` | `follow.started` · `follow.stopped` | `targetIsSelf: true` is the one that matters — you are being followed. The only people-signal the bridge still emits. |
| `NotificationShownEvent` | `notification.shown` | A notification Gather itself raised: a wave, a meeting invite, an event reminder. |
| `PlayerSpaceEvent` | `player.joinedSpace` · `player.leftSpace` | Roster churn. |
| `MediaChangedEvent` | `media.changed` | `MediaTrack.audio` / `video` / `screen`, plus `paused`. |
| `MediaConnectionEvent` | `media.connection` | Transport state. Mostly noise. |
| `ChatMessageEvent` | `chat.message` | |
| `SelfChangedEvent` | `self.changed` | Your own mic, camera, screenshare and in-office state. |
| `SpaceChangedEvent` | `space.changed` | |
| `BridgeStatusEvent` | `bridge.status` | A collector came up or went quiet. |
| `RawEvent` | *anything else* | The forward-compatibility escape hatch. |

## The snapshot

`PresenceSnapshot` is what the bridge sends on connect and whenever state changes
materially, so the app can paint a correct first frame without replaying history.

| Type | What it holds |
|---|---|
| `PresenceSnapshot` | `self`, `players`, `health`, `at` — plus a `followers` convenience filter |
| `PlayerRef` | One other person: `isFollowingMe`, `followingMeSince`, `name`, `speaking` |
| `SelfState` | Your own id, space, device state and `followingPlayerId` |
| `CollectorHealth` | Which collectors are live, and `hasRichData` |

`PlayerRef.label` is the display rule the whole app relies on: the display name if
one is known, otherwise the first eight characters of the uuid.

## Fidelity, stated rather than assumed

Two enums exist so the app can say *how* it knows something instead of presenting
a guess as a fact.

**`EventSource`** — which collector saw it:

| | |
|---|---|
| `log` | Parsed from the desktop client's log file. Always available, but ids only — never names or coordinates. |
| `cdp` | Read from the live renderer over the Chrome DevTools Protocol. Names, coordinates, explicit follow state. |
| `bridge` | The bridge itself: status and derived events. |

**`Confidence`** — how well it knows it:

| | |
|---|---|
| `observed` | Read directly from authoritative state or an explicit protocol signal. |
| `inferred` | Derived from a proxy signal — historically, movement standing in for following. |

The app surfaces that difference in words: an inferred follow says *"guessed from
movement"*. Nothing emits `inferred` any more — following is read from
`SpaceUser.followTargetId`, which means exactly what it says — but the enum stays
because older bridges on people's machines still send it.

## Forward compatibility

Decoding is deliberately forgiving, because the phone and the computer are
updated independently and a bridge is often newer than the app it is talking to:

- An unrecognised `type` decodes to `RawEvent` rather than throwing, so a new
  event still renders in the feed instead of crashing it.
- `EventSource.parse` and `Confidence.parse` fall back to `bridge` and `observed`
  rather than failing on an unknown value.
- Missing fields decode to null or a documented default.

Do not tighten `fromJson` into a strict parse. Rendering one event as a plain
line is a small problem; a feed that dies on an unknown string is a large one.

## Adding an event type

1. Add the constructor in `bridge/lib/events.js` and emit it from a collector.
2. Add the subclass here, and a `case` in `GatherEvent.fromJson`.
3. Run `flutter analyze` — the exhaustive switch in the app's `lib/src/notifications.dart` will
   fail, telling you exactly where the app has to decide how the event reads and
   which tier it belongs to.
4. Add a case pinning the title and body it produces.
5. Update the event-type list in the root README.

## Tests

The package has no suite of its own; it is exercised through the app, which
constructs these models directly:

```sh
flutter test
```

---

MIT, same as the rest of the repository.
