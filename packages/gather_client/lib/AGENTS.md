# `gather_client` — Gather V2's protocol, spoken from the phone

**Pure Dart — no Flutter.** That is the property to protect: this package runs
inside a Flutter app but contains none of it, so `dart test` exercises the whole
thing in seconds with no device, no simulator and no plugin registry.

It used to have **no dependencies at all** beyond `gather_events`, and that is no
longer true: `socket_io_client` arrived with `sfu_signalling.dart`, because
Gather's media plane is Socket.IO rather than the game socket's msgpack. It is a
pure-Dart package, not a Flutter plugin, so the testability property survives
intact — but the bar for the *next* dependency should stay exactly where it was.
msgpack, the WebSocket server, the QR encoder and the PNG encoder are all still
hand-rolled for good reasons.

This is a port of the bridge's own collector. The bridge still runs its copy (for
push), so **two implementations of one wire format exist and must not drift.** When
you change something here, look at the JS twin named in the table.

| File | Twin | What it is |
|---|---|---|
| `msgpack.dart` | `bridge/lib/msgpack.js` | Decoder for everything Gather sends, incl. 5 ext types. Shallow encoder for the 5 frames we send. |
| `game_protocol.dart` | `bridge/lib/game-protocol.js` | `GameProtocolReader` — patch fold over 6 of ~49 models, **plus `DeltaState.events[]`**, plus `MeetingWatch` for invites and knocks. |
| `gather_auth.dart` | `bridge/lib/gather-auth.js` (half) | `GatherAuth` — Firebase token exchange, `recent-spaces`. No IndexedDB half: the phone is *given* a refresh token at pairing. |
| `direct_collector.dart` | `bridge/lib/direct.js` | `DirectCollector` — handshake, `enterSpace`, heartbeat, 250ms roster coalescing, `teleport`, `move`, backoff, `describeClose()`, and the `_silenceLimit` deaf-socket watchdog. The watchdog and the close-code wording are ports and must not drift: `SILENCE_LIMIT_MS` / `_silenceLimit`, `describeClose` on both sides. |
| `presence_tracker.dart` | `bridge/lib/presence.js` | The fold → `PresenceSnapshot` + `GatherEvent`s. Owns the wave cooldown. |
| `activity_feed.dart` | *(no counterpart)* | `ActivityFeed` + the `ActivityItem` hierarchy — Gather's own activity feed, over **REST**, not the socket. `GET /chat/activity-feed` answers `application/x.gather.msgpack`, so `msgpackDecode` reads it and `GatherHttp.getBytes` exists because `getJson` would mangle it. The body is normalised like a state dump: id lists per kind plus a model store, so `parseActivityFeed` is a set of joins — a wave's actor is on `ChatMessageMetadata`, not on the message, and read state is `ActivityEventSubscription.readAt`, not on the event. There is no pagination; every query param is ignored. `markRead` is **JSON** (the response is still msgpack — the endpoint is not symmetric), names the *event* id rather than the subscription that carries `readAt`, sends one request per item because no batch form exists, and is a **toggle** with no `read: true` — so filtering to unread items is correctness, not an optimisation, or "mark all read" un-reads most of the list. All four were guessed wrong before being captured off the desktop client; the shapes are in `../../../docs/gather-api.md#marking-activity-read`. **Waves and activity events are measured; the mention, reaction and reply joins are not** — no space available had one, so each degrades to `UnknownActivity` rather than throwing. The bridge has no counterpart because push already covers what it would use this for. |
| `sfu_signalling.dart` | *(no counterpart)* | `SfuSignalling` — the media plane's Socket.IO transport: CONNECT auth, ack-keyed `sendWithResponse`, the `{wsSequenceNumber, zodData}` envelope, server-push notifications, backoff. The bridge will never speak to the SFU. |
| `party.dart` | *(deleted from the bridge)* | `PartyMode`. Lives only here now — the app holds the socket, and two parties driving one avatar would fight. Draws its tiles from `space_map.dart`. |
| `space_art.dart` | *(no counterpart)* | `SpaceArt` / `ArtGround` / `ArtFloor` / `ArtWall` / `ArtSprite`, and the URL rules for Gather's floor, wall and furniture art. **Transcribed from the client bundle.** Gather ships no tileset: this is the list of images to fetch and where each one goes, 573 of them totalling 222 KB on the measured space. Note the two depths a wall can have — the sides are `ArtWall` in `ground`, while the north and south bands are `ArtSprite`s in `props`, because `ensureImmersiveWalls` gives them depths of their own. |
| `profile_photos.dart` | *(no counterpart)* | `ProfilePhotos`. Turns a `SpaceUser.profilePictureId` into a URL you can load, which takes a REST call: the `UserFile` rows **are** in the state dump and all three of their URL fields come across msgpack-undefined on every row, and the bucket refuses an unsigned request. `GET /spaces/:id/files/:fileId` answers a CloudFront signature valid 24 hours that needs **no** authorization header — which is why this hands back a URL rather than bytes. Cached hard, failures included: the map draws a hundred faces and rebuilds four times a second. |
| `avatar.dart` | *(no counterpart)* | `hashOutfit` / `avatarSpriteUrl` / `avatarAnimation` / `AvatarAnimation` / `avatarFrame` / `Facing` / `Pose`. The sprite service composites an outfit into one 72-frame sheet; the "hash" is the wearable ids joined with dots plus a timestamp, and getting its order or format wrong is a 404 rather than a wrong-looking person. The animation table is `Ae` from the client, transcribed with its frame rates: walking at 7fps, talking at 4, a still pose declared as one frame at 60. |
| `space_map.dart` | *(no counterpart)* | `SpaceMap` / `SpaceRoom` / `SpaceMapBuilder` — the floor plan. **Transcribed from Gather's client bundle**, not inferred: every rule names the getter it came from. Answers "which tiles can I stand on" (`walkable`), "where may a party go" (`open`, which also drops walled areas), "may I take *this* step" (`canStep` / `canPassThrough` — walls are lines between tiles, not tiles), "what is this room called" and "is somebody standing here sitting down" (`isSeat` — `playerState` never reaches the wire, so it is derived from the chair). `artFor()` builds the drawable scene from the same rows. Also "how do I walk there" (`routeTo`) and "where do I stand when the answer is a whole room" (`tilesClosestTo`), both transcribed from the client's own pathfinder — see below. `isPublicWalkway` and `navigatesToTile` are its two area predicates, top-level rather than methods because they are pure functions of `mapAreaType`. |
| `walk.dart` | *(no counterpart)* | `Walk` — all of movement. Repeats `move` at Gather's own walking pace while a direction is held, applies `SpaceMap.canStep` to every step, and tracks its own tile because the roster is always two steps behind a walk. `follow(route)` is the other half: the tapped-destination walk, stepping a route from `SpaceMap.routeTo` to its end. **One stepper, deliberately** — a route and a held D-pad driving the same avatar would fight, so `press` cancels a route outright. The route is held as *tiles* rather than as directions, so each step re-derives its direction from wherever the roster says we actually are, and a correction that puts us somewhere the route does not pass through ends the walk instead of blindly applying the rest of it. |

## Things that will bite you

- **`msgpack_test.dart` pins the encoder's bytes against hex generated by the JS
  encoder.** Not pedantry: Gather does not reject a malformed handshake, it goes
  silent and keeps heartbeating, so a divergence looks like a network fault. If those
  fixtures fail, the phone has stopped being able to connect and you have a few
  minutes' warning instead of a bug report.
- **A whole-number `double` encodes as an integer**, because `Number.isInteger(3.0)`
  is true in JS and Dart has a separate `int`. Remove that and the two encoders
  disagree on any coordinate that arrived as a double.
- **`msgpackUndefined` is not `null`.** Gather's optional columns arrive as ext-4
  undefined, and *absent* `followTargetId` (nobody is followed) differs from *null*
  (explicitly cleared). `RosterRow.followTargetKnown` carries the distinction; without
  it the app renders a confident "nobody is following you" out of missing data.
  `clusterId` is the second such column and `clusterIdKnown` is its flag — the
  stakes there are opening a call with nobody in it, or never opening one.
- **`enterSpace` is sent here, and only here.** It puts an avatar in the room and
  permanently increments `numTimesEnteredSpace`, so it is not free — but the app
  publishes media, and a thing that publishes is present. `DirectCollector` sends
  it in the handshake when `/users/me/recent-spaces` supplied our `spaceUserId`,
  and otherwise as soon as the `Connection` row names us (`_maybeEnter`), once per
  connection. **The JS twin `bridge/lib/direct.js` must never grow these frames** —
  that divergence is the one exception to the never-drift rule, and
  `bridge/test/direct.test.js` guards it.
- **Never use `emitWithAckAsync` on the SFU sockets.** `socket_io_client`
  dispatches an ack with `Function.apply(ack, args)`, so an ack whose payload is
  `[]` calls back with **zero** arguments — and that method's internal callback
  requires one. It throws, the completer never completes, and the call hangs.
  Six of Gather's twelve client calls answer `[]` (`consume-request`,
  `consume-created`, `consume-pause`, `consume-resume`, `consume-set-spatial`,
  `set-player-conversation-metadata`), so half the protocol would stall.
  `sendWithResponse` uses `emitWithAck` with an all-optional callback instead.
- **`GatherAuthException.permanent` is load-bearing.** A revoked refresh token must
  stop retrying and ask for pairing; a 503 must retry silently. Confusing the two
  either strands the user at a spinner or sends them to the pairing screen over a
  dropped packet.
- **A wave's frame has an empty `patches` array.** That is exactly how the event bus
  went unread in the bridge for weeks. `ingest` checks `events[]` *before* patches, and
  a frame understood as an interaction must not land in `unknownFrames`.
- **A dump row is history; only a delta is news.** `MeetingParticipant` rows arrive
  in the state dump as well — 56 in the measured space, four naming us — so
  `ingest` reads `fullStatePatches` and `patches` separately and only the latter can
  produce an invite. Merge them again and every reconnect announces every meeting
  the user has ever been invited to; the collector reconnects whenever the phone
  wakes.
- **Identity can arrive after the rows that need it.** `Connection` is one patch
  among ~1500, so `MeetingWatch` parks anything it cannot judge and
  `resolvePending` re-reads it once `selfId` is known.
- **`PartyMode.tick()` is public** so tests can drive a hundred hops without a
  hundred real quarter-seconds. The timer does nothing but call it. `Walk.step()`
  is public for the same reason.
- **`move` checks nothing server-side.** Its whole body is
  `position += direction.toPositionDelta()`. Every rule about where an avatar may go
  lives in `SpaceMap.canStep`, and anything that sends `move` without asking first
  walks the user through the furniture and out of the building — the office footprint
  is 96×52 of a 124×82 grid and the void around it is walkable as far as the game
  server is concerned.
- **A route obeys two rules, and the second one is not geometry.** `routeTo` is the
  client's `Hh` (bundle module 22795) transcribed, and the part that surprises is
  `isPublicWalkway`: **every `Common`, `MeetingRoom` and `Desk` area is impassable**
  unless the route starts or ends in it. Without that, a walk across the office cuts
  straight through the desks in between — those are usually *unwalled*, so no edge
  stops them and pure geometry says the shortest way to the far side is through
  somebody's booth. The other detail worth keeping is the **−0.001 bonus for
  continuing in the same direction**: every step costs 1, so an L and a staircase are
  the same length and nothing else picks between them. Remove it and routes look
  drunk. Note also that this is not textbook A\* — the came-from map doubles as the
  visited set, so a node is enqueued once and never re-opened. That is transcribed
  too; diverging would put this client on different routes from the desktop one.
- **`SpaceRoom.locked` is a join, not a field.** `isLocked` lives on
  `MapEntityIdentifier` and the area only points at it, which is why that model is in
  `_models`. Nothing server-side enforces a lock — `move` and `teleport` both validate
  nothing — so a client that does not ask walks into a meeting somebody shut the door
  on.
- **Wall collision does not follow the wall art.** `Collisions.addArea` runs its side
  walls the full height of the room; `space_art.dart`'s drawing loop stops three rows
  short because the north and south bands are two tiles tall and cover the corners.
  Copying the art's range leaves a walkable gap at the bottom of every room.
- **`Walk` tracks its own tile and lets the roster correct it.** Positions are
  coalesced at 250ms and a walk runs at seven tiles a second, so a step judged against
  the roster's tile is judged against where you were two steps ago. A roster naming a
  tile it never claimed wins outright — that is what keeps it safe to share one avatar
  with the desktop client and with party mode.

## Testing

`test/fake_gather.dart` is a real `HttpServer` doing a real WebSocket upgrade, so the
collector runs its production socket path — `WebSocket.connect`, binary frames, close
codes. Mocking the socket would leave the part most likely to be wrong untested.
`FakeGatherHttp` keeps the token endpoint off the network; a suite that reached Google
would be flaky and would burn the developer's own session.
