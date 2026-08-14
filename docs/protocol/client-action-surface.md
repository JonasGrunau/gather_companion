# Gather V2 client action surface

The complete set of operations the GatherV2 desktop client can perform — every
WebSocket action and every HTTP endpoint it is built to call. Extracted from the
shipped bundles of app version 0.0.76 (commit `90c16e075`, built 2026-08-12),
read on 2026-08-14 from desktop client 0.48.4.

Each action was then invoked against the live server on both a Member and an
Admin account, so the tables carry the server's own verdict alongside the
declaration. It is the companion to
[`observed-wire-protocol.md`](./observed-wire-protocol.md), which records what
two live clients actually said to each other. Where that file shows message
shape and timing from real frames, this one shows the full surface those frames
are drawn from. The method behind both, and the runbook for repeating it against
a newer app version, is [`how-it-was-mapped.md`](./how-it-was-mapped.md).

## Totals

| | Count |
| --- | --- |
| WebSocket actions (distinct ids) | **261** |
| WebSocket actions (owner + id pairs) | 277 |
| Owning models/repos | 71 |
| Distinct permissions | 92 |
| HTTP endpoints | **243** |
| HTTP namespaces | 17 |

HTTP verbs: GET 107, POST 94, PATCH 22, DELETE 20.

## How this was extracted

Two passes: static extraction of the surface, then a live sweep of it. Static
first, deliberately — pressing every button in the UI would only
ever prove a lower bound, and would miss anything behind a permission the
signed-in account lacks, a feature flag that is off, or a screen nobody opened.

**WebSocket actions.** Every server action is declared in source as

```js
name = (0, X.MethodAction)({
  target: this,
  id: "move",
  requiredPermission: SpaceUserPermission.Move,
  argSchema: () => z.object({ direction: z.nativeEnum(MoveDirection) }),
  fn: ...
})
```

so the declarations enumerate directly. The client sends them as
`{type: "Action", txnId, action: "<id>", args: [<Model>, <modelId>, ...rest]}`.
The owning class is recovered from the registration that follows each class body.

Only 40 of the app's 80 chunks load at startup; the chunk containing the action
definitions is lazy and was **not** among them. All 80 were enumerated from the
webpack runtime's chunk map and downloaded, so the catalogue covers code the
running client had not yet loaded.

Parse completeness: 277 declarations parsed against 277 `MethodAction)(` occurrences
in the bundles — no occurrence went unparsed. As a spot check, all 8 actions seen
on the wire in the live capture appear here.

**HTTP endpoints.** The client is a ts-rest client whose contract is closed over
rather than exposed, so each route's method and path were read out of the
function's `[[Scopes]]` over CDP — what a debugger would show, without calling
the endpoint. All 243 routes resolved.

## What this does and does not prove

The WebSocket catalogue is authoritative for **what the client can send**, and
the Member/Admin columns record what the server answered when each was actually
invoked. Where a column reads `needs args` or `—`, that action went untested —
a gap in the experiment, not a statement about the server.

The HTTP catalogue was exercised too, on both accounts, and its tables carry the
status each account received. 84 of 243 routes were withheld by the safety rules
and are marked `skip` — untested, not unavailable.

Neither catalogue maps the server beyond what this client knows about. The server
may implement routes and actions no client calls, and nothing here would show it.

The sweep ran in a throwaway space, which matters: it executed destructive
zero-argument actions, altered space settings and map geometry, and would have
done real damage in a space anyone depended on.

## Reimplementation reference

What a client on another platform has to get right. Every fact in this section
was taken from live frames or from the shipped bundles, not from any existing
client in this repository.

### Hosts

| Purpose | URL |
| --- | --- |
| Game plane | `wss://game-router.v2.gather.town/gather-game-v2?spaceId=<space>&authUserId=<firebaseUid>` |
| SFU discovery | `wss://router.v2.gather.town/socket.io/?EIO=4&transport=websocket` |
| SFU media | `wss://sfu-v2.<region>.prod.aws.gather.town/<node>/socket.io/?sessionId=<uuid>&EIO=4&transport=websocket` |
| REST | `https://api.v2.gather.town/api/v2` |
| Web app origin | `https://app.v2.gather.town` |

### Authentication

Firebase Auth. The Firebase web API key is `AIzaSyDPwTbXLMPbIkg6UKr49VrHWwkrOdRh__E`
— public by design for a web app, not a secret. A refresh token is exchanged for
an ID token at `https://securetoken.googleapis.com/v1/token?key=<apiKey>` with
`grant_type=refresh_token`. ID tokens last about an hour, so a long-lived client
must refresh rather than hold one.

That ID token is the JWT presented to the game plane, and the same token is sent
as `Authorization: Bearer <idToken>` on REST calls. Sessions persist in IndexedDB
under `firebase:authUser:<apiKey>:[DEFAULT]` at the web app origin.

### Three id spaces

The single most important thing to model correctly. One human has three ids, and
each plane uses a different one:

| Id | Used by |
| --- | --- |
| Firebase uid | game socket `authUserId` query, `Connection.authUserId` |
| `UserAccount.id` | SFU and router `srcId` / `dstId` |
| `SpaceUser.id` | every game-plane patch and action target |

`SpaceUser.userAccountId` links the last two. `srcStreamId` on the media plane is
the **space id**, not a per-user value.

### Game plane framing

msgpack over **binary** WebSocket frames. Every message is a map with a `type`.
Connection order, which must be respected:

```
→ {type:"Authenticate", credential:{type:"JWT", jwt:"<idToken>"}}
→ {type:"ConnectToSpace", spaceId, connectionData}
→ {type:"Subscribe"}
← {type:"SpaceStatus", warmInGatewayServer, warmInLogicServer}
← {type:"FullStateChunk", fullStatePatches[], chunkConfig:{id,chunkIndex,totalChunks}, sequenceNumber, …}
← {type:"DeltaState", patches[], actionReturns[], events[], optimisticAckTxnIds[], sequenceNumber}
```

`FullStateChunk` may arrive in several chunks; `chunkConfig` carries the index
and total, so a reimplementation must buffer until `totalChunks` have arrived.

### Actions and acknowledgement

```
→ {type:"Action", txnId:"<uuid v4>", action:"<id>", args:[<ModelName>, <modelId|null>, ...rest]}
```

`txnId` is client-generated. The server answers, on the originating socket only,
with `optimisticAckTxnIds:[txnId]` and
`actionReturns:[{connectionId, txnId, result:{type:"Success", value}}]`.
Acknowledgements never reach other clients, so a client learns the outcome of its
own actions and only its own — another participant's action is visible purely as
the state patches it produced. Client-side optimistic application plus rollback on
failure is therefore the intended model.

### Applying patches

Two ops observed:

```jsonc
{op:"addmodel", model:"SpaceUser", data:{ …whole record… }}      // no path
{op:"replace",  model:"SpaceUser", id:"…", path:"/position/x", data:42}
```

`path` is a JSON Pointer and may index into arrays
(`/completedContextualOnboardingPOIs/5`). Non-scalar values are tagged with
`$type` — `Position`, `Direction`, `Speed`, `Dimensions`, `SpaceUserAvailability`
were observed — so `direction` is `{$type:"Direction", value:"Right"}` while
`position/x` is a bare number. A reimplementation needs a tagged-value decoder,
not plain JSON assignment.

Movement emits `/direction` on every step but `/position/*` only when a tile
boundary is crossed, so a turn in place changes direction with no position patch.

### Heartbeat

```
→ {type:"Heartbeat", timestamp:<epochMs>, sequenceNumber:<lastSeen>, origin:"Server"}
← {type:"Heartbeat", timestamp:<epochMs>, origin:"Client"}
```

Roughly every 5 s. Two traps: `origin` reads backwards — the frame the client
*sends* says `"Server"` — so direction must be taken from the frame itself; and
the client's `sequenceNumber` echoes the highest server sequence it has seen
rather than counting its own sends. Server `sequenceNumber` is strictly
increasing and is the resync anchor.

### Media plane

Both media sockets are socket.io v4 (engine.io framing: `0` open, `40` connect,
`42` event, `2`/`3` ping/pong), authenticated with `{spaceId, token}` on connect.

Discovery on the router, one round trip per participant:

```
→ 42N["get-addr",{srcId:"<UserAccount.id>", srcStreamId:"<spaceId>"}]
← 42 ["addrs",{srcId, sfuAddr:"wss://host:443/ip-10-…", distance}]
← 43N[{addrFound:true|false}]
```

`addrFound:false` is a normal answer for a participant with no assigned node, not
an error. Then, against the node named by `addrs`:

```
→ 42["get-rtp-capabilities",{wsSequenceNumber}]
← 43[{routerRtpCapabilities:{codecs:[…]}}]        // mediasoup; audio/opus 48k stereo
→ 42["consume-request",{wsSequenceNumber, zodData:{srcId, srcStreamId, …}}]
→ 42["consume-allow",{wsSequenceNumber, zodData:{dstId, allowed:true}}]
← 42["consume-try",{srcId, srcStreamId, producerIdMap:{}}]

Three asymmetries to honour: outgoing payloads are wrapped in `zodData` but
incoming ones are not; `consume-request` uses `srcId` while `consume-allow` uses
`dstId` for the same kind of value; and every client→server message carries its
own monotonic `wsSequenceNumber`, unrelated to the game plane's `sequenceNumber`.
`producerIdMap` names available producers and is empty when nobody is publishing.

### REST

Base URL is **`https://api.v2.gather.town/api/v2`**, with
`Authorization: Bearer <idToken>`. The `/api/v2` prefix is not part of the path
as declared in the contract and must be added — without it every route answers
404, which is how this was established: a first sweep against the bare host
returned 404 on all 159 requests, and the same sweep against the prefixed base
returned a full spread of 200/400/403.

Validation failures come back as `400` with a zod issue list, which is the
fastest way to learn a route's contract:

```json
{"error":"INVALID_REQUEST","errors":[{"code":"invalid_type","expected":"string",
 "received":"undefined","path":["areaId"],"message":"Required"}]}
```

### Models (149)

Server models the client holds repositories for. State arrives as patches
addressed by `{model, id}`, so these are the entity names a reimplementation must
be able to store, even if it only interprets a few.

```
AISpaceActivityItem                                   AITeamData                                            ActivityEvent
ActivityEventSubscription                             AreaAccessRequest                                     AreaAccessRequestRoleAssignment
BaseCombinedCalendarEvent                             BaseCombinedCalendarEventRoleAssignment               Bots
CatalogItem                                           CatalogItemVariant                                    ChatChannel
ChatChannelMember                                     ChatChannelMetadata                                   ChatChannelPreferences
ChatExportSession                                     ChatIncomingWebhook                                   ChatIntegration
ChatIntegrationAction                                 ChatIntegrationDelivery                               ChatIntegrationDestination
ChatIntegrationEvent                                  ChatIntegrationInstance                               ChatMention
ChatMessage                                           ChatMessageMetadata                                   ChatMessageReaction
ChatReadCursor                                        ChatThreadParticipant                                 ChatUserGroup
ChatUserGroupMember                                   ClientRefreshTarget                                   Connection
ConnectionRoleAssignment                              CoworkingSession                                      CoworkingSessionRoleAssignment
CustomerAccountUser                                   CustomerPlanInterval                                  DeploySimulation
EligibilitySurveySubmission                           ExternalCalendar                                      ExternalCalendarConnection
ExternalCalendarConnectionAccess                      ExternalCalendarConnectionAccessRoleAssignment        ExternalCalendarConnectionRoleAssignment
ExternalCalendarConnectionSecrets                     ExternalCalendarRoleAssignment                        Floor
FloorMap                                              FloorRoleAssignment                                   GitHubAppInstallation
GitHubOAuthUserSecret                                 GithubPullRequest                                     GoogleCalendarEvent
GrapevineIntegration                                  GuestPass                                             GuestPassRoleAssignment
MapArea                                               MapAreaRoleAssignment                                 MapEntityIdentifier
MapGroup                                              MapObject                                             MapObjectBehaviors
MapObjectRoleAssignment                               Meeting                                               MeetingActionItem
MeetingActionItemRoleAssignment                       MeetingArtifact                                       MeetingArtifactAccess
MeetingArtifactAccessRoleAssignment                   MeetingArtifactRoleAssignment                         MeetingExportSession
MeetingIntegration                                    MeetingIntegrationRoleAssignment                      MeetingJoinInfo
MeetingJoinInfoRoleAssignment                         MeetingJoinRequest                                    MeetingJoinRequestRoleAssignment
MeetingMemo                                           MeetingMemoRoleAssignment                             MeetingMemoTranscriptContent
MeetingParticipant                                    MeetingParticipantRoleAssignment                      MeetingRecording
MeetingRecordingRoleAssignment                        MeetingRoleAssignment                                 MeetingWebhook
ModelSubscription                                     ModelSubscriptionRoleAssignment                       MoveClusterToMeeting
Organization                                          OrganizationEmailDomain                               OrganizationMember
OrganizationSpace                                     OutfitTemplate                                        PerformanceProfiling
PermissionsGroup                                      PermissionsGroupUser                                  PermissionsRole
PricingServiceCustomer                                PricingServiceInvoice                                 PricingServicePaymentMethod
PricingServiceSubscription                            PushDevice                                            PushTicket
Space                                                 SpaceApiKey                                           SpaceCustomEmoji
SpaceCustomerPlanInterval                             SpaceInvitation                                       SpaceRoleAssignment
SpaceSettings                                         SpaceSettingsRoleAssignment                           SpaceTemplate
SpaceTemplateRoleAssignment                           SpaceUser                                             SpaceUserCluster
SpaceUserClusterJoinRequest                           SpaceUserClusterJoinRequestRoleAssignment             SpaceUserClusterRoleAssignment
SpaceUserGeneratedStatus                              SpaceUserMediaStatus                                  SpaceUserOnboarding
SpaceUserOnboardingRoleAssignment                     SpaceUserOutfit                                       SpaceUserRoleAssignment
SpaceUserStatus                                       SpaceUserUsageBasedBillingNotification                SpaceUserUsageBasedBillingNotificationRoleAssignment
SpotifyOAuthUserSecret                                StagedDeskAssignment                                  StudioUserSession
StudioUserSessionRoleAssignment                       SyncedMusicPlayback                                   SyncedMusicPlaybackRoleAssignment
ThirdPartyEvent                                       ThirdPartySecrets                                     UsageBasedBillingMetric
UserAccount                                           UserAccountSecrets                                    UserFile
UserInvitation                                        UserMapHistory                                        UserMapHistoryRoleAssignment
Wearable                                              WearablePart                                          WebhookObjectToken
WorkOSConnection                                      WorkOSOrganization
```

The full record shape for `SpaceUser` — the model that matters most — is in
[`observed-wire-protocol.md`](./observed-wire-protocol.md), taken from a real
frame. Note that **no field represents camera or microphone state**: whether a
participant is publishing media is knowable only from the media plane.

## What the server actually said

Every catalogued action was invoked against the live server on both accounts —
`grunauluca` (Member) and `grunaujonas` (Admin) — in a throwaway space, and the
verdict recorded. Each was called with **no arguments**, which splits the
catalogue usefully: an action that needs arguments fails validation and reports
the schema it wanted, while a zero-argument action executes and reports whether
the account was permitted to run it.

| Outcome | Member | Admin | Meaning |
| --- | --- | --- | --- |
| `success` | 33 | 46 | ran to completion |
| `refused` | 57 | 59 | server refused — permission or business rule |
| `validation` | 110 | 87 | rejected by schema validation (needs arguments) |
| `error` | 3 | 2 | other server-side rejection |
| `no-method` | 66 | 75 | no such method on the resolved target |
| `no-target` | 8 | 8 | no instance of that model in this space |

### `PerformSystemAction` is not an admin permission

The single largest refusal class. 54 actions were refused for the Member
and 54 for the Admin, with the identical message:

```
[Server]: User <spaceUserId> does not have permission Symbol(PerformSystemAction)
```

The space owner is refused exactly as the Member is, so this is a **server-only**
capability, not a role a user can hold. Those actions — the `broadcast*` family on
the chat repos, `AITeamDataRepo.create`, and the rest — exist in the client bundle
but no client can invoke them. Treat them as server-internal and ignore them when
reimplementing.

Comparing the two roles action-by-action, **no action was permitted for the Admin
and refused for the Member**. Role differences in this space were confined to
`SpaceTemplate.delete` (refused for the Admin with *"User does not have permission
to edit Space Templates"*) and target-resolution differences, not to the
permission system gating ordinary gameplay.

### Business rules surface as prose

Refusals that are not permission checks come back as readable sentences, which
document semantics no schema captures:

```
Cannot wave at yourself
Cannot request to lead yourself
Cannot move yourself via admin action
Cannot reset a non-webhook-object MapObject
There's no active transaction to revert
Deprecated Method Action.
No Grapevine integration found for this space. Please enable Grapevine first.
```

### Validation precedes the permission check

`forceMute()` returned a *schema* error, not a permission denial, although the
Member holds no force-mute permission. Arguments are validated first and the
permission gate is only reached once they parse. Two consequences: junk arguments
are a safe way to harvest schemas, because nothing executes; and they are useless
for probing permissions, because the check never runs.

### What reached the other client

The peer was recorded throughout both sweeps. State changes arrived as patches —
`/dancing`, `/speaking`, `/handRaisedAt`, `/speed`, `/deskId`,
`/userSetAvailability`, and from the Admin sweep a run of `SpaceSettings` toggles
(`/enableAmbientAudio`, `/enableDirectMessages`, `/guestCheckInEnabled`, …) and map
geometry (`/dimensionsInTiles/*`, `/doorways`, `/relativeX`, `/relativeY`).

Transient interactions arrived as **events**, not patches:
`ConfettiThrown`, `NewMemberJoined`, `DraftMapPublish`. A client that only applies
patches would miss all three.

### The `Member` and `Admin` columns

In the tables below: **ran** — executed successfully; **refused** — permission or
business rule; **needs args** — rejected by validation, so the action requires
arguments and its permission is untested; **—** — not reachable on the resolved
target in this space, so untested. A `needs args` or `—` is a gap in this
experiment, not a statement about the server.

## WebSocket actions

Sent as `{type: "Action", txnId, action, args}` on
`wss://game-router.v2.gather.town/gather-game-v2`. `args[0]` is the owning model
name and `args[1]` its id; the argument schema below is the remainder.

### SpaceUser (50)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `assignGitHubUserId` | SpaceUserPermission.AssignGitHubUserId | needs args | needs args | `number()` |
| `broadcastEmote` | SpaceUserPermission.BroadcastEmote | needs args | needs args | `object({emote:string(),count:number(),ambientlyConnectedUserIds:array(zodUuid)})` |
| `broadcastMessage` | SpaceUserPermission.BroadcastMessage | needs args | needs args | `object({message:union([string(),object({}).passthrough()]),ambientlyConnectedUserIds:array(zodUuid)})` |
| `broadcastTransientTyping` | SpaceUserPermission.BroadcastMessage | needs args | needs args | `object({isTyping:boolean(),ambientlyConnectedUserIds:array(zodUuid)})` |
| `claimDesk` | SpaceUserPermission.ClaimUnclaimDesk | needs args | needs args | `object({deskId:zodUuid})` |
| `clearCalendarInferredStatus` | SpaceUserPermission.UpdateCustomStatus | ran | ran | — |
| `clearCustomStatus` | SpaceUserPermission.UpdateCustomStatus | ran | ran | — |
| `clearDeskAssignmentStatus` | SpaceUserPermission.ClearDeskAssignmentStatus | ran | ran | — |
| `clearFollowers` | SpaceUserPermission.UpdateFollowing | ran | ran | — |
| `deactivate` | SpaceUserPermission.Deactivate | needs args | needs args | — |
| `disconnectGitHubAccount` | SpaceUserPermission.ManageThirdPartyConnections | ran | ran | — |
| `drive` | SpaceUserPermission.Move | ran | ran | — |
| `enterSpace` | SpaceUserPermission.EnterSpace | ran | ran | — |
| `faceDirection` | SpaceUserPermission.Move | needs args | needs args | `nativeEnum(MoveDirection)` |
| `follow` | SpaceUserPermission.UpdateFollowing | needs args | needs args | `object({followTargetId:zodUuid})` |
| `forceMute` | SpaceUserPermission.ForceMute | needs args | needs args | `object({mediaKind:nativeEnum(MediaKind)})` |
| `leaveCluster` | SpaceUserPermission.UpdateCluster | ran | ran | — |
| `lowerHand` | SpaceUserPermission.UpdateHandRaised | ran | ran | — |
| `move` | SpaceUserPermission.Move | needs args | needs args | `object({direction:nativeEnum(MoveDirection)})` |
| `moveToFloor` | SpaceUserPermission.Move | needs args | needs args | `object({floorId:zodUuid})` |
| `raiseHand` | SpaceUserPermission.UpdateHandRaised | ran | ran | — |
| `reactivate` | SpaceUserPermission.Deactivate | needs args | needs args | — |
| `requestToLead` | SpaceUserPermission.RequestToLead | refused | refused | — |
| `respondToRequestToLead` | SpaceUserPermission.RespondToRequestToLead | needs args | needs args | `nativeEnum(RequestToLeadResponseStatus)` |
| `run` | SpaceUserPermission.Move | ran | ran | — |
| `saveSpaceOutfit` | SpaceUserPermission.SaveSpaceOutfit | needs args | needs args | `object({skin:zodUuid.optional(),hair:zodUuid.optional(),facialHair:zodUuid.optional(),top:zodUuid.optional(),bottom:zodUuid.option` |
| `sendMessageMention` | SpaceUserPermission.BroadcastMessage | needs args | needs args | `object({message:string(),userIds:array(zodUuid)})` |
| `sendUserToDesk` | SpaceUserPermission.SendToDesk | needs args | refused | — |
| `sendWave` | SpaceUserPermission.SendWave | refused | refused | — |
| `setAvailability` | SpaceUserPermission.UpdateAvailability | needs args | needs args | `object({availability:nativeEnum(Availability),debugSource:string().optional()})` |
| `setCalendarInferredStatus` | SpaceUserPermission.UpdateCustomStatus | needs args | needs args | `object({text:string(),emoji:string(),clearCondition:object({type:literal(SpaceUserStatusClearCondition.DateTime),clearAt:date()}),` |
| `setCustomStatus` | SpaceUserPermission.UpdateCustomStatus | needs args | needs args | `object({text:string().max(eg).optional(),emoji:string().optional(),clearCondition:union([object({type:literal(SpaceUserStatusClear` |
| `setHandRaised` | SpaceUserPermission.UpdateHandRaised | needs args | needs args | `boolean()` |
| `startDancing` | SpaceUserPermission.UpdateDancing | ran | ran | — |
| `startSpeaking` | SpaceUserPermission.UpdateSpeaking | ran | ran | — |
| `stopDancing` | SpaceUserPermission.UpdateDancing | ran | ran | — |
| `stopSpeaking` | SpaceUserPermission.UpdateSpeaking | ran | ran | — |
| `teleport` | SpaceUserPermission.Move | needs args | needs args | `object({x:number(),y:number(),direction:nativeEnum(MoveDirection)})` |
| `throwConfetti` | SpaceUserPermission.ThrowConfetti | ran | ran | — |
| `unassignGitHubUserId` | SpaceUserPermission.AssignGitHubUserId | ran | ran | — |
| `unclaimDesk` | SpaceUserPermission.ClaimUnclaimDesk | ran | ran | — |
| `unfollow` | SpaceUserPermission.UpdateFollowing | ran | ran | — |
| `updateActiveApp` | SpaceUserPermission.UpdateActiveApp | needs args | needs args | `nativeEnum(eI).optional()` |
| `updateActiveMapObjectInteraction` | SpaceUserPermission.UpdateActiveMapObjectInteraction | needs args | needs args | `object({mapObjectId:zodUuid.optional()})` |
| `updateCalendarInferredStatus` | SpaceUserPermission.UpdateCustomStatus | needs args | needs args | `object({id:string(),text:string(),emoji:string(),clearCondition:object({type:literal(SpaceUserStatusClearCondition.DateTime),clear` |
| `updateCoreRole` | SpaceUserPermission.UpdateRole | needs args | needs args | `nativeEnum(CoreRoleType)` |
| `updateName` | SpaceUserPermission.UpdateName | needs args | needs args | `object({name:string()})` |
| `updateProfilePicture` | SpaceUserPermission.UpdateProfilePicture | needs args | needs args | `object({fileId:zodUuid.optional()})` |
| `updateTargetMeetingArea` | SpaceUserPermission.UpdateTargetMeetingArea | needs args | needs args | `object({meetingAreaId:zodUuid.optional(),shouldBeInClusterWithOthersWithSameTargetMeetingArea:boolean().optional()})` |
| `walk` | SpaceUserPermission.Move | ran | ran | — |

### MapArea (14)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `assignStagedDeskToSpaceUserOrEmail` | EditMapArea | needs args | needs args | `object({spaceUserIdOrEmail:union([zodUuid,string().email()])})` |
| `lock` | ChangeLockState | needs args | needs args | — |
| `removeStagedDeskFromSpaceUserOrEmail` | EditMapArea | needs args | needs args | `object({})` |
| `requestToAccess` | RequestToAccess | ran | ran | — |
| `setAreaType` | EditMapArea | needs args | needs args | `object({mapAreaType:nativeEnum(MapAreaType)})` |
| `setCapacity` | EditMapArea | needs args | needs args | `object({capacity:number()})` |
| `setFloorColor` | EditMapArea | needs args | needs args | `object({floorColor:nativeEnum(A2)})` |
| `setFloorTexture` | EditMapArea | needs args | needs args | `object({floorTexture:nativeEnum(AX)})` |
| `setFloorTextureAndColor` | EditMapArea | needs args | needs args | `object({floorTexture:nativeEnum(AX),floorColor:nativeEnum(A2)})` |
| `setName` | EditMapArea | needs args | needs args | `object({name:string()})` |
| `setWallsTexture` | EditMapArea | needs args | needs args | `object({wallsTexture:nativeEnum(AZ)})` |
| `smartResize` | EditMapArea | needs args | needs args | `object({up:number().int(),down:number().int(),left:number().int(),right:number().int()})` |
| `trimInPlace` | EditMapArea | ran | ran | — |
| `unlock` | ChangeLockState | needs args | needs args | — |

### Meeting (14)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `addParticipant` | AddParticipant | — | — | `object({spaceUserId:zodUuid,isHost:boolean(),inviteStatus:nativeEnum(MeetingParticipantInviteStatus),responseStatusOverride:native` |
| `addParticipants` | AddParticipant | — | — | `array(object({spaceUserId:zodUuid,isHost:boolean(),inviteStatus:nativeEnum(MeetingParticipantInviteStatus),responseStatusOverride:` |
| `cancel` | Cancel | — | — | — |
| `end` | End | — | — | — |
| `getMeetingTitle` | Start | — | — | — |
| `getOrSetMeetingArea` | AssignMeetingArea | — | — | `object({desiredCapacity:number().optional(),includePrivateDesks:boolean().optional()})` |
| `markResuming` | Start | — | — | `boolean()` |
| `raiseRecordingOrTranscriptionStartingEvent` | StartRecordingIncludingAVRecordingAndOrTranscription | — | — | `object({isTranscribing:boolean(),isRecording:boolean()})` |
| `removeParticipant` | RemoveParticipant | — | — | `zodUuid` |
| `requestToJoin` | RequestToJoin | — | — | — |
| `restart` | Start | — | — | — |
| `start` | Start | — | — | — |
| `startRecordingIncludingAVRecordingAndOrTranscription` | StartRecordingIncludingAVRecordingAndOrTranscription | — | — | `intersection(object({record:boolean(),shouldRaiseStartingEvent:boolean().default(true)}),union([object({transcribe:literal(true),t` |
| `stopRecordingIncludingAVRecordingAndTranscription` | StopRecordingIncludingAVRecordingAndOrTranscription | — | — | — |

### SpaceSettings (14)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `toggleAutoLockDesksDefault` | UpdateSpaceSetting | needs args | ran | — |
| `toggleEmailDomainAuthEnabled` | UpdateSpaceSetting | needs args | ran | — |
| `toggleEnableAmbientAudio` | UpdateSpaceSetting | needs args | ran | — |
| `toggleEnableDirectMessages` | UpdateSpaceSetting | needs args | ran | — |
| `toggleEnableGatherChatChannels` | UpdateSpaceSetting | needs args | ran | — |
| `toggleEnableGatherChatInMeetings` | UpdateSpaceSetting | needs args | ran | — |
| `toggleEnableSendNearbyInMapView` | UpdateSpaceSetting | needs args | ran | — |
| `toggleGatherStaffAccessEnabled` | UpdateSpaceSetting | needs args | ran | — |
| `toggleGuestCheckInEnabled` | UpdateSpaceSetting | needs args | ran | — |
| `toggleMemberToMemberInvitesEnabled` | UpdateSpaceSetting | needs args | ran | — |
| `toggleSpaceSetting` | UpdateSpaceSetting | needs args | needs args | `nativeEnum($)` |
| `toggleStudioEnabled` | UpdateSpaceSetting | needs args | ran | — |
| `updateAllowedEmailDomains` | UpdateSpaceSetting | needs args | needs args | `array(string())` |
| `updateAmbientAudioRange` | UpdateSpaceSetting | needs args | needs args | `nativeEnum(W)` |

### GitHubAppInstallationRepo (12)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `addFloor` | FloorPermission.EditMap | — | — | — |
| `approvePendingInstallation` | PerformSystemAction | refused | refused | `object({id:zodUuid,gitHubAppInstallationId:number()})` |
| `createApprovedInstallation` | PerformSystemAction | refused | refused | `object({spaceId:zodUuid,gitHubOrganizationId:number(),gitHubAppInstallationId:number()})` |
| `createPendingInstallation` | PerformSystemAction | refused | refused | `object({spaceId:zodUuid,gitHubOrganizationId:number(),gitHubAppInstallationRequestId:number()})` |
| `DEBUG_createFloor` | FloorPermission.EditMap | — | — | — |
| `deleteInstallation` | PerformSystemAction | refused | refused | `zodUuid` |
| `duplicateFloor` | FloorPermission.EditMap | — | — | `object({floorId:zodUuid})` |
| `removeFloor` | FloorPermission.EditMap | — | — | `object({floorId:zodUuid})` |
| `renameFloor` | FloorPermission.EditMap | — | — | `object({floorId:zodUuid,name:string().trim().max(MAX_FLOOR_NAME_LENGTH)})` |
| `reorderFloors` | FloorPermission.EditMap | — | — | `object({floorIds:array(zodUuid)})` |
| `setLandingFloor` | FloorPermission.EditMap | — | — | `object({floorId:zodUuid})` |
| `updatePreviewFilePath` | PerformSystemAction | — | — | `object({floorId:zodUuid,previewFilePath:string()})` |

### ModelSubscriptionRepo (9)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `broadcastMeetingMemoUpdated` | PerformSystemAction | — | — | `object({event:object(GAME_EVENT_PAYLOADS[GameEvents.MeetingMemoUpdated]),targetUserIds:union([undefined(),set(zodUuid)])})` |
| `createSubscription` | PublicMethod | needs args | needs args | `object({modelKey:nativeEnum(SubscribableModelKeys),modelIds:set(zodUuid),subscriptionType:nativeEnum(ModelSubscriptionType)})` |
| `createUnscheduledMeetingInCurrentArea` | MeetingPermission.AssignMeetingArea | — | — | `object({areaId:zodUuid,inviteeIds:array(zodUuid),responseStatusOverride:nativeEnum(MeetingParticipantResponseStatus).optional()})` |
| `findAvailableAreaAndCreateUnscheduledMeeting` | MeetingPermission.AssignMeetingArea | — | — | `object({inviteeIds:array(zodUuid),includePrivateDesks:boolean(),responseStatusOverride:nativeEnum(MeetingParticipantResponseStatus` |
| `getActiveTranscriptionState` | PerformSystemAction | — | — | `object({meetingId:zodUuid,spaceUserId:zodUuid})` |
| `getMeetingLinkDetails` | PublicMethod | — | — | `Ag` |
| `getMeetingLinkStatus` | PublicMethod | — | — | `Ag` |
| `unsubscribeAll` | PublicMethod | ran | ran | — |
| `updateMeetingArea` | MeetingPermission.AssignMeetingArea | — | — | `object({meetingId:zodUuid,areaId:zodUuid.nullable()})` |

### MapEntity (8)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `delete` | EditMapEntity | — | — | — |
| `duplicate` | EditMapEntity | — | — | — |
| `handleOverlaps` | EditMapEntity | — | — | — |
| `moveBy` | EditMapEntity | — | — | `object({xOffset:number(),yOffset:number()})` |
| `moveToAbsolutePosition` | EditMapEntity | — | — | `object({x:number(),y:number(),forceSnapToGrid:boolean().optional(),dontValidatePosition:boolean().optional()})` |
| `moveToRelativePosition` | EditMapEntity | — | — | `object({x:number(),y:number(),forceSnapToGrid:boolean().optional()})` |
| `reparentTo` | EditMapEntity | — | — | `object({newParentEntity:AnyMapEntityTypedId})` |
| `restore` | EditMapEntity | — | — | — |

### SpaceUserOnboarding (8)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `completeDbo` | UpdateOnboardingStatus | ran | ran | — |
| `dismissGatherAssistPrompt` | UpdateOnboardingStatus | ran | ran | — |
| `dismissOnboardingChecklist` | UpdateOnboardingStatus | ran | ran | — |
| `dismissOnboardingModalPrompt` | UpdateOnboardingStatus | ran | ran | — |
| `markContextualOnboardingPOICompleted` | UpdateOnboardingStatus | needs args | needs args | `nativeEnum(V)` |
| `markOnboardingTaskCompleted` | UpdateOnboardingStatus | needs args | needs args | `nativeEnum(OnboardingTaskEnum)` |
| `reset` | UpdateOnboardingStatus | ran | ran | — |
| `unmarkOnboardingTaskCompleted` | UpdateOnboardingStatus | needs args | needs args | `nativeEnum(OnboardingTaskEnum)` |

### ChatChannelRepo (7)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `broadcastBulkAddMembers` | PerformSystemAction | refused | refused | `object({event:object(GAME_EVENT_PAYLOADS[GameEvents.ChatBroadcastBulkAddMembers]),targetUserIds:union([undefined(),set(zodUuid)])}` |
| `broadcastBulkRemoveMembers` | PerformSystemAction | refused | refused | `object({event:object(GAME_EVENT_PAYLOADS[GameEvents.ChatBroadcastBulkRemoveMembers]),targetUserIds:set(zodUuid)})` |
| `broadcastDeleteChannel` | PerformSystemAction | refused | refused | `object({event:object(GAME_EVENT_PAYLOADS[GameEvents.ChatBroadcastDeleteChannel]),targetUserIds:union([undefined(),set(zodUuid)])})` |
| `broadcastNewChannel` | PerformSystemAction | refused | refused | `object({event:object(GAME_EVENT_PAYLOADS[GameEvents.ChatBroadcastNewChannel]),targetUserIds:union([undefined(),set(zodUuid)])})` |
| `broadcastNewChannelMembership` | PerformSystemAction | refused | refused | `object({event:object(GAME_EVENT_PAYLOADS[GameEvents.ChatBroadcastNewChannelMembership]),targetUserIds:union([undefined(),set(zodUu` |
| `broadcastTypingIndicator` | PerformSystemAction | refused | refused | `object({event:object(GAME_EVENT_PAYLOADS[GameEvents.ChatBroadcastTypingIndicator]),targetUserIds:union([undefined(),set(zodUuid)])` |
| `broadcastUpdateChannel` | PerformSystemAction | refused | refused | `object({event:object(GAME_EVENT_PAYLOADS[GameEvents.ChatBroadcastUpdateChannel]),targetUserIds:union([undefined(),set(zodUuid)])})` |

### ChatMessageRepo (6)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `broadcastDeleteMessage` | PerformSystemAction | refused | refused | `object({event:object(GAME_EVENT_PAYLOADS[GameEvents.ChatBroadcastDeleteMessage]),targetUserIds:union([undefined(),set(zodUuid)])})` |
| `broadcastDeleteReaction` | PerformSystemAction | refused | refused | `object({event:object(GAME_EVENT_PAYLOADS[GameEvents.ChatBroadcastDeleteReaction]),targetUserIds:union([undefined(),set(zodUuid)])}` |
| `broadcastNewMessage` | PerformSystemAction | refused | refused | `object({event:object(GAME_EVENT_PAYLOADS[GameEvents.ChatBroadcastNewMessage]),targetUserIds:union([undefined(),set(zodUuid)])})` |
| `broadcastNewReaction` | PerformSystemAction | refused | refused | `object({event:object(GAME_EVENT_PAYLOADS[GameEvents.ChatBroadcastNewReaction]),targetUserIds:union([undefined(),set(zodUuid)])})` |
| `broadcastNewThreadParticipation` | PerformSystemAction | refused | refused | `object({event:object(GAME_EVENT_PAYLOADS[GameEvents.ChatBroadcastNewThreadParticipation]),targetUserIds:union([undefined(),set(zod` |
| `broadcastUpdateMessage` | PerformSystemAction | refused | refused | `object({event:object(GAME_EVENT_PAYLOADS[GameEvents.ChatBroadcastUpdateMessage]),targetUserIds:union([undefined(),set(zodUuid)])})` |

### ExternalCalendarConnectionRepo (6)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `checkCalendarScopes` | PerformSystemAction | refused | refused | `object({scope:string(),userId:zodUuid})` |
| `connectCalendar` | PerformSystemAction | refused | refused | `object({code:string(),userId:zodUuid})` |
| `initiateAuthFlow` | ExternalCalendarConnectionPermission.InitiateAuthFlow | needs args | needs args | `object({electronProtocol:string().optional(),newMeetingTitle:string().optional(),shouldGetPeopleApiScopes:boolean().optional()})` |
| `markSyncFinishedSystemAction` | PerformSystemAction | refused | refused | `object({externalCalendarConnectionId:zodUuid})` |
| `markSyncStartedSystemAction` | PerformSystemAction | refused | refused | `object({externalCalendarConnectionId:zodUuid})` |
| `syncCalendarsSystemAction` | PerformSystemAction | refused | refused | `object({externalCalendarConnectionId:zodUuid,googleCalendarApiCalendars:array(googleCalendarApiCalendarSchema.zodType)})` |

### MapObject (6)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `resetWebhookObject` | EditMapObject | refused | refused | — |
| `rotate` | MapEntityPermission.EditMapEntity | needs args | needs args | `object({isClockwise:boolean().optional()})` |
| `rotateToOrientation` | MapEntityPermission.EditMapEntity | needs args | needs args | `object({orientation:string()})` |
| `setCatalogItemVariant` | EditMapObject | needs args | needs args | `object({catalogItemVariantId:zodUuid})` |
| `setEmbeddedWebsiteUrl` | EditMapObject | needs args | needs args | `object({url:embeddedUrlSchema})` |
| `setWebhookObjectInfo` | EditMapObject | needs args | needs args | `object({name:string().max(WEBHOOK_OBJECT_NAME_MAX_LENGTH).optional(),description:string().max(WEBHOOK_OBJECT_DESCRIPTION_MAX_LENGT` |

### UserInvitationRepo (6)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `deleteStagedUserInvitation` | SpacePermission.InviteMemberOrGuest | needs args | needs args | `object({email:string().email()})` |
| `invalidate` | SpacePermission.InviteAdmin | needs args | needs args | `zodUuid` |
| `inviteAdminByEmail` | SpacePermission.InviteAdmin | needs args | needs args | `object({email:string().email(),spaceId:zodUuid})` |
| `inviteMemberOrGuestByEmail` | SpacePermission.InviteMemberOrGuest | needs args | needs args | `object({email:string().email(),roleName:nativeEnum(CoreRoleType),spaceId:zodUuid})` |
| `inviteMembersByEmailWithoutDesks` | SpacePermission.InviteMemberOrGuest | needs args | needs args | `array(string())` |
| `stageMemberEmailInvitations` | SpacePermission.InviteMemberOrGuest | needs args | needs args | `object({emails:array(string().email())})` |

### BotsRepo (5)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `addBot` | BotManagement | needs args | needs args | `object({name:string().optional()})` |
| `addBots` | BotManagement | needs args | needs args | `object({count:number().min(1).max(100),coreRole:union([literal(CoreRoleType.Guest),literal(CoreRoleType.Member)]).optional()})` |
| `ensureLoaded` | PerformSystemAction | — | — | `array(zodUuid)` |
| `removeAllBots` | BotManagement | needs args | ran | — |
| `removeBot` | BotManagement | needs args | needs args | `object({name:string()})` |

### Floor (5)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `discardDraftMap` | EditMap | needs args | ran | — |
| `getOrCreateDraftMap` | EditMap | needs args | ran | — |
| `loadFromSpaceTemplate` | EditMap | needs args | needs args | `object({spaceTemplateId:zodUuid,asActiveMap:boolean().default(false)})` |
| `publishDraftMap` | EditMap | needs args | ran | — |
| `publishDraftMapAsSpaceTemplate` | EditMap | needs args | needs args | `spaceTemplateMetadataSchema` |

### GuestPass (5)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `admit` | CanRespond | — | — | — |
| `delete` | CanDestroy | — | — | — |
| `deny` | CanRespond | — | — | — |
| `reset` | CanReset | — | — | — |
| `respondRunningLate` | CanRespond | — | — | — |

### MeetingActionItem (5)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `cancelEditing` | UpdateActionItem | — | — | — |
| `lock` | UpdateActionItem | — | — | — |
| `softDelete` | UpdateActionItem | — | — | — |
| `startEditing` | StartEditingActionItem | — | — | — |
| `update` | UpdateActionItem | refused | refused | `object({userProvidedText:string()})` |

### SpaceUserRepo (5)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `bulkDeactivateRecentlyAddedSpaceMembers` | PerformSystemAction | refused | refused | `number()` |
| `deleteSpaceUser` | PerformSystemAction | refused | refused | `object({spaceUserId:zodUuid})` |
| `gatherAdminUpdateCoreRole` | PerformSystemAction | refused | refused | `object({spaceUserId:zodUuid,coreRoleType:nativeEnum(CoreRoleType),enforceCapacity:boolean().optional()})` |
| `loadSpaceUser` | PublicMethod | needs args | needs args | `object({connectionTarget:nativeEnum(ConnectionTarget),invitationId:zodUuid.optional(),spawnAreaId:zodUuid.optional(),clientPlatfor` |
| `requestGrapes` | PublicMethod | needs args | needs args | `object({grapesId:zodUuid,targetUserIds:array(zodUuid)})` |

### UserMapHistory (5)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `beginTransaction` | EditMapHistory | needs args | — | `object({kind:nativeEnum(SpaceTransactionCommandKind)})` |
| `endTransaction` | EditMapHistory | needs args | — | `object({kind:nativeEnum(SpaceTransactionCommandKind)})` |
| `redo` | MapEntityPermission.EditMapEntity | ran | — | — |
| `revertActiveTransaction` | EditMapHistory | error | — | — |
| `undo` | MapEntityPermission.EditMapEntity | ran | — | — |

### MapObjectBehaviorsRepo (4)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `createNewMapArea` | SpacePermission.UseStudio | — | — | `object({mapId:zodUuid,parent:AnyMapEntityTypedId,width:number(),height:number(),mapAreaType:nativeEnum(MapAreaType),wallsTexture:n` |
| `dispatchWebhookEvent` | PerformSystemAction | refused | refused | `object({behaviorsId:zodUuid,webhookId:string(),event:webhookEventSchema})` |
| `getOrCreateMapObjectBehaviors` | MapObjectPermission.EditMapObject | needs args | needs args | `object({mapObjectId:zodUuid})` |
| `updateAISummaryForMapArea` | PerformSystemAction | — | — | `object({mapAreaId:zodUuid,aiSummary:string()})` |

### MeetingIntegration (4)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `delete` | ManageMeetingIntegration | — | — | — |
| `toggleIntegration` | ManageMeetingIntegration | — | — | — |
| `updateName` | ManageMeetingIntegration | — | — | `object({name:string().min(1).max(255)})` |
| `updateSubscribedEvents` | ManageMeetingIntegration | — | — | `object({subscribedEvents:array(nativeEnum(q)).min(1,"At least one event type required")})` |

### SpotifyOAuthUserSecretRepo (4)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `getAuthenticationData` | PublicMethod | ran | ran | — |
| `isUserConnected` | PublicMethod | needs args | needs args | `zodUuid` |
| `registerSpaceUserOAuthToken` | PerformSystemAction | refused | refused | `object({tokenData:object({accessToken:string(),accessTokenExpiryDate:date(),refreshToken:string()}),userData:object({spaceUserId:z` |
| `unregisterAuthentication` | PublicMethod | ran | ran | — |

### GoogleCalendarEventRepo (3)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `createBulkSystemAction` | PerformSystemAction | refused | refused | `q` |
| `deleteBulkSystemAction` | PerformSystemAction | refused | refused | `Z` |
| `updateBulkSystemAction` | PerformSystemAction | refused | refused | `W` |

### GrapevineIntegrationRepo (3)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `ensureTenantForSpace` | SpacePermission.ManageGrapevine | needs args | error | — |
| `getConfigStatus` | SpacePermission.UseGatherAI | error | error | — |
| `mintAdminSSOGrant` | SpacePermission.ManageGrapevine | needs args | needs args | `K` |

### MeetingActionItemRepo (3)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `create` | PerformSystemAction | refused | refused | `J` |
| `createManualActionItem` | MeetingActionItemPermission.CreateManualActionItem | needs args | needs args | `T` |
| `update` | PerformSystemAction | refused | refused | `P` |

### SpaceRepo (3)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `broadcastSpaceNameUpdate` | PerformSystemAction | refused | refused | `object({spaceId:zodUuid,name:string()})` |
| `updateAllowAccessWhenSpaceDeactivated` | PerformSystemAction | refused | refused | `object({spaceId:zodUuid,allow:boolean()})` |
| `updateDailyInviteLimit` | PerformSystemAction | refused | refused | `object({spaceId:zodUuid,dailyInviteLimit:number().int().min(1).max(MAX_DAILY_INVITE_LIMIT)})` |

### StudioUserSession (3)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `close` | EditSessionData | ran | — | — |
| `heartbeat` | EditSessionData | error | — | — |
| `setDirty` | EditSessionData | needs args | — | `object({dirty:boolean()})` |

### UserFileRepo (3)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `createFile` | PerformSystemAction | refused | refused | `object({path:string(),type:nativeEnum(UploadedFileType),spaceId:zodUuid.optional(),uploaderUserId:zodUuid.nullable(),originalWidth` |
| `deleteFile` | PerformSystemAction | refused | refused | `object({fileId:zodUuid})` |
| `disassociateUploaderAfterUserDeletion` | PerformSystemAction | refused | refused | `object({fileId:zodUuid})` |

### CustomerPlanIntervalRepo (2)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `broadcastCustomerPlanIntervalsUpsert` | PerformSystemAction | refused | refused | `object({customerPlanIntervals:array(CustomerPlanInterval.schema)})` |
| `broadcastCustomerPlanIntervalUpdated` | PerformSystemAction | refused | refused | `object({updatedInterval:CustomerPlanInterval.schema})` |

### GuestPassRepo (2)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `createGuestPass` | PublicMethod | needs args | needs args | `object({hostId:zodUuid,meetingId:zodUuid.optional(),meetingJoinInfoLinkId:string().optional()})` |
| `kickGuestFromSpace` | GuestPassPermission.CanKick | needs args | needs args | `object({spaceUserId:zodUuid})` |

### MeetingJoinInfoRepo (2)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `create` | SpacePermission.CreateMeetingJoinInfo | needs args | needs args | `j` |
| `updateMeetingJoinInfoArea` | PerformSystemAction | refused | refused | `object({linkId:string(),areaId:zodUuid.nullable()})` |

### MeetingParticipant (2)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `markIntentionallyLeaving` | IntentionallyLeave | — | — | — |
| `respondToMeetingInvite` | AcceptMeeting | — | — | `nativeEnum(MeetingParticipantResponseStatus)` |

### MeetingRecording (2)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `markRecordingEnded` | SetRecordingDetails | — | — | `object({endReason:nativeEnum(z)})` |
| `markRecordingStarted` | SetRecordingDetails | — | — | — |

### MeetingRecordingRepo (2)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `markEgressEnded` | PerformSystemAction | refused | refused | `meetingRecordingSchema.zodType.pick({id:true,egressEndedAt:true}).extend({objectKey:string().optional(),size:union([bigint(),numbe` |
| `markRecordingDeleted` | PerformSystemAction | refused | refused | `meetingRecordingSchema.zodType.pick({id:true,deleterId:true})` |

### ModelSubscription (2)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `deleteSubscription` | UpdateSubscription | — | — | — |
| `updateSubscription` | UpdateSubscription | needs args | — | `object({modelIds:set(zodUuid),subscriptionType:nativeEnum(T)})` |

### MoveClusterToMeetingRepo (2)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `cancelMoveClusterToMeeting` | MoveClusterToMeetingPermission.CancelRequestToMoveCluster | needs args | needs args | `object({})` |
| `sendRequestToMoveClusterToMeeting` | MoveClusterToMeetingPermission.RequestToMoveCluster | needs args | needs args | `L` |

### PerformanceProfilingRepo (2)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `heapSnapshot` | StartCPUProfiling | needs args | needs args | `object({name:string().optional()})` |
| `startCPUProfiling` | StartCPUProfiling | needs args | needs args | `object({durationMs:number().optional(),name:string().optional()})` |

### PricingServiceSubscriptionRepo (2)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `broadcastPricingServiceSubscriptionUpsert` | PerformSystemAction | refused | refused | `object({pricingServiceSubscription:PricingServiceSubscription.schema})` |
| `broadcastSubscriptionUpdated` | PerformSystemAction | refused | refused | `object({updatedSubscription:PricingServiceSubscription.schema})` |

### SpaceUserCluster (2)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `requestToJoin` | PublicMethod | — | — | — |
| `setLocked` | SetClusterLocked | — | — | `boolean()` |

### StudioUserSessionRepo (2)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `getSessionAndLockFloor` | SpacePermission.UseStudio | needs args | needs args | `object({floorId:zodUuid,forceConnect:boolean()})` |
| `getStudioUserSession` | SpacePermission.UseBuildTool | needs args | needs args | `object({floorId:zodUuid,target:nativeEnum(StudioUserSessionTarget)})` |

### SyncedMusicPlayback (2)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `setPlaylist` | ControlSyncedMusicPlayback | — | — | `object({playlist:nativeEnum(W)})` |
| `stop` | ControlSyncedMusicPlayback | — | — | — |

### SyncedMusicPlaybackRepo (2)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `create` | SyncedMusicPlaybackPermission.ControlSyncedMusicPlayback | needs args | needs args | `object({playlist:nativeEnum(MusicPlaybackList)})` |
| `createOrUpdate` | SyncedMusicPlaybackPermission.ControlSyncedMusicPlayback | needs args | needs args | `object({playlist:nativeEnum(MusicPlaybackList)})` |

### AITeamData (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `setData` | PerformSystemAction | — | — | `K` |

### AITeamDataRepo (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `create` | PerformSystemAction | refused | refused | `K` |

### AreaAccessRequest (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `respondToAccessRequest` | RespondToAccessRequest | — | — | `nativeEnum(AreaAccessRequestResponseStatus)` |

### BaseCombinedCalendarEvent (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `getOrCreateMeeting` | AccessMeeting | — | — | `object({virtualCalendarEventRefId:string().optional(),source:enum(["auto_busy"]).optional()})` |

### ConnectionRepo (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `reportActivity` | PublicMethod | needs args | needs args | `object({isActive:boolean()})` |

### CoworkingSession (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `cancel` | CancelCoworkingSession | — | — | — |

### CoworkingSessionRepo (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `createCoworkingSession` | CoworkingSessionPermission.CreateCoworkingSession | needs args | needs args | `union([z,q,W])` |

### DeploySimulationRepo (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `simulateDeploy` | SimulateDeploy | needs args | needs args | `number()` |

### ExternalCalendarConnection (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `disconnectCalendars` | DisconnectCalendars | — | — | — |

### ExternalCalendarConnectionAccess (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `setVisibility` | SetVisibility | — | — | `object({visible:boolean()})` |

### GitHubAppInstallation (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `approve` | PerformSystemAction | — | — | `object({installationId:number()})` |

### GitHubOAuthUserSecretRepo (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `createGitHubOAuthUserSecret` | PerformSystemAction | refused | refused | `object({spaceUserId:zodUuid,accessToken:string(),expiresAt:date(),refreshToken:string(),refreshTokenExpiresAt:date(),gitHubUserId:` |

### GithubPullRequestRepo (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `upsert` | PerformSystemAction | refused | refused | `O` |

### MapObjectBehaviors (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `triggerGong` | PublicMethod | — | — | `object({message:string()})` |

### MapObjectRepo (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `createNewMapObject` | SpacePermission.UseBuildTool | needs args | needs args | `object({mapId:zodUuid,catalogItemVariantId:zodUuid,parent:AnyMapEntityTypedId,relativeX:number(),relativeY:number()})` |

### MeetingArtifactRepo (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `broadcastArtifactReadyOnActivityFeed` | PerformSystemAction | refused | refused | `q` |

### MeetingIntegrationRepo (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `createMeetingIntegration` | SpacePermission.ManageMeetingIntegrations | needs args | needs args | `object({name:string().min(1).max(255),webhookUrl:string().url(),subscribedEvents:array(nativeEnum(MeetingWebhookEventType)).min(1,` |

### MeetingJoinInfo (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `getOrCreateMeeting` | CreateMeetingFromCalendarEvent | — | — | — |

### MeetingJoinRequest (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `respondToJoinRequest` | RespondToJoinRequest | — | — | `nativeEnum(MeetingJoinRequestResponseStatus)` |

### MeetingMemoRepo (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `broadcastNewTranscriptContent` | PerformSystemAction | refused | refused | `object({event:object(GAME_EVENT_PAYLOADS[GameEvents.MeetingMemoTranscriptContentCreated]),targetUserIds:union([undefined(),set(zod` |

### SpaceInvitationRepo (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `createMemberGeneralInvite` | SpacePermission.InviteMemberOrGuest | needs args | ran | — |

### SpaceTemplate (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `delete` | FloorPermission.EditMap | needs args | refused | — |

### SpaceUserClusterJoinRequest (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `respondToJoinRequest` | RespondToJoinRequest | — | — | `nativeEnum(ClusterJoinRequestResponseStatus)` |

### SpaceUserUsageBasedBillingNotification (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `dismissNotification` | DismissNotification | — | — | — |

### StagedDeskAssignmentRepo (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `publishDraft` | SpacePermission.InviteMemberOrGuest | needs args | needs args | `object({mapId:zodUuid,shouldSendEmails:boolean()})` |

### ThirdPartyEventRepo (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `create` | PerformSystemAction | refused | refused | `object({type:enum([ThirdPartyEventProvider.GitHub]),spaceId:zodUuid,eventType:nativeEnum(GitHubEventType),title:string(),url:strin` |

### UsageBasedBillingMetricRepo (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `broadcastUsageUpdate` | PerformSystemAction | refused | refused | `object({event:object(GAME_EVENT_PAYLOADS[GameEvents.SpaceUsageUpdate])})` |

### UserFile (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `disassociateUploaderAfterUserDeletion` | PerformSystemAction | refused | refused | — |

### UserMapHistoryRepo (1)

| Action | Requires | Member | Admin | Arguments |
| --- | --- | --- | --- | --- |
| `getOrCreate` | SpacePermission.UseBuildTool | needs args | needs args | `object({userId:zodUuid,mapId:zodUuid})` |

## What the REST API answered

All 243 routes were called on both accounts against
`https://api.v2.gather.town/api/v2`, with real ids substituted for `:spaceId`,
`:spaceUserId` and `:userId`, and an empty JSON body on writes.

Safety was enforced by construction rather than by care: **every GET was sent**
(read-only), a non-GET was sent **only** when its path is scoped to the throwaway
space, and non-GET routes touching billing, orgs, users, admin, auth or webhooks
were never sent. 159 of 243 went out; 84 were withheld.

| Status | Member | Admin |
| --- | --- | --- |
| 200 | 19 | 31 |
| 201 | 0 | 2 |
| 400 | 94 | 94 |
| 401 | 1 | 1 |
| 403 | 38 | 24 |
| 404 | 7 | 7 |

### The privilege boundary is real, and it is mostly money

33 routes answered 2xx for the Admin against
19 for the Member. The 14 that separate them:

| Method | Path | Member | Admin |
| --- | --- | --- | --- |
| GET | `/pricing/:spaceId/payment-methods` | 403 | 200 |
| GET | `/pricing/:spaceId/get-invoices` | 403 | 200 |
| GET | `/pricing/:spaceId/linked-v1-capacity` | 403 | 200 |
| POST | `/spaces/:spaceId/github/regenerate-secret` | 403 | 200 |
| POST | `/spaces/:spaceId/chat/exports` | 403 | 201 |
| GET | `/spaces/:spaceId/api-keys` | 403 | 200 |
| POST | `/spaces/:spaceId/meetings/exports` | 403 | 201 |
| GET | `/spaces/:spaceId/meetings/integrations` | 403 | 200 |
| GET | `/pricing/:spaceId/subscriptions` | 403 | 200 |
| GET | `/pricing/:spaceId/subscriptions/model-counts` | 403 | 200 |
| GET | `/pricing/:spaceId/subscriptions/active-customer-plan-interval` | 403 | 200 |
| GET | `/pricing/:spaceId/subscriptions/customer-plan-intervals` | 403 | 200 |
| GET | `/pricing/:spaceId/subscriptions/payment-info` | 403 | 200 |
| GET | `/pricing/:spaceId/subscriptions/billing-country` | 403 | 200 |

Almost the whole boundary is billing and space administration — payment methods,
invoices, subscriptions, API keys, chat and meeting exports, the GitHub webhook
secret. Ordinary gameplay and chat reads are open to both roles.

### Gated for everyone

24 routes answered 403 for **both** accounts, including the space owner: the
entire `/sso/*` family (this space has no SSO configured) and every `/admin/*`
route. As with `PerformSystemAction` on the game plane, `/admin/*` is Gather
staff tooling — being a space Admin does not reach it. Treat those 65 admin
routes as out of reach for any normal account.

### Contract detail comes free

94 routes answered 400 with a zod issue list naming the missing field, its
expected type, and for enums the full set of valid values — for example
`/spaces/:spaceId/usage` enumerated `TestMetric | GuestMinutes |
MeetingTranscriptionMinutes | MeetingRecordingMinutes | …`. An empty-body call is
therefore a cheap way to recover a route's contract without ever satisfying it.

## HTTP endpoints

Called against `https://api.v2.gather.town/api/v2`. Route names are the client's
own dotted identifiers; paths are as declared in the contract, `:param` style.

The **Member** and **Admin** columns are the HTTP status each account got when
the route was actually called. `skip` means the call was withheld by the safety
rules described above, so that route is untested.

### spaces (89)

| Method | Path | Member | Admin | Route |
| --- | --- | --- | --- | --- |
| POST | `/spaces/:spaceId/api-keys` | 400 | 400 | `spaces.apiKeys.create` |
| GET | `/spaces/:spaceId/api-keys` | 403 | 200 | `spaces.apiKeys.list` |
| DELETE | `/spaces/:spaceId/api-keys/:apiKeyId` | 400 | 400 | `spaces.apiKeys.revoke` |
| GET | `/spaces/:spaceId/chat/activity-feed` | 200 | 200 | `spaces.chat.activityFeed.list` |
| POST | `/spaces/:spaceId/chat/activity-feed/toggle-read-status` | 400 | 400 | `spaces.chat.activityFeed.toggleReadStatus` |
| POST | `/spaces/:spaceId/chat/channels` | 400 | 400 | `spaces.chat.channels.create` |
| DELETE | `/spaces/:spaceId/chat/channels/:channelId` | 400 | 400 | `spaces.chat.channels.delete` |
| GET | `/spaces/:spaceId/chat/channel-exists` | 400 | 400 | `spaces.chat.channels.exists` |
| GET | `/spaces/:spaceId/chat/channels` | 200 | 200 | `spaces.chat.channels.list` |
| POST | `/spaces/:spaceId/chat/channels/:channelId/bulk-add-members` | 400 | 400 | `spaces.chat.channels.members.bulkAdd` |
| POST | `/spaces/:spaceId/chat/channels/:channelId/bulk-remove-members` | 400 | 400 | `spaces.chat.channels.members.bulkRemove` |
| POST | `/spaces/:spaceId/chat/channels/:channelId/join` | 400 | 400 | `spaces.chat.channels.members.join` |
| POST | `/spaces/:spaceId/chat/channels/:channelId/messages` | 400 | 400 | `spaces.chat.channels.messages.create` |
| DELETE | `/spaces/:spaceId/chat/channels/:channelId/messages/:messageId` | 400 | 400 | `spaces.chat.channels.messages.delete` |
| GET | `/spaces/:spaceId/chat/channels/:channelId/messages` | 400 | 400 | `spaces.chat.channels.messages.list` |
| POST | `/spaces/:spaceId/chat/channels/:channelId/messages/:messageId/reactions` | 400 | 400 | `spaces.chat.channels.messages.reactions.create` |
| DELETE | `/spaces/:spaceId/chat/channels/:channelId/messages/:messageId/reactions` | 400 | 400 | `spaces.chat.channels.messages.reactions.delete` |
| PATCH | `/spaces/:spaceId/chat/channels/:channelId/messages/:messageId` | 400 | 400 | `spaces.chat.channels.messages.update` |
| DELETE | `/spaces/:spaceId/chat/channels/:channelId/read-cursors` | 400 | 400 | `spaces.chat.channels.readCursors.delete` |
| POST | `/spaces/:spaceId/chat/channels/:channelId/read-cursors` | 400 | 400 | `spaces.chat.channels.readCursors.update` |
| POST | `/spaces/:spaceId/chat/channels/:channelId/messages/:messageId/thread-participants` | 400 | 400 | `spaces.chat.channels.threadParticipants.subscribe` |
| DELETE | `/spaces/:spaceId/chat/channels/:channelId/messages/:messageId/thread-participants` | 400 | 400 | `spaces.chat.channels.threadParticipants.unsubscribe` |
| POST | `/spaces/:spaceId/chat/channels/:channelId/typing` | 400 | 400 | `spaces.chat.channels.typing.update` |
| PATCH | `/spaces/:spaceId/chat/channels/:channelId` | 400 | 400 | `spaces.chat.channels.update` |
| PATCH | `/spaces/:spaceId/chat/channels/:channelId/preferences` | 400 | 400 | `spaces.chat.channels.upsertPreferences` |
| POST | `/spaces/:spaceId/chat/exports` | 403 | 201 | `spaces.chat.exports.createSession` |
| GET | `/spaces/:spaceId/chat/exports/:sessionId/channels` | 400 | 400 | `spaces.chat.exports.getChannels` |
| GET | `/spaces/:spaceId/chat/exports/:sessionId/messages` | 400 | 400 | `spaces.chat.exports.getMessages` |
| GET | `/spaces/:spaceId/chat/exports/:sessionId` | 400 | 400 | `spaces.chat.exports.getSession` |
| GET | `/spaces/:spaceId/chat/exports/:sessionId/space` | 400 | 400 | `spaces.chat.exports.getSpaceMetadata` |
| GET | `/spaces/:spaceId/chat/exports/:sessionId/users` | 400 | 400 | `spaces.chat.exports.getUsers` |
| POST | `/spaces` | skip | skip | `spaces.create` |
| POST | `/spaces/:spaceId/chat/chats/files` | 400 | 400 | `spaces.files.chat.create` |
| POST | `/spaces/:spaceId/files` | 400 | 400 | `spaces.files.create` |
| DELETE | `/spaces/:spaceId/files/:fileId` | 400 | 400 | `spaces.files.delete` |
| GET | `/spaces/:spaceId/files/:fileId/download` | 400 | 400 | `spaces.files.download` |
| GET | `/spaces/:spaceId/files/:fileId` | 400 | 400 | `spaces.files.get` |
| POST | `/spaces/:spaceId/support-request-files` | 400 | 400 | `spaces.files.supportRequest.create` |
| POST | `/spaces/:spaceId/floors/:floorId/preview` | 400 | 400 | `spaces.floors.preview.upload` |
| GET | `/spaces/:spaceId/gather-ai/channels` | 200 | 200 | `spaces.gatherAI.channels.list` |
| POST | `/spaces/:spaceId/gather-ai/channels/:channelId/messages` | 400 | 400 | `spaces.gatherAI.messages.create` |
| GET | `/spaces/:spaceId` | 200 | 200 | `spaces.get` |
| GET | `/spaces/:spaceId/insights-details/:metric` | 400 | 400 | `spaces.insights.details.get` |
| GET | `/spaces/:spaceId/insights/:metric` | 400 | 400 | `spaces.insights.get` |
| GET | `/spaces/:spaceId/insights-summary/:metrics` | 400 | 400 | `spaces.insights.summary.get` |
| GET | `/spaces/:spaceId/artifacts/:artifactId/content` | 400 | 400 | `spaces.meeting.artifacts.content` |
| DELETE | `/spaces/:spaceId/artifacts/:artifactId/content/:contentType` | 400 | 400 | `spaces.meeting.artifacts.deleteContent` |
| GET | `/spaces/:spaceId/meetings/:meetingId/artifacts` | 400 | 400 | `spaces.meeting.artifacts.list` |
| POST | `/spaces/:spaceId/artifacts/:artifactId/share-with-invitees` | 400 | 400 | `spaces.meeting.artifacts.shareWithInvitees` |
| POST | `/spaces/:spaceId/meetings/exports` | 403 | 201 | `spaces.meeting.exports.createSession` |
| GET | `/spaces/:spaceId/meetings/exports/:sessionId/meetings` | 400 | 400 | `spaces.meeting.exports.getMeetings` |
| GET | `/spaces/:spaceId/meetings/exports/:sessionId` | 400 | 400 | `spaces.meeting.exports.getSession` |
| POST | `/spaces/:spaceId/meetings/integrations` | 400 | 400 | `spaces.meeting.integrations.create` |
| DELETE | `/spaces/:spaceId/meetings/integrations/:integrationId` | 400 | 400 | `spaces.meeting.integrations.delete` |
| GET | `/spaces/:spaceId/meetings/integrations/:integrationId` | 400 | 400 | `spaces.meeting.integrations.get` |
| GET | `/spaces/:spaceId/meetings/integrations` | 403 | 200 | `spaces.meeting.integrations.list` |
| PATCH | `/spaces/:spaceId/meetings/integrations/:integrationId` | 400 | 400 | `spaces.meeting.integrations.update` |
| GET | `/spaces/:spaceId/meeting-memos-default-prompts` | 200 | 200 | `spaces.meeting.memos.defaults` |
| POST | `/spaces/:spaceId/meeting-memos/feedback` | 400 | 400 | `spaces.meeting.memos.feedback.create` |
| POST | `/spaces/:spaceId/meeting-memos/:meetingId` | 400 | 400 | `spaces.meeting.memos.generate` |
| POST | `/spaces/:spaceId/meeting/:meetingId/meetingMemo/generateFullNote` | 400 | 400 | `spaces.meeting.memos.generateFullNote` |
| GET | `/spaces/:spaceId/meeting-memos/:meetingId` | 400 | 400 | `spaces.meeting.memos.get` |
| GET | `/spaces/:spaceId/meeting-memos` | 200 | 200 | `spaces.meeting.memos.list` |
| POST | `/spaces/:spaceId/meeting-memos/:meetingId/regenerate` | 400 | 400 | `spaces.meeting.memos.regenerate` |
| POST | `/spaces/:spaceId/meeting-memos/:meetingId/token` | 400 | 400 | `spaces.meeting.memos.tokens.create` |
| POST | `/spaces/:spaceId/meeting-memos/:meetingId/transcripts` | 400 | 400 | `spaces.meeting.memos.transcripts.create` |
| GET | `/spaces/:spaceId/meeting-memos/:meetingId/transcripts` | 400 | 400 | `spaces.meeting.memos.transcripts.list` |
| GET | `/spaces/:spaceId/users/me/meetings/:meetingId` | 400 | 400 | `spaces.meetings.get` |
| GET | `/spaces/:spaceId/users/me/meetings` | 400 | 400 | `spaces.meetings.list` |
| GET | `/spaces/:spaceId/nooks` | 404 | 404 | `spaces.nooks.list` |
| GET | `/spaces/:spaceId/organization` | 200 | 200 | `spaces.organization.get` |
| GET | `/spaces/:spaceId/search/messages` | 400 | 400 | `spaces.search.messages.list` |
| POST | `/spaces/:spaceId/sso` | 403 | 403 | `spaces.sso.create` |
| POST | `/spaces/:spaceId/sso/email-domains` | 400 | 400 | `spaces.sso.emailDomains.create` |
| DELETE | `/spaces/:spaceId/sso/email-domains` | 400 | 400 | `spaces.sso.emailDomains.delete` |
| GET | `/spaces/:spaceId/sso/email-domains` | 403 | 403 | `spaces.sso.emailDomains.list` |
| POST | `/spaces/:spaceId/sso/email-domain/verify` | 403 | 403 | `spaces.sso.emailDomains.verification.create` |
| GET | `/spaces/:spaceId/sso` | 403 | 403 | `spaces.sso.get` |
| DELETE | `/spaces/:spaceId/sso/linked-spaces` | 400 | 400 | `spaces.sso.linkedSpaces.delete` |
| GET | `/spaces/:spaceId/sso/linked-spaces` | 403 | 403 | `spaces.sso.linkedSpaces.list` |
| GET | `/spaces/:spaceId/sso/linked-space-source` | 403 | 403 | `spaces.sso.linkedSpaces.source.get` |
| PATCH | `/spaces/:spaceId/sso/linked-spaces` | 400 | 400 | `spaces.sso.linkedSpaces.update` |
| GET | `/spaces/:spaceId/sso/settings` | 403 | 403 | `spaces.sso.settings.get` |
| POST | `/spaces/:spaceId/surveys/onboarding` | 400 | 400 | `spaces.surveys.onboarding.create` |
| GET | `/spaces/:spaceId/users/me` | 200 | 200 | `spaces.users.get` |
| POST | `/spaces/:spaceId/objects/:objectId/tokens` | 400 | 400 | `spaces.webhookObjectTokens.create` |
| GET | `/spaces/:spaceId/objects/:objectId/tokens` | 400 | 400 | `spaces.webhookObjectTokens.get` |
| GET | `/spaces/:spaceId/objects/tokens` | 200 | 200 | `spaces.webhookObjectTokens.list` |
| DELETE | `/spaces/:spaceId/objects/:objectId/tokens` | 400 | 400 | `spaces.webhookObjectTokens.revoke` |

### admin (63)

| Method | Path | Member | Admin | Route |
| --- | --- | --- | --- | --- |
| POST | `/admin/audit-events` | skip | skip | `admin.auditEvents.list` |
| GET | `/admin/av-client-state-sessions/:sessionId/userFeedback` | 403 | 403 | `admin.avClientStateSessions.feedback.get` |
| GET | `/admin/av-client-state-sessions/:sessionId` | 403 | 403 | `admin.avClientStateSessions.get` |
| GET | `/admin/av-client-state-sessions` | 403 | 403 | `admin.avClientStateSessions.list` |
| GET | `/admin/catalog-items` | 403 | 403 | `admin.catalogItems.list` |
| PATCH | `/admin/catalog-items/:catalogItemId` | skip | skip | `admin.catalogItems.update` |
| GET | `/admin/catalog-items/:catalogItemId/variants` | 403 | 403 | `admin.catalogItems.variants.list` |
| PATCH | `/admin/catalog-item-variant/:catalogItemVariantId` | skip | skip | `admin.catalogItems.variants.update` |
| GET | `/admin/conversation-metadata/meeting/:meetingId` | 403 | 403 | `admin.conversationMetadata.get` |
| POST | `/admin/organizations/:organizationId/email-domains` | skip | skip | `admin.organizations.addEmailDomain` |
| POST | `/admin/organizations/:organizationId/spaces` | skip | skip | `admin.organizations.addSpace` |
| POST | `/admin/organizations` | skip | skip | `admin.organizations.create` |
| GET | `/admin/organizations/db-search` | 400 | 400 | `admin.organizations.dbSearch` |
| GET | `/admin/organizations` | 403 | 403 | `admin.organizations.get` |
| POST | `/admin/organizations/import` | skip | skip | `admin.organizations.import` |
| DELETE | `/admin/organizations/:organizationId/email-domains/:domain` | skip | skip | `admin.organizations.removeEmailDomain` |
| DELETE | `/admin/organizations/:organizationId/spaces/:spaceId` | skip | skip | `admin.organizations.removeSpace` |
| PATCH | `/admin/organizations/:organizationId` | skip | skip | `admin.organizations.update` |
| PATCH | `/admin/organizations/:organizationId/spaces/:spaceId` | skip | skip | `admin.organizations.updateSpace` |
| DELETE | `/admin/spaces/:spaceId` | skip | skip | `admin.spaces.delete` |
| GET | `/admin/spaces/:spaceId` | 403 | 403 | `admin.spaces.get` |
| GET | `/admin/spaces/:spaceId/organization` | 403 | 403 | `admin.spaces.getOrganization` |
| PATCH | `/admin/spaces/:spaceId/name` | skip | skip | `admin.spaces.name.update` |
| POST | `/admin/spaces/:spaceId/revoke-tokens` | skip | skip | `admin.spaces.revokeTokens` |
| PATCH | `/admin/spaces/:spaceId/settings/allowAccessWhenDeactivated` | skip | skip | `admin.spaces.settings.allowAccessWhenDeactivated.update` |
| PATCH | `/admin/spaces/:spaceId/settings/dailyInviteLimit` | skip | skip | `admin.spaces.settings.dailyInviteLimit.update` |
| PATCH | `/admin/spaces/:spaceId` | skip | skip | `admin.spaces.toggleStaffAccess` |
| GET | `/admin/spaces/:spaceId/users` | 403 | 403 | `admin.spaces.users.list` |
| POST | `/admin/spaces/:spaceId/users/:spaceUserId/role` | skip | skip | `admin.spaces.users.updateRole` |
| GET | `/admin/subscriptions/:subscriptionId/linked-v1-space-capacity` | 400 | 400 | `admin.subscriptions.adminGetLinkedV1SpaceCapacity` |
| POST | `/admin/subscriptions/:subscriptionId/change-owner` | skip | skip | `admin.subscriptions.changeOwner` |
| POST | `/admin/subscriptions/:subscriptionId/intervals` | skip | skip | `admin.subscriptions.createInterval` |
| POST | `/admin/spaces/:spaceId/create-paid-subscription` | skip | skip | `admin.subscriptions.createPaidSubscription` |
| DELETE | `/admin/subscriptions/:subscriptionId` | skip | skip | `admin.subscriptions.delete` |
| DELETE | `/admin/subscriptions/:subscriptionId/intervals/:intervalId` | skip | skip | `admin.subscriptions.deleteInterval` |
| GET | `/admin/subscriptions/:subscriptionId` | 400 | 400 | `admin.subscriptions.get` |
| GET | `/admin/spaces/:spaceId/subscriptions` | 403 | 403 | `admin.subscriptions.getBySpace` |
| GET | `/admin/subscriptions/:subscriptionId/intervals/:intervalId` | 400 | 400 | `admin.subscriptions.getInterval` |
| GET | `/admin/subscriptions/:subscriptionId/intervals` | 400 | 400 | `admin.subscriptions.getIntervals` |
| PATCH | `/admin/subscriptions/:subscriptionId` | skip | skip | `admin.subscriptions.update` |
| PATCH | `/admin/subscriptions/:subscriptionId/intervals/:intervalId` | skip | skip | `admin.subscriptions.updateInterval` |
| POST | `/admin/super-admin-users` | skip | skip | `admin.superAdminUsers.create` |
| DELETE | `/admin/super-admin-users/:userAccountId` | skip | skip | `admin.superAdminUsers.delete` |
| GET | `/admin/super-admin-users` | 403 | 403 | `admin.superAdminUsers.list` |
| GET | `/admin/super-admin-users/:userAccountId/roles` | 403 | 403 | `admin.superAdminUsers.roles.list` |
| PATCH | `/admin/super-admin-users/:userAccountId` | skip | skip | `admin.superAdminUsers.update` |
| GET | `/admin/telemetry/:serviceName/firetiger-traces` | 400 | 400 | `admin.telemetry.firetigerTraceEvents.get` |
| GET | `/admin/telemetry/:serviceName/firetiger-traces/cluster/:clusterId` | 400 | 400 | `admin.telemetry.firetigerTraceEvents.getByClusterId` |
| GET | `/admin/telemetry/:serviceName/firetiger-traces/meeting/:meetingId` | 400 | 400 | `admin.telemetry.firetigerTraceEvents.getByMeetingId` |
| GET | `/admin/telemetry/:serviceName/firetiger-traces/operation/:operationName` | 400 | 400 | `admin.telemetry.firetigerTraceEvents.getByOperationName` |
| GET | `/admin/telemetry/:serviceName/newrelic` | 400 | 400 | `admin.telemetry.newrelic.get` |
| GET | `/admin/telemetry/:serviceName/newrelic/cluster/:clusterId` | 400 | 400 | `admin.telemetry.newrelic.getByClusterId` |
| GET | `/admin/telemetry/:serviceName/newrelic/meeting/:meetingId` | 400 | 400 | `admin.telemetry.newrelic.getByMeetingId` |
| GET | `/admin/telemetry/:serviceName/newrelic/operation/:operationName` | 400 | 400 | `admin.telemetry.newrelic.getByOperationName` |
| GET | `/admin/users/:userAccountId/artifacts` | 403 | 403 | `admin.users.artifacts.list` |
| POST | `/admin/users/:userAccountId/cancel-subscriptions` | skip | skip | `admin.users.cancelSubscriptions` |
| DELETE | `/admin/users` | skip | skip | `admin.users.delete` |
| POST | `/admin/users/deletion-preflight` | skip | skip | `admin.users.deletionPreflight` |
| GET | `/admin/users/email-or-id/:emailOrId` | 403 | 403 | `admin.users.getByEmailOrId` |
| POST | `/admin/users/:userAccountId/revoke-tokens` | skip | skip | `admin.users.revokeTokens` |
| GET | `/admin/users/:userAccountId/spaces` | 403 | 403 | `admin.users.spaces.list` |
| GET | `/admin/wearables` | 403 | 403 | `admin.wearables.list` |
| PATCH | `/admin/wearables/:wearableId` | skip | skip | `admin.wearables.update` |

### v2 (26)

| Method | Path | Member | Admin | Route |
| --- | --- | --- | --- | --- |
| POST | `/exp-ai/grapevine-mcp` | skip | skip | `v2.expAi.grapevineMcp.post` |
| POST | `/exp-ai/pr-summary` | skip | skip | `v2.expAi.prSummary.create` |
| GET | `/me/api-keys` | 401 | 401 | `v2.me.apiKeyMetadata` |
| GET | `/meeting-join-info/:linkId` | 404 | 404 | `v2.meetingJoinInfo.get` |
| POST | `/pricing/:spaceId/create-intent` | skip | skip | `v2.pricing.createIntent` |
| GET | `/pricing/:spaceId/get-invoice-from-provider/:invoiceId` | 400 | 400 | `v2.pricing.getInvoiceFromProvider` |
| GET | `/pricing/:spaceId/get-invoices` | 403 | 200 | `v2.pricing.getInvoices` |
| GET | `/pricing/:spaceId/linked-v1-capacity` | 403 | 200 | `v2.pricing.getLinkedV1SpaceCapacity` |
| POST | `/pricing/:spaceId/link-v1-space-to-v2` | skip | skip | `v2.pricing.linkV1SpaceToV2` |
| GET | `/pricing/:spaceId/payment-methods` | 403 | 200 | `v2.pricing.paymentMethods` |
| POST | `/pricing/:spaceId/proration-subscription-preview` | skip | skip | `v2.pricing.prorationSubscriptionPreview` |
| POST | `/pricing/:spaceId/start-paid-subscription` | skip | skip | `v2.pricing.startPaidSubscription` |
| POST | `/pricing/:spaceId/subscription-preview` | skip | skip | `v2.pricing.subscriptionPreview` |
| POST | `/pricing/:spaceId/subscription-previewV2` | skip | skip | `v2.pricing.subscriptionPreviewV2` |
| POST | `/pricing/:spaceId/unlink-v1-space` | skip | skip | `v2.pricing.unlinkV1Space` |
| GET | `/spaces/:spaceId/areas` | 200 | 200 | `v2.spaces.areas.get` |
| GET | `/spaces/:spaceId/areas/for-meeting` | 200 | 200 | `v2.spaces.areas.getSuitableForMeeting` |
| POST | `/spaces/:spaceId/github/regenerate-secret` | 403 | 200 | `v2.spaces.github.regenerateSecret` |
| POST | `/spaces/:spaceId/meeting-join-info` | 400 | 400 | `v2.spaces.meetingJoinInfo.create` |
| GET | `/spaces/:spaceId/meeting-join-info/:linkId` | 404 | 404 | `v2.spaces.meetingJoinInfo.get` |
| PATCH | `/spaces/:spaceId/meeting-join-info/:linkId` | 400 | 400 | `v2.spaces.meetingJoinInfo.update` |
| GET | `/spaces/:spaceId/usage` | 400 | 400 | `v2.spaces.usageBasedBilling.usageForSpace` |
| GET | `/pricing/:subscriptionId/usage` | 400 | 400 | `v2.spaces.usageBasedBilling.usageForSubscription` |
| GET | `/spaces/:spaceId/users/:userAccountId/base-calendar-events` | 404 | 404 | `v2.spaces.users.baseCalendarEvents.list` |
| POST | `/spaces/:spaceId/users/me/base-calendar-events/sync` | skip | skip | `v2.spaces.users.baseCalendarEvents.sync` |
| GET | `/space-templates` | 200 | 200 | `v2.spaceTemplates.get` |

### pricing (16)

| Method | Path | Member | Admin | Route |
| --- | --- | --- | --- | --- |
| POST | `/pricing/:spaceId/subscriptions/add-coupon` | skip | skip | `pricing.addCoupon` |
| POST | `/pricing/:spaceId/subscriptions/apply-one-time-discount` | skip | skip | `pricing.applyOneTimeDiscount` |
| POST | `/pricing/:spaceId/subscriptions` | skip | skip | `pricing.cancelSubscription` |
| GET | `/pricing/:spaceId/subscriptions/create-customer-payment-link` | 400 | 400 | `pricing.createCustomerPaymentLink` |
| GET | `/pricing/:spaceId/subscriptions/active-customer-plan-interval` | 403 | 200 | `pricing.getActiveCustomerPlanInterval` |
| GET | `/pricing/:spaceId/subscriptions/customer-plan-intervals` | 403 | 200 | `pricing.getCustomerPlanIntervals` |
| GET | `/pricing/:spaceId/subscriptions/model-counts` | 403 | 200 | `pricing.getModelCountsLostOnCancel` |
| GET | `/pricing/:spaceId/subscriptions/payment-info` | 403 | 200 | `pricing.getPaymentMethod` |
| GET | `/pricing/:spaceId/subscriptions` | 403 | 200 | `pricing.getSubscription` |
| GET | `/pricing/:spaceId/subscriptions/billing-country` | 403 | 200 | `pricing.getSubscriptionBillingCountry` |
| GET | `/pricing/:spaceId/subscriptions/by-space` | 200 | 200 | `pricing.getSubscriptionBySpace` |
| GET | `/pricing/subscriptions/:subscriptionId/space-id-and-name` | 400 | 400 | `pricing.getSubscriptionSpaceIdAndName` |
| POST | `/pricing/:spaceId/subscriptions/renew` | skip | skip | `pricing.renewSubscription` |
| POST | `/pricing/:spaceId/test-simulate-daily-proration` | skip | skip | `pricing.simulateDailyProration` |
| POST | `/pricing/:spaceId/subscriptions/switch-billing-interval` | skip | skip | `pricing.switchBillingInterval` |
| POST | `/pricing/:spaceId/subscriptions/update-quantity` | skip | skip | `pricing.updateSubscriptionQuantity` |

### webhooks (11)

| Method | Path | Member | Admin | Route |
| --- | --- | --- | --- | --- |
| POST | `/hooks/assemblyai/transcription` | skip | skip | `webhooks.assemblyAi.transcription` |
| POST | `/hooks/audio-recordings/s3` | skip | skip | `webhooks.audioRecording.receive` |
| POST | `/hooks/github/spaces/:spaceId` | skip | skip | `webhooks.github.receive` |
| POST | `/hooks/github/app-webhook` | skip | skip | `webhooks.github.receiveApp` |
| POST | `/hooks/grapevine/task-extraction` | skip | skip | `webhooks.grapevine.receiveTaskExtraction` |
| POST | `/spaces/:spaceId/chat/hooks/:token` | skip | skip | `webhooks.incomingChat.receive` |
| POST | `/hooks/livekit/recording/:recordingId/status` | skip | skip | `webhooks.livekit.receive` |
| POST | `/hooks/meeting-summaries/s3` | skip | skip | `webhooks.meetingSummary.receive` |
| POST | `/hooks/spaces/:spaceId/objects/:objectId` | skip | skip | `webhooks.spaceObject.receive` |
| POST | `/hooks/stripe/app-webhook` | skip | skip | `webhooks.stripe.receive` |
| POST | `/webhooks/workos/8XIspKIObRYIHTDXVeCTuqEe` | skip | skip | `webhooks.workos.receive` |

### auth (8)

| Method | Path | Member | Admin | Route |
| --- | --- | --- | --- | --- |
| POST | `/auth/google/authorize` | skip | skip | `auth.google.authorization.create` |
| POST | `/auth/google/token` | skip | skip | `auth.google.token.create` |
| POST | `/auth/logout` | skip | skip | `auth.logout.create` |
| POST | `/auth/otp-requests` | skip | skip | `auth.otpRequests.create` |
| POST | `/auth/otp-requests/verify` | skip | skip | `auth.otpRequests.verify.create` |
| POST | `/auth/sso/initiate` | skip | skip | `auth.sso.initiate` |
| GET | `/auth/sso/member` | 400 | 400 | `auth.sso.members.get` |
| GET | `/auth/sso/token-swap` | 400 | 400 | `auth.sso.swapToken` |

### integrations (8)

| Method | Path | Member | Admin | Route |
| --- | --- | --- | --- | --- |
| POST | `/spaces/:spaceId/integrations/:integrationKey/install` | 400 | 400 | `integrations.chatIntegrations.install` |
| POST | `/integrations/cloudflare/siteverify` | skip | skip | `integrations.cloudflare.verify` |
| POST | `/spaces/:spaceId/users/me/github/disconnect` | skip | skip | `integrations.github.disconnect` |
| GET | `/spaces/:spaceId/users/me/github/getOrganizationInfo` | 404 | 404 | `integrations.github.getOrganizationInfo` |
| GET | `/spaces/:spaceId/users/me/github/getOrganizationMembers` | 404 | 404 | `integrations.github.getOrganizationMembers` |
| POST | `/spaces/:spaceId/users/me/auth/github/initiate` | skip | skip | `integrations.github.initiate` |
| GET | `/integrations/spotify/:spaceId/authenticate` | 200 | 200 | `integrations.spotify.generateOAuthUrl` |
| GET | `/integrations/spotify/redirect` | 400 | 400 | `integrations.spotify.redirect` |

### users (6)

| Method | Path | Member | Admin | Route |
| --- | --- | --- | --- | --- |
| GET | `/users/me` | 200 | 200 | `users.get` |
| POST | `/users/me/push-devices` | skip | skip | `users.pushDevices.create` |
| DELETE | `/users/me/push-devices/:pushDeviceId` | skip | skip | `users.pushDevices.delete` |
| GET | `/users/me/owned-spaces` | 200 | 200 | `users.spaces.listOwned` |
| GET | `/users/me/recent-spaces` | 200 | 200 | `users.spaces.listRecent` |
| PATCH | `/users/me` | skip | skip | `users.update` |

### releases (4)

| Method | Path | Member | Admin | Route |
| --- | --- | --- | --- | --- |
| POST | `/releases/browser/:browserName/:releaseCommit/:releaseChannel` | skip | skip | `releases.browser.get` |
| GET | `/releases/desktop/:platform/:releaseVersion/:releaseChannel` | 400 | 400 | `releases.desktop.get` |
| GET | `/releases/desktop/latest` | 200 | 200 | `releases.desktop.latest.get` |
| GET | `/releases/latest/:platform/:appVersion` | 400 | 400 | `releases.desktop.latest.installer.get` |

### hubspot (3)

| Method | Path | Member | Admin | Route |
| --- | --- | --- | --- | --- |
| POST | `/hubspot/contacts/create` | skip | skip | `hubspot.contacts.create` |
| PATCH | `/hubspot/contacts/update-number-properties` | skip | skip | `hubspot.contacts.numberProperties.update` |
| PATCH | `/hubspot/contacts/update` | skip | skip | `hubspot.contacts.update` |

### eligibilitySurveySubmission (2)

| Method | Path | Member | Admin | Route |
| --- | --- | --- | --- | --- |
| GET | `/eligibility-survey-submission` | 200 | 200 | `eligibilitySurveySubmission.get` |
| PATCH | `/eligibility-survey-submission` | skip | skip | `eligibilitySurveySubmission.upsert` |

### internals (2)

| Method | Path | Member | Admin | Route |
| --- | --- | --- | --- | --- |
| POST | `/internal/logs` | skip | skip | `internals.logs.create` |
| POST | `/newrelic/custom-events` | skip | skip | `internals.newRelic.customEvents.create` |

### browserExtension (1)

| Method | Path | Member | Admin | Route |
| --- | --- | --- | --- | --- |
| POST | `/browser-extension/config` | skip | skip | `browserExtension.config.get` |

### scheduledTasks (1)

| Method | Path | Member | Admin | Route |
| --- | --- | --- | --- | --- |
| POST | `/scheduled-tasks/delete-recordings` | skip | skip | `scheduledTasks.deleteRecordings.receive` |

### supportRequests (1)

| Method | Path | Member | Admin | Route |
| --- | --- | --- | --- | --- |
| POST | `/support-requests` | skip | skip | `supportRequests.create` |

### user (1)

| Method | Path | Member | Admin | Route |
| --- | --- | --- | --- | --- |
| GET | `/user/exists` | 400 | 400 | `user.exists` |

### wearables (1)

| Method | Path | Member | Admin | Route |
| --- | --- | --- | --- | --- |
| GET | `/wearables/:wearableId` | 404 | 404 | `wearables.get` |

## Permissions

Every distinct `requiredPermission` seen on an action, by frequency.

| Permission | Actions |
| --- | --- |
| PerformSystemAction | 60 |
| UpdateSpaceSetting | 14 |
| PublicMethod | 13 |
| EditMapArea | 11 |
| EditMapEntity | 8 |
| FloorPermission.EditMap | 8 |
| UpdateOnboardingStatus | 8 |
| SpaceUserPermission.Move | 7 |
| SpacePermission.InviteMemberOrGuest | 6 |
| EditMap | 5 |
| SpaceUserPermission.UpdateCustomStatus | 5 |
| BotManagement | 4 |
| EditMapObject | 4 |
| ManageMeetingIntegration | 4 |
| MapEntityPermission.EditMapEntity | 4 |
| Start | 4 |
| UpdateActionItem | 4 |
| CanRespond | 3 |
| EditMapHistory | 3 |
| EditSessionData | 3 |
| MeetingPermission.AssignMeetingArea | 3 |
| SpacePermission.UseBuildTool | 3 |
| SpaceUserPermission.BroadcastMessage | 3 |
| SpaceUserPermission.UpdateFollowing | 3 |
| SpaceUserPermission.UpdateHandRaised | 3 |
| AddParticipant | 2 |
| ChangeLockState | 2 |
| ControlSyncedMusicPlayback | 2 |
| RespondToJoinRequest | 2 |
| SetRecordingDetails | 2 |
| SpacePermission.InviteAdmin | 2 |
| SpacePermission.ManageGrapevine | 2 |
| SpacePermission.UseStudio | 2 |
| SpaceUserPermission.AssignGitHubUserId | 2 |
| SpaceUserPermission.ClaimUnclaimDesk | 2 |
| SpaceUserPermission.Deactivate | 2 |
| SpaceUserPermission.UpdateDancing | 2 |
| SpaceUserPermission.UpdateSpeaking | 2 |
| StartCPUProfiling | 2 |
| StartRecordingIncludingAVRecordingAndOrTranscription | 2 |
| SyncedMusicPlaybackPermission.ControlSyncedMusicPlayback | 2 |
| UpdateSubscription | 2 |
| AcceptMeeting | 1 |
| AccessMeeting | 1 |
| AssignMeetingArea | 1 |
| Cancel | 1 |
| CancelCoworkingSession | 1 |
| CanDestroy | 1 |
| CanReset | 1 |
| CoworkingSessionPermission.CreateCoworkingSession | 1 |
| CreateMeetingFromCalendarEvent | 1 |
| DisconnectCalendars | 1 |
| DismissNotification | 1 |
| End | 1 |
| ExternalCalendarConnectionPermission.InitiateAuthFlow | 1 |
| GuestPassPermission.CanKick | 1 |
| IntentionallyLeave | 1 |
| MapObjectPermission.EditMapObject | 1 |
| MeetingActionItemPermission.CreateManualActionItem | 1 |
| MoveClusterToMeetingPermission.CancelRequestToMoveCluster | 1 |
| MoveClusterToMeetingPermission.RequestToMoveCluster | 1 |
| RemoveParticipant | 1 |
| RequestToAccess | 1 |
| RequestToJoin | 1 |
| RespondToAccessRequest | 1 |
| SetClusterLocked | 1 |
| SetVisibility | 1 |
| SimulateDeploy | 1 |
| SpacePermission.CreateMeetingJoinInfo | 1 |
| SpacePermission.ManageMeetingIntegrations | 1 |
| SpacePermission.UseGatherAI | 1 |
| SpaceUserPermission.BroadcastEmote | 1 |
| SpaceUserPermission.ClearDeskAssignmentStatus | 1 |
| SpaceUserPermission.EnterSpace | 1 |
| SpaceUserPermission.ForceMute | 1 |
| SpaceUserPermission.ManageThirdPartyConnections | 1 |
| SpaceUserPermission.RequestToLead | 1 |
| SpaceUserPermission.RespondToRequestToLead | 1 |
| SpaceUserPermission.SaveSpaceOutfit | 1 |
| SpaceUserPermission.SendToDesk | 1 |
| SpaceUserPermission.SendWave | 1 |
| SpaceUserPermission.ThrowConfetti | 1 |
| SpaceUserPermission.UpdateActiveApp | 1 |
| SpaceUserPermission.UpdateActiveMapObjectInteraction | 1 |
| SpaceUserPermission.UpdateAvailability | 1 |
| SpaceUserPermission.UpdateCluster | 1 |
| SpaceUserPermission.UpdateName | 1 |
| SpaceUserPermission.UpdateProfilePicture | 1 |
| SpaceUserPermission.UpdateRole | 1 |
| SpaceUserPermission.UpdateTargetMeetingArea | 1 |
| StartEditingActionItem | 1 |
| StopRecordingIncludingAVRecordingAndOrTranscription | 1 |

`PublicMethod` marks an action with no permission requirement.
`PerformSystemAction` is the most common by a wide margin, covering internal and
lifecycle operations rather than user-initiated ones.

