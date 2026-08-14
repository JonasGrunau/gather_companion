# Gather V2 wire protocol, as observed

Everything below was read off two live GatherV2 desktop clients on 2026-08-14,
app version 0.48.4 (Electron 40.6.0, Chromium 144). Nothing here is carried over
from other documents in this repo — where this file and another disagree, this
file records what the wire actually did.

Statements are limited to what appeared in the capture. Where a field was present
but its meaning was not exercised, it is listed as present and unexercised rather
than guessed at.

## How it was captured

Two desktop instances, each with its own Chromium profile and its own remote
debugging port, signed into different accounts:

| Instance | Port | Account | Role in space |
| --- | --- | --- | --- |
| A | 9222 | `grunaujonas@gmail.com` | Admin |
| B | 9333 | `grunauluca@gmail.com` | Member |

Both were in space `bfe5d402-3a4c-4988-a3e8-b2a760371c14`. Frames were taken from
CDP `Network.webSocketFrameSent` / `…Received`, decoded with msgpack for binary
opcodes, and written to JSONL. B was reloaded at capture start so its connection
handshake was recorded from the first frame; A was left alone and therefore shows
only steady state.

A known stimulus was then applied: B's avatar was driven with four held arrow
keys (Right, Down, Left, Up, 1.2 s each) via `Input.dispatchKeyEvent`. That is
what makes the cross-client section below a correlation rather than a guess — the
cause was chosen, not observed after the fact.

Capture sizes: A 177 frames, B 239 frames, over 70 s.

## Three sockets

A client runs three WebSockets concurrently. They are separate connections with
separate lifecycles and separate identity schemes.

| Socket | Transport | Carries |
| --- | --- | --- |
| `wss://game-router.v2.gather.town/gather-game-v2` | msgpack over binary frames | game state, movement, actions |
| `wss://router.v2.gather.town/socket.io/?EIO=4` | socket.io v4, text | SFU node discovery |
| `wss://sfu-v2.<region>.prod.aws.gather.town/<node>/socket.io/?EIO=4` | socket.io v4, text | media negotiation |

The game socket carries its identity in the URL query:

```
wss://game-router.v2.gather.town/gather-game-v2
  ?spaceId=bfe5d402-3a4c-4988-a3e8-b2a760371c14
  &authUserId=G12514TRcvRMMcTUPVfYeocWuyg2
```

The SFU URL embeds the node's private address (`/ip-10-206-194-73`) and a
`sessionId` query parameter distinct from the socket.io `sid`.

## Identity: three separate id spaces

This is the single most consequential thing in the capture. The same human has
three different identifiers, and each socket uses a different one. Confusing them
is the most likely source of a bug that only shows up with two participants.

| Id space | Example (Luca) | Example (Jonas) | Where it is used |
| --- | --- | --- | --- |
| Firebase auth id | `G12514TRcvRMMcTUPVfYeocWuyg2` | `MD7q4DyAwbYysRYzRDPgKuxdu6w1` | game socket `authUserId` query, `Connection.authUserId` |
| `UserAccount.id` | `4f981673-cb83-49df-9c28-adb64e53e792` | `d3edd4b0-3fd7-43d6-bafb-c76090d43c81` | **SFU and router `srcId`** |
| `SpaceUser.id` | `1fdcb187-851f-46bc-b02f-b0157594c757` | `75ac8eb3-82e4-4318-9d3f-ba49304004b5` | every game-plane patch and action target |

So a participant's avatar is addressed by `SpaceUser.id`, but their media is
addressed by `UserAccount.id`. The link between them is `SpaceUser.userAccountId`,
which is present on every `SpaceUser` record. `srcStreamId` on the media plane is
the **space id**, not a per-user value.

## Game plane

### Message types

Sent by the client:

| Type | Fields |
| --- | --- |
| `Authenticate` | `credential: {type: "JWT", jwt}` |
| `ConnectToSpace` | `spaceId`, `connectionData` |
| `Subscribe` | *(no fields beyond `type`)* |
| `Action` | `txnId`, `action`, `args` |
| `Heartbeat` | `timestamp`, `sequenceNumber`, `origin` |

Received from the server:

| Type | Fields |
| --- | --- |
| `SpaceStatus` | `warmInGatewayServer`, `warmInLogicServer` |
| `FullStateChunk` | `fullStatePatches`, `actionReturns`, `events`, `optimisticAckTxnIds`, `chunkConfig`, `sequenceNumber` |
| `DeltaState` | `patches`, `actionReturns`, `events`, `optimisticAckTxnIds`, `sequenceNumber` |
| `Heartbeat` | `timestamp`, `origin` |

`FullStateChunk` and `DeltaState` share an envelope; the only difference is
`fullStatePatches` + `chunkConfig` versus `patches`.

### Connection order

Observed exactly once, on B's reload:

```
→ Authenticate      {credential: {type: "JWT", jwt: "<redacted>"}}
→ ConnectToSpace    {spaceId, connectionData: undefined}
→ Subscribe         {}
← SpaceStatus       {warmInGatewayServer: true, warmInLogicServer: undefined}
← FullStateChunk    842 patches, sequenceNumber 124
← DeltaState        …continuous from there
```

`chunkConfig` was `{id, chunkIndex: 0, totalChunks: 1}` — chunking exists in the
envelope but this space fit in one chunk, so multi-chunk assembly was not
exercised.

### Action envelope

```jsonc
{
  "type": "Action",
  "txnId": "2d21b2fd-5150-4757-aaef-d8d9dedced4c",   // client-generated uuid
  "action": "move",                                   // method name, a string
  "args": ["SpaceUser", "1fdcb187-…", { "direction": "Right" }]
}
```

`args` is positional and consistently shaped as
`[modelName, modelId | null, params?]`. `modelId` is null for calls that create
or address something not yet identified.

Every action B sent during the capture:

| Action | n | `args` |
| --- | --- | --- |
| `move` | 36 | `["SpaceUser", <id>, {direction}]` |
| `reportActivity` | 9 | `["Connection", null, {isActive}]` |
| `updateActiveApp` | 2 | `["SpaceUser", <id>, "Gather"]` |
| `loadSpaceUser` | 1 | `["SpaceUser", null, {connectionTarget: "OfficeView", invitationId, spawnAreaId, clientPlatform: "Desktop"}]` |
| `createSubscription` | 1 | `["ModelSubscription", null, {modelKey, subscriptionType: "Include", modelIds: []}]` |
| `enterSpace` | 1 | `["SpaceUser", <id>]` |
| `getAuthenticationData` | 1 | `["SpotifyOAuthUserSecret", null]` |
| `markContextualOnboardingPOICompleted` | 1 | `["SpaceUserOnboarding", <id>, "SimplifiedView"]` |

`direction` took the string values `Right`, `Down`, `Left`, `Up` — 9 of each,
matching the four 1.2 s key holds.

### Acknowledgement

Every action is acknowledged twice in the same envelope family:

```jsonc
"optimisticAckTxnIds": ["2d21b2fd-…"],
"actionReturns": [{
  "connectionId": "e93d909c-…",
  "txnId": "2d21b2fd-…",
  "result": { "type": "Success", "value": "1fdcb187-…" }
}]
```

All 52 acknowledged txnIds matched a txnId the client had sent — a clean 1:1
correspondence with no unmatched or duplicated acks in the capture. `result.type`
was `Success` in every case; no failure result was provoked, so the error shape is
unknown.

### Events — the transient channel

`events[]` sits on the same envelope as `patches[]` but carries things that
change no persistent state. Invoking `throwConfetti()` produced, on the *peer's*
socket, one `DeltaState` with an event and **no patches at all**:

```jsonc
{
  "payload": {
    "eventName": "ConfettiThrown",
    "senderSpaceUserId": "1fdcb187-…",
    "x": 35, "y": 29,
    "direction": "Up"
  },
  "options": {
    "targetUserIds": ["75ac8eb3-…", "1fdcb187-…"]   // includes the sender
  }
}
```

Two structural consequences. Ephemeral interactions — confetti, waves, emotes —
are **not** discoverable by diffing state; a client that only applies patches
will silently ignore every one of them. And unlike patches, an event names its
recipients explicitly in `options.targetUserIds`, sender included, so delivery is
addressed rather than broadcast to everyone in the space.

### Patch shape

```jsonc
{ "op": "replace", "model": "SpaceUser", "id": "1fdcb187-…",
  "path": "/position/x", "data": 42 }

{ "op": "addmodel", "model": "SpaceUser", "data": { …whole record… } }
```

`addmodel` carries a whole record and no `path`; `replace` carries a JSON-Pointer
path and a scalar or tagged value. Only these two ops appeared — deletion and
insertion were not exercised.

Values that are not plain scalars are tagged with `$type`. Tags observed:
`Position`, `Direction`, `Speed`, `Dimensions`, `SpaceUserAvailability`. So
`direction` is `{"$type": "Direction", "value": "Right"}`, not a bare string,
while `position/x` is a bare number.

### Initial state contents

The 842-patch `FullStateChunk` was entirely `addmodel`, covering 27 model types.
The bulk is static catalogue data, not per-session state:

| Model | n | | Model | n |
| --- | --- | --- | --- | --- |
| `CatalogItem` | 569 | | `ChatMessage` | 4 |
| `CatalogItemVariant` | 136 | | `SpaceUser` | 2 |
| `SpaceTemplate` | 61 | | `UserAccount` | 2 |
| `MapEntityIdentifier` | 24 | | `ActivityEvent` | 2 |
| `Wearable` | 13 | | `Connection` | 1 |
| `ChatChannelMember` | 4 | | `Space`, `Floor`, `FloorMap`, … | 1 each |

Catalogue data alone is 83.7 % of the patches, and 91.0 % once templates are
included — the per-session state is a small tail on a large static payload. Both
`SpaceUser` records were delivered to B, including the admin's — a client sees
every participant's full record, not a filtered view.

### The `SpaceUser` record

Fields present on a live `SpaceUser` (values from the admin's record):

```jsonc
{
  "id": "75ac8eb3-…", "name": "grunaujonas", "coreRole": "Admin",
  "spaceId": "bfe5d402-…", "userAccountId": "d3edd4b0-…",
  "position": {"$type": "Position", "x": 41, "y": 29},
  "direction": {"$type": "Direction", "value": "Up"},
  "floorId": "9b758980-…",
  "speed": {"$type": "Speed", "modifier": 1},
  "userSetAvailability": {"$type": "SpaceUserAvailability", "value": "Active"},
  "connected": true, "isIdle": false, "speaking": false, "dancing": false,
  "isBot": false, "type": "Regular",
  "clusterId": undefined, "followTargetId": undefined,
  "shouldBeInClusterWithFollowTarget": false,
  "currentTargetMeetingAreaId": undefined,
  "shouldBeInClusterWithOthersWithSameTargetMeetingArea": false,
  "deskId": "38eb2075-…", "deskAssignmentStatus": undefined,
  "activeApp": undefined, "handRaisedAt": undefined,
  "activeMapObjectInteractionId": undefined,
  "profilePictureId": undefined, "aiSummary": undefined,
  "numTimesEnteredSpace": 1, "lastOnlineAt": "…", "firstBecameMemberAt": "…",
  "createdAt": "…"
}
```

Note what is **absent**: there is no camera, microphone, or video field. Whether a
participant is sending media is not represented in the game plane at all — it is
only knowable from the media plane. `speaking` exists, but is a separate boolean
from whether a stream is being produced.

`clusterId` is `undefined` when not in a conversation, so it is a nullable field
rather than one that is always present.

### The `Connection` model

```jsonc
{ "id": "de72932f-…", "spaceId": "bfe5d402-…",
  "authUserId": "G12514TRcvRMMcTUPVfYeocWuyg2",   // Firebase id, not UserAccount.id
  "spaceUserId": "1fdcb187-…", "entered": false, "target": "Default",
  "clientPlatform": "Unknown", "isActive": false,
  "studioUserSessionId": undefined, "lastActiveAt": undefined }
```

This is the record that ties the Firebase identity to the `SpaceUser`.

## Cross-client correlation

The point of two clients: while B's avatar was driven, A received, on the game
socket, 36 `DeltaState` messages inside the drive window, carrying only these
paths, all on `SpaceUser` id `1fdcb187-…` (B's id):

| Path | n |
| --- | --- |
| `/direction` | 36 |
| `/position/y` | 14 |
| `/position/x` | 12 |

A representative message A received:

```jsonc
{ "type": "DeltaState",
  "patches": [
    {"op": "replace", "model": "SpaceUser", "id": "1fdcb187-…",
     "path": "/direction", "data": {"$type": "Direction", "value": "Right"}},
    {"op": "replace", "model": "SpaceUser", "id": "1fdcb187-…",
     "path": "/position/x", "data": 42}
  ],
  "actionReturns": [], "events": [], "optimisticAckTxnIds": [],
  "sequenceNumber": 142 }
```

**`/direction` is emitted on every move, but position only on the moves that were
allowed** — 36 direction patches against 26 position patches (`x` 12, `y` 14) for the
same 36 moves.

The ten-patch gap was read as turns-in-place when this was written. It is not: the
model refused those ten. `move`'s body assigns `direction` and then calls
`setPosition`, which returns false without writing anything when
`isBlockedBy(map, prevPosition)` — and `gameMove` sends every held-key step without
checking first, so leaning on a wall produces exactly this signature. The mechanism is
in [`gather-api.md`](../gather-api.md#move-is-collision-checked-and-the-check-is-inside-setposition);
the correction was made 2026-08-15 from the bundle, not from a new capture.

**Acknowledgements are strictly private to the originating client.** A also sent
7 actions of its own during the capture, and its socket received exactly 7
`actionReturns` and 7 `optimisticAckTxnIds` — all 7 matching its own txnIds, none
matching any of B's 52. B likewise received 52 acks, all its own. Across both
captures there was no cross-contamination in either direction. So a client is
told the outcome of its own actions and only its own; another participant's
actions are visible solely as resulting state patches. Observing what someone
else *did* is not possible — only what changed as a result.

Across the whole 70 s capture, every patch path A received was:

| Path | n | | Path | n |
| --- | --- | --- | --- | --- |
| `/direction` | 36 | | `/lastActiveAt` | 3 |
| `/position/y` | 14 | | `/connected` | 2 |
| `/position/x` | 12 | | `/lastOnlineAt` | 2 |
| `/isActive` | 6 | | `/numTimesEnteredSpace` | 1 |
| `/updatedAt` | 5 | | `/completedContextualOnboardingPOIs/5` | 1 |
| `/activeApp` | 3 | | | |

`/completedContextualOnboardingPOIs/5` shows that array elements are patched by
index, so paths are not restricted to scalar object fields.

## Driving the UI, and why it is a poor map

Both clients' interfaces were driven systematically: every visible control
clicked, menus recursed two levels deep, keyboard shortcuts `1`–`6`, `z`, `x`,
`f`, `g`, `e` pressed, on both the Member and the Admin account — about 95
interactions in total.

**Nine of the 261 catalogued actions ever reached the wire — 3.4 %.**

| Interaction | Action produced |
| --- | --- |
| number keys `1`–`6` | `broadcastEmote` |
| `gather-chat-channels-nav`, `calendar-view-nav`, `sidebar-search-header`, `Invite` | `markContextualOnboardingPOICompleted` |
| `desktop-toolbar` | `updateActiveApp` |
| holding an arrow key | `move` (~142 ms cadence) |
| connect / enter | `loadSpaceUser`, `enterSpace`, `createSubscription`, `getAuthenticationData` |
| idle / focus change | `reportActivity` |

Most of the interface is local MobX state: of 45 controls clicked in the first
sweep only 4 produced any traffic, and opening panels, switching tabs and
toggling the mic and camera buttons produced no game-plane action at all.

The lesson is that the UI is not a map of the protocol. Coverage is bounded by
the account's permissions, by feature flags, and by state the session happens to
be in — and you cannot tell from the outside which actions you failed to reach.

## Asking the server directly

A far better instrument, and the one that produced the `events[]` finding above.
Model instances expose their actions as methods — `Repos.gameSpace.currentSpaceUser`
carries 123 of them — so an action can be invoked without any UI, and the
returned promise settles with the server's own verdict:

```js
await Repos.gameSpace.currentSpaceUser.throwConfetti();   // resolves — action ran
await Repos.gameSpace.currentSpaceUser.sendWave();
//   → MethodActionError: Cannot wave at yourself
await Repos.gameSpace.currentSpaceUser.faceDirection('Sideways');
//   → MethodActionError: [{ received: "Sideways", code: "invalid_enum_value",
//                           options: ["Up","Down","Left","Right"], … }]
```

Errors come back in two useful flavours. Business-logic refusals arrive as prose
(*"Cannot wave at yourself"*), and schema violations arrive as **structured zod
issues that enumerate the valid domain** — the second example reveals the
complete `MoveDirection` enum without reading any source.

That gives a safe way to harvest argument schemas: call an action with
deliberately wrong arguments and the server describes what it wanted. Validation
fails before the action runs, so nothing happens as a side effect. The caveat is
that an action taking **no** arguments has nothing to fail on and will simply
execute — `throwConfetti()` did — so zero-argument actions must be classified
before they are probed, not swept blindly.

## Router socket — SFU discovery

socket.io v4. Handshake, then one round trip per participant whose media is
wanted:

```
← 0{"sid":"UomPabktkMVb5kDPAKR8","upgrades":[],"pingInterval":5000,"pingTimeout":10000,"maxPayload":1000000}
→ 40{"spaceId":"bfe5d402-…","token":"<redacted>"}
← 40{"sid":"Hnl1GGjE6pH1AqVlAKR9"}
→ 420["get-addr",{"srcId":"4f981673-…","srcStreamId":"bfe5d402-…"}]
→ 421["get-addr",{"srcId":"d3edd4b0-…","srcStreamId":"bfe5d402-…"}]
← 42["addrs",{"srcId":"4f981673-…","sfuAddr":"wss://sfu-v2.eu-central-1-a.prod.aws.gather.town:443/ip-10-206-194-73","distance":424.146}]
← 430[{"addrFound":true}]
← 431[{"addrFound":false}]
```

`srcId` is the **`UserAccount.id`**, and `srcStreamId` is the space id. A
`get-addr` is issued per participant — including one for the client's own account
— and each gets an independent ack. `addrFound` was `true` for one and `false`
for the other in the same capture, so a participant having no assigned SFU node
is a normal, expected answer rather than an error.

`sfuAddr` arrives as a full `wss://host:443/ip-10-…` string: scheme and port
included, with the node path appended. `distance` (424.146) accompanies it.

## SFU socket — media negotiation

Same socket.io v4 framing, separate connection to the node named by `addrs`:

```
← 0{"sid":"EDn9WtNoHKW2xMs2AEcW",…}
→ 40{"spaceId":"bfe5d402-…","token":"<redacted>"}
← 40{"sid":"wqX884qWqO8KnAKFAEcX"}
→ 420["get-rtp-capabilities",{"wsSequenceNumber":1}]
← 430[{"routerRtpCapabilities":{"codecs":[{"kind":"audio","mimeType":"audio/opus","clockRate":48000,"channels":2,…}]}}]
→ 42["consume-request",{"wsSequenceNumber":2,"zodData":{"srcId":"d3edd4b0-…","srcStreamId":"bfe5d402-…",…}}]
→ 42["consume-allow",{"wsSequenceNumber":3,"zodData":{"dstId":"d3edd4b0-…","allowed":true}}]
← 42["consume-try",{"srcId":"d3edd4b0-…","srcStreamId":"bfe5d402-…","producerIdMap":{}}]
```

Observations that matter:

- Payloads are wrapped in a **`zodData`** envelope on the way out, but arrive
  **unwrapped** on the way back — `consume-try` has `srcId` at the top level while
  `consume-request` nests it. The asymmetry is real, not a transcription slip.
- Every client→server message carries a monotonic **`wsSequenceNumber`**,
  independent of the game plane's `sequenceNumber`.
- `consume-allow` uses **`dstId`**, while `consume-request` uses `srcId` — both
  are `UserAccount.id` values, but the field name changes with direction.
- `producerIdMap` was `{}` here, because neither client was publishing media
  during the capture. It is the field that would name available producers.
- The codec list is mediasoup `routerRtpCapabilities`, audio Opus 48 kHz stereo
  first.

## Timing

| Thing | Value |
| --- | --- |
| Game `Heartbeat` cadence, client→server | median 4.6 s (min 0.36 s, max 6.2 s) |
| socket.io `pingInterval` / `pingTimeout` | 5 s / 10 s (both router and SFU) |
| `move` action cadence while a key is held | median 142 ms (min 130 ms) |
| Moves per 1.2 s key hold | 9 |

At ~142 ms per step, a held key produces about 7 actions per second.

## Two gotchas worth knowing

**`Heartbeat.origin` reads backwards.** The frame the client sends carries
`origin: "Server"`; the frame the client receives carries `origin: "Client"`.
Whatever the field is meant to denote, it is not the sender. Do not use it to
work out which way a heartbeat travelled — use the frame direction.

```jsonc
→ sent: {"type":"Heartbeat","timestamp":1786659713501,"sequenceNumber":121,"origin":"Server"}
← recv: {"type":"Heartbeat","timestamp":1786659713113,"origin":"Client"}
```

**The client's heartbeat `sequenceNumber` echoes the server's stream.** Server
`sequenceNumber` ran 124 → 178, strictly increasing across the capture with no
gaps or repeats. The client's outgoing `Heartbeat.sequenceNumber` ran 121 → 178
and converged on the same value, so it is reporting the last sequence it has
seen rather than counting its own sends. Only the received frames carry `origin`
without `sequenceNumber`.

## What this capture does not cover

This file records one 70-second session. For the *complete* surface — all 261
WebSocket actions and all 243 HTTP endpoints the client can call, extracted from
the shipped bundles rather than from traffic — see
[`client-action-surface.md`](./client-action-surface.md). The 8 actions seen here
are a small sample of that catalogue.

Gaps in this capture, stated so they are not mistaken for absences in the
protocol:

- **No media was published**, so `producerIdMap` was always `{}`, and the
  produce/transport-create path never ran.
- **No conversation was joined**, so `clusterId` stayed `undefined` and no
  clustering traffic appeared.
- **No action failed**, so `result.type` other than `Success` was never seen.
- **Multi-chunk `FullStateChunk`** did not occur (`totalChunks: 1`).
- `chat`, `screenshare`, `follow`, and `teleport` were not exercised.

## Reproducing

The rig is documented in [`two-instance-rig.md`](./two-instance-rig.md); its
scripts live outside this repo in `~/.gather-alt/` (`gather-alt.sh` to run extra
isolated instances, `record.mjs` to capture, `drive.mjs` to apply a stimulus).
Raw captures for this document were `cap-9222.jsonl` and `cap-9333.jsonl`. The
method as a whole — which instrument answers which question, and which ones
turned out to answer nothing — is in
[`how-it-was-mapped.md`](./how-it-was-mapped.md).

A second instance needs nothing but its own `--user-data-dir` and
`--remote-debugging-port`: Electron keeps its single-instance lock inside the
user-data-dir, so a separate directory is a separate lock, and the Firebase
session lives in that directory's IndexedDB.
