<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-05 | Updated: 2026-08-05 -->

# src

## Purpose

The models. `events.dart` is the stream (things that happened); `presence.dart`
is the snapshot (what is true right now). The bridge sends both over the same
socket, distinguished by the frame's `kind`.

## Key Files

| File | Description |
|------|-------------|
| `events.dart` | `sealed class GatherEvent` plus ten subclasses, and the `EventSource` / `Confidence` / `MediaTrack` enums. |
| `presence.dart` | `PlayerRef`, `SelfState`, `CollectorHealth`, `PartyState`, `PresenceSnapshot` — the `kind: 'snapshot'` frame. |

## The event hierarchy

| Class | Wire `type` |
|---|---|
| `FollowEvent` | `follow.started` / `follow.stopped` |
| `PlayerSpaceEvent` | `player.joinedSpace` / `player.leftSpace` |
| `MediaChangedEvent` | `media.changed` |
| `MediaConnectionEvent` | `media.connection` |
| `ChatMessageEvent` | `chat.message` |
| `SelfChangedEvent` | `self.changed` |
| `SpaceChangedEvent` | `space.changed` |
| `NotificationShownEvent` | `notification.shown` |
| `BridgeStatusEvent` | `bridge.status` |
| `RawEvent` | anything unrecognised |

## For AI Agents

### Working In This Directory

- **`EventSource` and `Confidence` are the honesty mechanism.** `log` means ids
  only, no names and no coordinates; `cdp` means the high-fidelity collector was
  attached. `inferred` versus `observed` tells the UI whether to say "guessed
  from movement" or state it plainly. Preserve them on every new event type.
- **`RawEvent` is the escape hatch that keeps the feed lossless.** Unknown `type`
  values decode into it rather than throwing, so a bridge newer than the app
  degrades gracefully. Do not tighten `fromJson` into a strict parse.
- Both parse helpers use `firstWhere(..., orElse:)` and default to the safe
  option (`EventSource.bridge`, `Confidence.observed`).
- `PlayerRef.label` is the display rule the whole app relies on: name if known,
  otherwise the first 8 characters of the uuid. `name` is null in log-only mode —
  treat it as optional everywhere.
- **`PlayerRef` is deliberately not a position.** It carries who somebody is and
  whether they are following you, and nothing about where they are standing.
  Proximity was removed on purpose; do not reintroduce `isNear`, `distance` or
  coordinates to make a UI easier.
- `CollectorHealth.gather` is now the app's *own* connection to Gather, not a
  report about the bridge's. `cdp` is a dead field kept only because
  `hasRichData` reads `gather || cdp` and a bridge older than the app still sets
  it; `logTail` is likewise vestigial and gates nothing.
- `NotificationShownEvent.senderId` carries who did it, for the kinds that come
  off Gather's event bus or its meeting state. A wave scraped from the desktop
  log could never say — the IPC line has only a type — which is why it is nullable
  and why the fallback wording is "Someone".
- `CollectorHealth.hasRichData` is what the UI reads to decide whether to admit
  the follow-detection limitation. It is not decoration.
- `copyWith` on `PlayerRef` carries an explicit `clearFollowingMeSince` flag,
  because null cannot mean both "unchanged" and "cleared".

### Testing Requirements

Covered indirectly by the app's tests, which construct these models directly:

```sh
flutter test
```

A new event type should arrive with a case in `notifications.dart` asserting its
tier, since the classification switch is where the analyzer will demand it.

### Common Patterns

- One class per wire type, each with `type`, `summary`, `payload()`, and an
  optional `playerId` override.
- `library;` directive with a file-level doc comment at the top of each file.
- `const` constructors on the presence models; events hold a `DateTime` so they
  cannot be.

## Dependencies

### Internal

Exported by `../gather_events.dart`. Mirrors `bridge/lib/events.js` and the
snapshot shape from `bridge/lib/presence.js` (`newPlayer()`, `emptySelf()`).

### External

None. Plain Dart, no Flutter import.

<!-- MANUAL: -->
