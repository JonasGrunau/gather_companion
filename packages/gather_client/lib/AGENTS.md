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
| `game_protocol.dart` | `bridge/lib/game-protocol.js` | `GameProtocolReader` — patch fold over 6 of ~49 models, **plus `DeltaState.events[]`**, **plus `actionReturns[]`**, plus `MeetingWatch` for invites and knocks. All three arrays matter and two of them arrive in frames whose `patches` array is empty, which is exactly how each went unread in turn: an event changes no state, and a *refused* action changes no state either. `ActionResult` + `describeActionError` are the second half; `lastSequence` is the server's counter, which the heartbeat echoes back. `_senderOf` tries all three names an event can give its sender (`senderId`, `senderUserId`, `senderSpaceUserId`) — they route on `targetUserIds` regardless, so getting it wrong is a wave from nobody rather than a wave that never came. |
| `gather_auth.dart` | `bridge/lib/gather-auth.js` (half) | `GatherAuth` — Firebase token exchange, `recent-spaces`. No IndexedDB half: the phone is *given* a refresh token at pairing. |
| `direct_collector.dart` | `bridge/lib/direct.js` | `DirectCollector` — handshake, `enterSpace`, heartbeat, 250ms roster coalescing, `teleport`, `move`, `setGait`, `setActive`, backoff, `describeClose()`, and the `_silenceLimit` deaf-socket watchdog. The watchdog and the close-code wording are ports and must not drift: `SILENCE_LIMIT_MS` / `_silenceLimit`, `describeClose` on both sides. **The heartbeat deliberately does not match the bridge's**: it carries `origin: 'Server'` and the echoed `sequenceNumber`, which is what the desktop client sends — see the note below. Every action is sent through `_actionFrame`, which files its `txnId` in `_awaiting` so the ack can be paired back to a name; refusals come out on `refusals` as `ActionRefused`. |
| `presence_tracker.dart` | `bridge/lib/presence.js` | The fold → `PresenceSnapshot` + `GatherEvent`s. Owns the wave cooldown. |
| `activity_feed.dart` | *(no counterpart)* | `ActivityFeed` + the `ActivityItem` hierarchy — Gather's own activity feed, over **REST**, not the socket. `GET /chat/activity-feed` answers `application/x.gather.msgpack`, so `msgpackDecode` reads it and `GatherHttp.getBytes` exists because `getJson` would mangle it. The body is normalised like a state dump: id lists per kind plus a model store, so `parseActivityFeed` is a set of joins — a wave's actor is on `ChatMessageMetadata`, not on the message, and read state is `ActivityEventSubscription.readAt`, not on the event. There is no pagination; every query param is ignored. `markRead` is **JSON** (the response is still msgpack — the endpoint is not symmetric), names the *event* id rather than the subscription that carries `readAt`, sends one request per item because no batch form exists, and is a **toggle** with no `read: true` — so filtering to unread items is correctness, not an optimisation, or "mark all read" un-reads most of the list. All four were guessed wrong before being captured off the desktop client; the shapes are in `../../../docs/gather-api.md#marking-activity-read`. **Waves and activity events are measured; the mention, reaction and reply joins are not** — no space available had one, so each degrades to `UnknownActivity` rather than throwing. The bridge has no counterpart because push already covers what it would use this for. |
| `sfu_signalling.dart` | *(no counterpart)* | `SfuSignalling` — the media plane's Socket.IO transport: CONNECT auth, ack-keyed `sendWithResponse`, the `{wsSequenceNumber, zodData}` envelope, server-push notifications, backoff. The bridge will never speak to the SFU. |
| `party.dart` | *(deleted from the bridge)* | `PartyMode`. Lives only here now — the app holds the socket, and two parties driving one avatar would fight. Draws its tiles from `space_map.dart`. |
| `space_art.dart` | *(no counterpart)* | `SpaceArt` / `ArtGround` / `ArtFloor` / `ArtWall` / `ArtSprite`, and the URL rules for Gather's floor, wall and furniture art. **Transcribed from the client bundle.** Gather ships no tileset: this is the list of images to fetch and where each one goes, 573 of them totalling 222 KB on the measured space. Note the two depths a wall can have — the sides are `ArtWall` in `ground`, while the north and south bands are `ArtSprite`s in `props`, because `ensureImmersiveWalls` gives them depths of their own. |
| `profile_photos.dart` | *(no counterpart)* | `ProfilePhotos`. Turns a `SpaceUser.profilePictureId` into a URL you can load, which takes a REST call: the `UserFile` rows **are** in the state dump and all three of their URL fields come across msgpack-undefined on every row, and the bucket refuses an unsigned request. `GET /spaces/:id/files/:fileId` answers a CloudFront signature valid 24 hours that needs **no** authorization header — which is why this hands back a URL rather than bytes. Cached hard, failures included: the map draws a hundred faces and rebuilds four times a second. Every test in `test/profile_photos_test.dart` is a count of requests, because that is the only interesting question here — and the first of them was written because `whenComplete(() => _inFlight.remove(id))` handed its own future back to itself and deadlocked every lookup. The cache still filled, so faces still appeared; they just waited for the next rebuild caused by something else. |
| `avatar.dart` | *(no counterpart)* | `hashOutfit` / `avatarSpriteUrl` / `avatarAnimation` / `AvatarAnimation` / `avatarFrame` / `Facing` / `Pose`. The sprite service composites an outfit into one 72-frame sheet; the "hash" is the wearable ids joined with dots plus a timestamp, and getting its order or format wrong is a 404 rather than a wrong-looking person. The animation table is `Ae` from the client, transcribed with its frame rates: walking at 7fps, talking at 4, a still pose declared as one frame at 60. Also `goKartUrl` / `goKartAnimation` / `goKartFrameSize`: the run cycle and the go-kart, which used to be unreachable here and are not any more. `Pose.running` is chosen on `speed.modifier > 1` — running and driving share it, there is no third cycle — and the kart is a separate 512×32 sheet of 16 frames laid **over** the body. Its frame order starts *east* where the avatar's starts south, which is exactly the sort of thing that silently points everybody's kart the wrong way. |
| `space_map.dart` | *(no counterpart)* | `SpaceMap` / `SpaceRoom` / `SpaceMapBuilder` — the floor plan. **Transcribed from Gather's client bundle**, not inferred: every rule names the getter it came from. Answers "which tiles can I stand on" (`walkable`), "where may a party go" (`open`, which also drops walled areas), "may I take *this* step" (`canStep` / `canPassThrough` — walls are lines between tiles, not tiles), "what is this room called" and "is somebody standing here sitting down" (`isSeat` — `playerState` never reaches the wire, so it is derived from the chair). `artFor()` builds the drawable scene from the same rows. Also "how do I walk there" (`routeTo`) and "where do I stand when the answer is a whole room" (`tilesClosestTo`), both transcribed from the client's own pathfinder — see below. `isPublicWalkway` and `navigatesToTile` are its two area predicates, top-level rather than methods because they are pure functions of `mapAreaType`. It also owns the **movement vocabulary** that is not geometry — `moveDirections`, `stepOf`, and `Gait` / `gaitOf` — because `direct_collector.dart` needs those words and importing `walk.dart` for them would be a cycle. |
| `walk.dart` | *(no counterpart)* | `Walk` — all of movement. Repeats `move` at Gather's own walking pace while a direction is held, applies `SpaceMap.canStep` to every step, and tracks its own tile because the roster is always two steps behind a walk. `follow(route)` is the other half: the tapped-destination walk, stepping a route from `SpaceMap.routeTo` to its end. **One stepper, deliberately** — a route and a held D-pad driving the same avatar would fight, so `press` cancels a route outright. The route is held as *tiles* rather than as directions, so each step re-derives its direction from wherever the roster says we actually are, and a correction that puts us somewhere the route does not pass through **re-plans** (`_replan`) rather than blindly applying the rest of it. That is the client's own recovery — `updatePathMove` re-runs the whole pathfinder every tick and takes `moveRoute[1]` — done on divergence rather than on every tick, since at a kart's pace every tick would be twenty-one searches a second. It used to simply stop, which was survivable at seven tiles a second and was not at twenty-one. **How fast is also here**, and it is the client's own arithmetic: `gaitToSetOff` picks a ceiling from the route's length (walk to 13 tiles, run to 23, take the go-kart past that), `gaitFor` recomputes from what is *left* on every step and never exceeds the ceiling, so a route only ever decelerates and the last six tiles of anything are walked. The gait divides the step interval — `getMoveInterval(m) = (1000/7) / m` — so the timer is re-timed whenever it changes, and entering `Gait.driving` parks a `kartPause` of two walking steps in which nothing moves at all, which is the beat the kart appears in. Standing in an area that is not a public walkway forces a walk however far there is left to go. `boost` is the shift key, and it is a live field rather than an argument because shift can be pressed *during* a walk: while it is on you drive, full stop — no distance test, no deceleration, no area test, exactly as `onArrowKeyDown(dir, shiftKey)` has none of the three. A gait is only ever announced when it **changes**, which is `setSpeedModifier`'s own rule and leaves one hole worth knowing about: a send that fails is a gait nobody will mention again. `_announced` is the last one the wire actually took, and `noteRoster` says it again until it lands — because the message that has to arrive is the `walk` on the way *out* of a kart, and `speed.modifier` is a synced field, so failing to send it parks this avatar in a go-kart on every other screen in the space. |

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
  stakes there are opening a call with nobody in it, or never opening one. The trap
  reaches **REST as well**, because those bodies are the same msgpack:
  `ActivityEventSubscription.readAt` is unset-as-undefined, so `readAt != null`
  answers *true* for an unread row and reports the whole feed as read. Test the
  value, never the absence of null — `activity_feed.dart` reads the timestamp.
- **A refused action is indistinguishable from a slow network unless you read
  `actionReturns`.** Arguments are validated *before* the action runs, so a bad one
  executes nothing: no patch, no event, no socket error, no close. Sending returns
  `ok` because the bytes went out — that is all `ok` has ever meant here — and the
  verdict arrives later, keyed by `txnId`, in a frame whose `patches` array is
  empty. `_awaiting` is what puts a name back on it, and it is cleared per connect,
  because pairing a fresh ack with a previous socket's action would put the wrong
  sentence in front of somebody. This channel is *why* `_act` can stay
  fire-and-forget: nothing waits, and nothing is silently lost either.
- **The heartbeat's `origin` reads backwards, and its `sequenceNumber` is not
  ours.** The frame the client *sends* says `origin: 'Server'`; the one it receives
  says `'Client'`. And `sequenceNumber` echoes the highest the *server* has sent —
  it reports what we have seen, not what we have sent. Both were measured off two
  live desktop clients on 2026-08-14 and both are the opposite of the obvious guess,
  so `bridge/lib/direct.js`, which still sends the older shape, is **wrong here and
  this file is right** — the second sanctioned divergence, alongside `enterSpace`.
  `msgpack_test.dart` keeps the bridge's bytes as a codec fixture under
  `bridgeHeartbeat`; the frame this client actually sends is asserted in
  `direct_collector_test.dart` instead.
- **`reportActivity` has two halves and the second one is easy to forget.** It is
  also the only action addressed to `Connection` with a `null` id rather than to our
  own `SpaceUser` — sending it the usual way is a schema failure, which executes
  nothing. The handshake reports `true`; `AppState` reports `false` when the app is
  backgrounded and `true` again on resume. Without the `false`, `Connection.isActive`
  stays true for the life of the socket and a phone in a pocket goes on telling
  colleagues somebody is at their desk.
- **`enterSpace` is sent here, and only here.** It puts an avatar in the room and
  permanently increments `numTimesEnteredSpace`, so it is not free — but the app
  publishes media, and a thing that publishes is present. `DirectCollector` sends
  it in the handshake when `/users/me/recent-spaces` supplied our `spaceUserId`,
  and otherwise as soon as the `Connection` row names us (`_maybeEnter`), once per
  connection. **The JS twin `bridge/lib/direct.js` must never grow these frames** —
  that divergence is the one exception to the never-drift rule, and
  `bridge/test/direct.test.js` guards it.
- **`SfuSignalling.start()` waits for the handshake, and that is load-bearing.**
  `_open()` ends at `socket.connect()`, which only *starts* it. A `start()` that
  awaited `_open()` alone resolved a round trip early, so the caller's first
  question came back `not connected` — followed a beat later by the connection
  succeeding. Every first call failed and every retry worked, which reads as a
  flaky server rather than a bug here. A refusal settles it immediately rather
  than making a tapped button wait out the ten-second timeout, and a second
  concurrent `start()` joins the first attempt instead of replacing its completer
  and stranding whoever was already waiting.
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
- **`move` *is* checked server-side, and it fails silently.** This entry used to say
  the opposite; the check was found one call deeper on 2026-08-15. `move`'s visible
  body is `position += delta`, but the `setPosition` it ends on refuses when
  `isBlockedBy(map, prevPosition)` — and refusal is not a reply, it is a position
  patch that never arrives. So `SpaceMap.canStep` is still mandatory, for a different
  reason: without it the optimistic tile runs ahead of an avatar that never left, and
  the walk is then reconciling against a lie.
  **Two halves, and `Walk` treats them differently.** A wall or a chair is handed to
  Gather — the step is sent, because the model assigns `direction` before it consults
  `setPosition` and that is how walking into furniture turns you to face it, exactly
  as `gameMove` does on the desktop. Off the grid is kept here and never sent:
  `blockedAtPosition` reads the object map only, so the void outside the 96×52
  footprint is unoccupied rather than blocked, and a move over the edge would very
  likely be accepted.
- **A locked door is enforced server-side, and the refusal is an event.**
  `isPermittedToMoveTo` is the *second* gate inside `setPosition`, so a `move` or a
  `teleport` into a private area you may not enter changes nothing — while the action
  still returns `Success` and no patch is sent. `UserIsNotPermittedToEnterLockedArea`
  is published to you alone, and it is the only thing that says what happened.
  `canEnterRoom` implements the three clauses of `canBeEnteredBy` a second client can
  evaluate; the two it cannot (`Meeting`, `AreaAccessRequest`) fail *closed*, so the
  local answer is stricter than Gather's and the event is what corrects it. Ask
  `privateAreaAt` and not `areaAt` — the rule reads the last **walled** area at a
  tile, not the smallest one covering it.
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
- **A destination is relocated, never refused.** The single most important thing
  about `routeTo`'s callers, and getting it wrong made tap-to-walk look broken.
  `blockedAtPosition` has **no exemption for seats** — a chair carrying collision
  points is as impassable as a wall in Gather too — and the client does not care,
  because `startPathMoveOnCurrentFloor` runs `getNearestFreeTile(goal, dir, 4)` over
  a blocked goal and walks you to the tile beside it. `moveSpaceUserToTile` does the
  same for a tile somebody is standing on. `nearestFree` is that rule; anything that
  refuses on `!isWalkable` is reproducing the bug. Note the search box: **2 by
  default, 4 when starting a walk**. One ring is not enough — a chair in the middle
  of a desk cluster is more than one tile from open floor.
- **A route that cannot be found ends in a teleport, not in an apology.**
  `shouldTeleport(reason)` is true for `NoPathFound` and `MaxDepthReached`, so
  `setPathMoveTo` blinks you there rather than telling you the place is unreachable.
  That matters more here than it does in the client, because the area rule above
  makes "no route" an ordinary answer in a real office. Note the bounds check it is
  paired with: `Hh` measures the goal against `baseArea.dimensionsInTiles`, which is
  the **whole grid** and not the office footprint, and `moveSpaceUserToTile` navigates
  to a tile with no area at all (`isNil(E) || E.shouldNavigateToTile()`). So the
  emptiness around the building is a destination like any other. This screen briefly
  refused it — a teleport into the void looked like a trap — and that was an invented
  rule: the way back is another tap, and a second client that quietly disallows what
  the first allows is worse than one that lets you stand somewhere odd.
- **There is no go-kart.** No vehicle model, no ride action, nothing on the wire that
  says "in a kart". There is `speed.modifier`, it is 1, 2 or 3, and
  `PlayerEntityRenderer` draws a kart under anybody who reaches 3
  (`if (getSpeedModifier() === Speed.DRIVING) this.setVehicle({id: "goKart-for-speed-modifier"})`).
  So "implement the go-kart" is: send `drive`, step three times as often, and draw
  the sheet. Miss the first of those and the pace is still right on this phone and
  wrong on every other screen in the space — an avatar crossing the office at
  twenty-one tiles a second in an idle pose.
- **Speed is a multiplier on everything, including the things measured in steps.**
  A go-kart sends `move` three times as often, so anything counted in *steps* buys a
  third as much *time* — and the roster it is being reconciled against did not speed
  up. `_maxPending` was a flat 16 and so covered 2.3 seconds at a walk and 0.76 of a
  second while driving, which is three roster ticks; one late roster past that and
  the tile it names has already fallen off the list, so a roster that was merely
  behind reads as a correction from nowhere and the walk ends in the middle of the
  office. `_pendingLimit` scales it by the gait. Anything else expressed in steps
  wants the same treatment before the kart is trusted at speed.
- **Gather has two doors to driving and they obey different rules.** The automatic
  one picks a gait from the route's length and then *decelerates*, so the kart is
  gone for the last sixteen tiles of every journey. The manual one is the shift key,
  and `onArrowKeyDown` does nothing but
  `setSpeedModifier(shift ? DRIVING : WALKING)` — no distance, no deceleration, no
  area check. Wiring the manual door through the automatic one's machinery is a bug
  that has already been made here once: a latched kart on a twenty-tile route lasted
  four steps before the deceleration cancelled it, which reads as the feature not
  working at all. `Walk.boost` bypasses all three rules, deliberately.
- **`SpaceRoom.locked` is a join, not a field.** `isLocked` lives on
  `MapEntityIdentifier` and the area only points at it, which is why that model is in
  `_models`. Nothing server-side enforces a lock — `move` and `teleport` both validate
  nothing — so a client that does not ask walks into a meeting somebody shut the door
  on.
- **An area has two ids and they are not interchangeable.** `SpaceRoom.id` is the
  `MapArea` row; `SpaceRoom.stableId` is the `MapEntityIdentifier` it points at, and
  that is the one everything outside the floor plan addresses it by. `SpaceUser.deskId`
  is a one-to-one at `MapEntityIdentifier`, so a desk is found by matching `stableId` —
  matching `id` compiles, reads correctly, and finds nobody's desk on a live space.
  Gather's own property name for it is `stableId_USE_THIS_INSTEAD_OF_ID`, shouting
  included.
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
