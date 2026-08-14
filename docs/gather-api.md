# Gather v2 API — what we know

Reverse-engineered 2026-08-06. Three kinds of evidence appear below, and the
difference matters when judging how much to trust a claim:

1. **Static artefacts** (read-only) — the two files listed next.
2. **Live read connections** — observer connections to a real space, and CDP capture
   of the desktop client's own frames.
3. **Live write experiments** — `Action` frames actually executed against a real
   space with the user's account, on their explicit instruction. Anything asserted
   about `move`, `teleport`, `enterSpace` or collision was executed, not inferred.

Findings are dated and labelled with which of the three they came from. Where a
claim is inference, it says so, and the [Unverified](#unverified) list is the
inventory of what nobody has checked.

**A note on what this document does not reproduce.** Everything here came from
Gather's own publicly served client, but this repository is public, so third-party
credentials are not copied into it even when they are already public: Gather's
Statsig and Amplitude client keys are described rather than quoted, and the
`WorkOSWebhook` path — whose final segment functions as a shared secret — is
redacted in the endpoint table. The Firebase *web* API key is the one exception; it
is public by design for Firebase web clients, is required for the code in
`bridge/lib/gather-auth.js` to work at all, and grants nothing on its own.

The static artefacts:

- `/Applications/GatherV2.app/Contents/Resources/app.asar` — the Electron shell.
  It contains **no** game code, no endpoints and no Firebase config; the renderer is
  loaded remotely. Do not go looking there.
- `https://app.v2.gather.town/main.<hash>.js` — the real client. 5.2 MB, one bundle,
  **no lazy chunks**, so everything the client knows is in that single file. The
  build referenced here was `main.6756e69ea136ffbc.js` (release `90c618a88`).

The bundle emits a `sourceMappingURL` pointing at
`sourcemaps.us-east-1-a.prod.aws.gather.town`, which is not publicly routable — so
all of this comes from minified code. Local variable names are lost, but **string
literals, enum members and schema field names survive intact**. That is why the
tables below are trustworthy and why there are few notes about control flow.

This document maps the API. It does not describe how the bridge works today — see
`README.md` and `bridge/lib/AGENTS.md` for that.

## Contents

- [The three hosts](#the-three-hosts)
- [Authentication](#authentication)
  - [The auth endpoints are themselves authenticated](#the-auth-endpoints-are-themselves-authenticated)
  - [Email OTP does not currently complete for an existing account](#email-otp-does-not-currently-complete-for-an-existing-account)
  - [What does work: reuse the desktop client's session](#what-does-work-reuse-the-desktop-clients-session)
- [REST surface — 217 endpoints](#rest-surface-217-endpoints)
- [The activity feed](#the-activity-feed)
  - [Marking activity read](#marking-activity-read)
- [The game socket](#the-game-socket)
  - [Frame types and envelopes](#frame-types-and-envelopes)
  - [Confirmed live, 2026-08-06](#confirmed-live-2026-08-06)
  - [The client→server handshake, captured](#the-clientserver-handshake-captured)
  - [Observer mode: `enterSpace` is a separate action](#observer-mode-enterspace-is-a-separate-action)
  - [Does a duplicate connection evict the desktop client? No.](#does-a-duplicate-connection-evict-the-desktop-client-no)
  - [Entering the space does not collide either](#entering-the-space-does-not-collide-either)
- [Actions — the write API](#actions-the-write-api)
  - [The server tells you the API if you ask wrong](#the-server-tells-you-the-api-if-you-ask-wrong)
  - [Known actions](#known-actions)
  - [`move` is collision-checked, and the check is inside `setPosition`](#move-is-collision-checked-and-the-check-is-inside-setposition)
  - [The server does not validate walkability *for a teleport*](#the-server-does-not-validate-walkability-for-a-teleport)
  - [Entering costs something](#entering-costs-something)
- [What arrives in a state dump](#what-arrives-in-a-state-dump)
  - [Checked because they looked alarming](#checked-because-they-looked-alarming)
- [Media — the SFU](#media-the-sfu)
- [Negative results](#negative-results)
- [Data model](#data-model)
  - [`SpaceUser` — 37 in the schema, 41 on the wire](#spaceuser-37-in-the-schema-41-on-the-wire)
  - [What is *not* in the game state](#what-is-not-in-the-game-state)
- [Incidental finds](#incidental-finds)
- [Verdict](#verdict)
- [Reproducing any of this](#reproducing-any-of-this)
- [Unverified](#unverified)

## The three hosts

| Host | Purpose |
|---|---|
| `https://api.v2.gather.town/api/v2` | REST. The host is `API_BASE_PATH` in bundle module `86415`; the `/api/v2` prefix is **not** in that constant — see below. |
| `wss://game-router.v2.gather.town/gather-game-v2` | **The game socket** — msgpack state sync. Query: `?spaceId=<uuid>&authUserId=<firebaseUid>`. |
| `wss://router.v2.gather.town` | **The media SFU** (mediasoup), bundle module `15683`. Unrelated to game state. |

The trap: only the *SFU* router appears as a literal in the bundle, under the
innocuous key `routerURLs`. The game socket host appears **nowhere** in the client
bundle — the URL above comes from our own live capture
(`bridge/lib/game-protocol.js:5`) and is confirmed to still resolve in DNS. Anyone
who greps the bundle for a websocket URL and finds `router.v2.gather.town` will
connect to the wrong service.

Supporting hosts: `sprite.v2.gather.town` and `dynamic-assets.gather.town` (assets),
`crystal.gather.town/2/httpapi` (Amplitude proxy), `telemetry.*.aws.gather.town` and
`bam.nr-data.net` (New Relic). A `staging` twin exists for each.

## Authentication

Firebase Auth, with the web API key shipped in the bundle (public by design for
Firebase web clients):

```
AIzaSyDPwTbXLMPbIkg6UKr49VrHWwkrOdRh__E
```

REST calls carry `Authorization: Bearer <firebase idToken>`. ID tokens expire in
about an hour; refresh through Google's standard endpoint:

```
POST https://securetoken.googleapis.com/v1/token?key=<apiKey>
grant_type=refresh_token&refresh_token=<token>
```

Three sign-in routes exist in the contract:

| Route | Endpoints |
|---|---|
| **Email OTP** | `POST /auth/otp-requests` then `POST /auth/otp-requests/verify` |
| Google | `GET /auth/google/authorize`, `POST /auth/google/token` (authCode swap) |
| SSO / WorkOS | `POST /auth/sso/initiate`, `POST /auth/sso/token-swap`, `GET /auth/sso/member` |

### The auth endpoints are themselves authenticated

`POST /auth/otp-requests` cold returns **403** `"Authentication is required to access
this resource"`. It is not an anonymous endpoint. The client signs in to Firebase
**anonymously** first — `POST identitytoolkit.googleapis.com/v1/accounts:signUp`
with `{returnSecureToken:true}`, which is what the web SDK's `signInAnonymously()`
does — and then requests the OTP as that anonymous user. With an anonymous Bearer
the same call returns **200** `{"isNewUser":false}`. Verified 2026-08-06.

### Email OTP does not currently complete for an existing account

Sequence as measured, with an anonymous Bearer throughout:

| Step | Result |
|---|---|
| `POST /auth/otp-requests` `{email}` | `200 {"isNewUser":false}`, code arrives by email |
| `POST /auth/otp-requests/verify` `{email, otp}` — **wrong** code | `400` `"That code is invalid or has expired"` |
| `POST /auth/otp-requests/verify` `{email, otp}` — **correct** code | `404` `"No UserAccount found"` |

The two different failures are the point: a correct code gets *past* OTP
validation and then dies in the server's account lookup. The body schema is
confirmed from the bundle's zod contract — `z.object({email, otp})` — so the
request is not malformed.

Corroborating evidence that this path is not the one the desktop client uses:
there is **no app-level `signInWithCustomToken` call site** anywhere in the bundle
(all matches are Firebase SDK internals), and no call site for the otp-verify
contract either. Likely a partially shipped or differently targeted flow. A
second/bot account would need this to work, so it matters — unresolved.

### What does work: reuse the desktop client's session

The GatherV2 desktop client persists its Firebase session at

```
~/Library/Application Support/GatherV2/IndexedDB/
    https_app.v2.gather.town_0.indexeddb.leveldb/
```

under `firebase:authUser:<key>:[DEFAULT]` in the `firebaseLocalStorage` store. The
value is a Blink structured-clone blob, but its strings are plain — tag `0x22`, a
LEB128 length, then the bytes — so `refreshToken` is locatable without a LevelDB
library. Feed it to the standard refresh endpoint and you have a working ID token.

Verified end-to-end 2026-08-06 (`tool/probe-connect.mjs adopt`):

```
GET /api/v2/users/me
  -> { userAccount: { id, email, firebaseAuthId, selectedLanguage, createdAt },
       serverRegion: "us-east-1" }

GET /api/v2/users/me/recent-spaces
  -> { "<spaceId>": { id, name, lastVisited, currentUserRole, spaceUserId } }
```

Two things worth noticing in that second response:

- It is a **map keyed by space id**, not a list.
- It hands over `spaceUserId` — our own `SpaceUser` id for the space — *before any
  socket is opened*. `bridge/lib/game-protocol.js:158-180` currently derives the
  same fact the hard way, by matching a `Connection` row against a Firebase uid
  scraped from IndexedDB over CDP. A direct client can simply be told.

Because refresh tokens are long-lived, this is a **one-time** read: after adopting
once, nothing depends on the desktop client, the debug port, or CDP again. That
makes it a viable bootstrap, not just a debugging shortcut.

Separately, spaces can mint their own API keys (`/spaces/:spaceId/api-keys`,
`/me/api-keys`, model `SpaceApiKey` with `keyHash` / `expiresAt` / `revokedAt`).
Those authenticate *integrations*, not game sockets, and grant no presence access.

## REST surface — 217 endpoints

The client declares its whole REST contract with **ts-rest + zod**: an `HttpV2Paths`
string enum of every path, plus per-route `method`, `pathParams`, `query` and `body`
schemas. The enum is reproduced in full below; the zod schemas are in the bundle if
a specific route's body shape is ever needed.

**Mind the prefix.** `HttpV2Paths` values are relative to `/api/v2`, which appears
nowhere near the `API_BASE_PATH` constant — the client joins the two elsewhere.
Measured 2026-08-06:

| URL | Status |
|---|---|
| `https://api.v2.gather.town/api/v2/users/me` | **403** — route exists, unauthorized |
| `https://api.v2.gather.town/users/me` | 404 |
| `https://api.v2.gather.town/api/users/me` | 404 |
| `https://api.v2.gather.town/v2/users/me` | 404 |

So the full URL for any row below is `https://api.v2.gather.town/api/v2` + path.

**There is no presence in here.** No roster endpoint, no positions, no
game-server-assignment route (the v1 API had one; v2 does not). Live presence is
obtainable *only* over the game socket. This is the single most important negative
result in this document.

### Auth (9)

| Name | Path |
|---|---|
| `AuthOtpRequests` | `/auth/otp-requests` |
| `AuthOtpRequestsVerify` | `/auth/otp-requests/verify` |
| `AuthSSORequests` | `/auth/sso/initiate` |
| `AuthSSOTokenSwap` | `/auth/sso/token-swap` |
| `AuthSSOUserIsMemberOfActiveOrganizationByEmail` | `/auth/sso/member` |
| `AuthLogout` | `/auth/logout` |
| `AuthGoogleTokenSwap` | `/auth/google/token` |
| `AuthGoogleSignInAuthUrl` | `/auth/google/authorize` |
| `AuthGitHubInitiate` | `/spaces/:spaceId/users/me/auth/github/initiate` |

### User (7)

| Name | Path |
|---|---|
| `UserRecentSpaces` | `/users/me/recent-spaces` |
| `UserOwnedSpaces` | `/users/me/owned-spaces` |
| `User` | `/users/me` |
| `UserExists` | `/user/exists` |
| `UserPushDevices` | `/users/me/push-devices` |
| `UserPushDevice` | `/users/me/push-devices/:pushDeviceId` |
| `APIKeyMetadata` | `/me/api-keys` |

### Spaces (41)

| Name | Path |
|---|---|
| `Spaces` | `/spaces` |
| `Space` | `/spaces/:spaceId` |
| `SpaceUsersMe` | `/spaces/:spaceId/users/me` |
| `SpaceUserBaseCalendarEvents` | `/spaces/:spaceId/users/:userAccountId/base-calendar-events` |
| `SpaceUserBaseCalendarEventsSync` | `/spaces/:spaceId/users/me/base-calendar-events/sync` |
| `SpaceOnboardingSurvey` | `/spaces/:spaceId/surveys/onboarding` |
| `SpaceSettings` | `/spaces/:spaceId/settings` |
| `SpaceNooksSpawnTokens` | `/spaces/:spaceId/nooks` |
| `SpaceFile` | `/spaces/:spaceId/files/:fileId` |
| `SpaceFiles` | `/spaces/:spaceId/files` |
| `SpaceGitHubSecret` | `/spaces/:spaceId/github/regenerate-secret` |
| `SpaceSSO` | `/spaces/:spaceId/sso` |
| `SpaceSSOEmailDomains` | `/spaces/:spaceId/sso/email-domains` |
| `SpaceSSOSettings` | `/spaces/:spaceId/sso/settings` |
| `SpaceSSOLinkedSpaces` | `/spaces/:spaceId/sso/linked-spaces` |
| `SpaceSSOLinkedSpaceSource` | `/spaces/:spaceId/sso/linked-space-source` |
| `SpaceSSOEmailDomainVerification` | `/spaces/:spaceId/sso/email-domain/verify` |
| `SpaceOrganization` | `/spaces/:spaceId/organization` |
| `SpaceFileDownload` | `/spaces/:spaceId/files/:fileId/download` |
| `SpaceGatherAIChannels` | `/spaces/:spaceId/gather-ai/channels` |
| `SpaceGatherAIChannelMessages` | `/spaces/:spaceId/gather-ai/channels/:channelId/messages` |
| `SpaceApiKeys` | `/spaces/:spaceId/api-keys` |
| `SpaceApiKey` | `/spaces/:spaceId/api-keys/:apiKeyId` |
| `SpaceObjectTokens` | `/spaces/:spaceId/objects/:objectId/tokens` |
| `SpaceObjectTokensList` | `/spaces/:spaceId/objects/tokens` |
| `SpaceMeetingArtifactGetContent` | `/spaces/:spaceId/artifacts/:artifactId/content` |
| `SpaceMeetingArtifactDeleteContent` | `/spaces/:spaceId/artifacts/:artifactId/content/:contentType` |
| `SpaceMeetingArtifactShareWithInvitees` | `/spaces/:spaceId/artifacts/:artifactId/share-with-invitees` |
| `SpaceFloorPreview` | `/spaces/:spaceId/floors/:floorId/preview` |
| `SpaceInsights` | `/spaces/:spaceId/insights/:metric` |
| `SpaceInsightsMetricDetails` | `/spaces/:spaceId/insights-details/:metric` |
| `SpaceInsightsSummary` | `/spaces/:spaceId/insights-summary/:metrics` |
| `SpaceSearchMessages` | `/spaces/:spaceId/search/messages` |
| `AuthGitHubDisconnect` | `/spaces/:spaceId/users/me/github/disconnect` |
| `GitHubGetOrganizationInfo` | `/spaces/:spaceId/users/me/github/getOrganizationInfo` |
| `GitHubGetOrganizationMembers` | `/spaces/:spaceId/users/me/github/getOrganizationMembers` |
| `GetUsageAndBudgetForSpace` | `/spaces/:spaceId/usage` |
| `ChatIntegrationsInstall` | `/spaces/:spaceId/integrations/:integrationKey/install` |
| `SpaceAreas` | `/spaces/:spaceId/areas` |
| `SpaceTemplates` | `/space-templates` |
| `SpaceSupportRequestFiles` | `/spaces/:spaceId/support-request-files` |

### Chat (26)

| Name | Path |
|---|---|
| `ExpAiChatbotChatKnowledgeBase` | `/exp-ai/chatbot/chat/knowledge-base` |
| `SpaceChatActivityFeedToggleReadStatus` | `/spaces/:spaceId/chat/activity-feed/toggle-read-status` |
| `SpaceChatChannels` | `/spaces/:spaceId/chat/channels` |
| `SpaceChatChannel` | `/spaces/:spaceId/chat/channels/:channelId` |
| `SpaceChatChannelExists` | `/spaces/:spaceId/chat/channel-exists` |
| `SpaceChatChannelByName` | `/spaces/:spaceId/chat/channels/by-name/:name` |
| `SpaceChatChannelPreferences` | `/spaces/:spaceId/chat/channels/:channelId/preferences` |
| `SpaceChatChannelBulkAddMembers` | `/spaces/:spaceId/chat/channels/:channelId/bulk-add-members` |
| `SpaceChatChannelJoin` | `/spaces/:spaceId/chat/channels/:channelId/join` |
| `SpaceChatChannelBulkRemoveMembers` | `/spaces/:spaceId/chat/channels/:channelId/bulk-remove-members` |
| `SpaceChatChannelMessages` | `/spaces/:spaceId/chat/channels/:channelId/messages` |
| `SpaceChatChannelMessage` | `/spaces/:spaceId/chat/channels/:channelId/messages/:messageId` |
| `SpaceChatMessageReactions` | `/spaces/:spaceId/chat/channels/:channelId/messages/:messageId/reactions` |
| `SpaceChatChannelMessageFileDownload` | `/spaces/:spaceId/chat/channels/:channelId/messages/:messageId/file-download/:fileId` |
| `SpaceChatChannelReadCursors` | `/spaces/:spaceId/chat/channels/:channelId/read-cursors` |
| `SpaceChatChannelTyping` | `/spaces/:spaceId/chat/channels/:channelId/typing` |
| `SpaceChatThreadParticipants` | `/spaces/:spaceId/chat/channels/:channelId/messages/:messageId/thread-participants` |
| `SpaceChatFiles` | `/spaces/:spaceId/chat/chats/files` |
| `SpaceChatActivityFeed` | `/spaces/:spaceId/chat/activity-feed` |
| `SpaceChatExports` | `/spaces/:spaceId/chat/exports` |
| `SpaceChatExportSession` | `/spaces/:spaceId/chat/exports/:sessionId` |
| `SpaceChatExportSpace` | `/spaces/:spaceId/chat/exports/:sessionId/space` |
| `SpaceChatExportUsers` | `/spaces/:spaceId/chat/exports/:sessionId/users` |
| `SpaceChatExportChannels` | `/spaces/:spaceId/chat/exports/:sessionId/channels` |
| `SpaceChatExportMessages` | `/spaces/:spaceId/chat/exports/:sessionId/messages` |
| `ChatIncomingWebhook` | `/spaces/:spaceId/chat/hooks/:token` |

### Meetings (20)

| Name | Path |
|---|---|
| `SpaceUserMeetingsList` | `/spaces/:spaceId/users/me/meetings` |
| `SpaceUserMeetingsGet` | `/spaces/:spaceId/users/me/meetings/:meetingId` |
| `SpaceMeetingArtifactList` | `/spaces/:spaceId/meetings/:meetingId/artifacts` |
| `SpaceMeetingExports` | `/spaces/:spaceId/meetings/exports` |
| `SpaceMeetingExportSession` | `/spaces/:spaceId/meetings/exports/:sessionId` |
| `SpaceMeetingExportMeetings` | `/spaces/:spaceId/meetings/exports/:sessionId/meetings` |
| `SpaceMeetingIntegrations` | `/spaces/:spaceId/meetings/integrations` |
| `SpaceMeetingIntegration` | `/spaces/:spaceId/meetings/integrations/:integrationId` |
| `SpaceMeetingMemoTranscripts` | `/spaces/:spaceId/meeting-memos/:meetingId/transcripts` |
| `SpaceMeetingMemoList` | `/spaces/:spaceId/meeting-memos` |
| `SpaceMeetingMemoRegenerate` | `/spaces/:spaceId/meeting-memos/:meetingId/regenerate` |
| `SpaceMeetingMemoDefaultPrompts` | `/spaces/:spaceId/meeting-memos-default-prompts` |
| `SpaceMeetingMemos` | `/spaces/:spaceId/meeting-memos/:meetingId` |
| `SpaceMeetingMemoGenerateFullNote` | `/spaces/:spaceId/meeting/:meetingId/meetingMemo/generateFullNote` |
| `SpaceMeetingMemoFeedback` | `/spaces/:spaceId/meeting-memos/feedback` |
| `SpaceMeetingMemoToken` | `/spaces/:spaceId/meeting-memos/:meetingId/token` |
| `SpaceAreasForMeeting` | `/spaces/:spaceId/areas/for-meeting` |
| `SpaceMeetingJoinInfo` | `/spaces/:spaceId/meeting-join-info` |
| `SpaceMeetingJoinInfoLink` | `/spaces/:spaceId/meeting-join-info/:linkId` |
| `MeetingJoinInfoLink` | `/meeting-join-info/:linkId` |

### Pricing (29)

| Name | Path |
|---|---|
| `PricingServiceSubscription` | `/pricing/:spaceId/subscriptions` |
| `PricingActiveCustomerPlanInterval` | `/pricing/:spaceId/subscriptions/active-customer-plan-interval` |
| `PricingServiceSubscriptionBySpace` | `/pricing/:spaceId/subscriptions/by-space` |
| `SpaceIdAndNameByPricingServiceSubscription` | `/pricing/subscriptions/:subscriptionId/space-id-and-name` |
| `CancelPricingServiceSubscription` | `/pricing/:spaceId/subscriptions/cancel` |
| `PricingApplyOneTimeDiscount` | `/pricing/:spaceId/subscriptions/apply-one-time-discount` |
| `PricingAddCoupon` | `/pricing/:spaceId/subscriptions/add-coupon` |
| `RenewPricingServiceSubscription` | `/pricing/:spaceId/subscriptions/renew` |
| `PricingServiceSubscriptionModelCounts` | `/pricing/:spaceId/subscriptions/model-counts` |
| `PricingCustomerPlanIntervals` | `/pricing/:spaceId/subscriptions/customer-plan-intervals` |
| `PricingServicePaymentMethod` | `/pricing/:spaceId/subscriptions/payment-info` |
| `PricingServiceSubscriptionBillingCountry` | `/pricing/:spaceId/subscriptions/billing-country` |
| `PricingSwitchBillingInterval` | `/pricing/:spaceId/subscriptions/switch-billing-interval` |
| `PricingUpdateSubscriptionQuantity` | `/pricing/:spaceId/subscriptions/update-quantity` |
| `PricingSubscriptionPreview` | `/pricing/:spaceId/subscription-preview` |
| `PricingProrationSubscriptionPreview` | `/pricing/:spaceId/proration-subscription-preview` |
| `PricingSubscriptionPreviewV2` | `/pricing/:spaceId/subscription-previewV2` |
| `PricingPaymentMethods` | `/pricing/:spaceId/payment-methods` |
| `PricingStartPaidSubscription` | `/pricing/:spaceId/start-paid-subscription` |
| `PricingCreateIntent` | `/pricing/:spaceId/create-intent` |
| `CreateCustomerPaymentLink` | `/pricing/:spaceId/subscriptions/create-customer-payment-link` |
| `PricingGetInvoices` | `/pricing/:spaceId/get-invoices` |
| `PricingGetInvoiceFromProvider` | `/pricing/:spaceId/get-invoice-from-provider/:invoiceId` |
| `PricingMigrateV1SubscriptionSeats` | `/pricing/:spaceId/migrate-v1-subscription-seats` |
| `PricingLinkV1SpaceToV2` | `/pricing/:spaceId/link-v1-space-to-v2` |
| `PricingUnlinkV1Space` | `/pricing/:spaceId/unlink-v1-space` |
| `PricingGetLinkedV1SpaceCapacity` | `/pricing/:spaceId/linked-v1-capacity` |
| `TestSimulateDailyProration` | `/pricing/:spaceId/test-simulate-daily-proration` |
| `GetUsageAndBudgetForSubscription` | `/pricing/:subscriptionId/usage` |

### Admin (52)

| Name | Path |
|---|---|
| `AdminAvClientStateSessions` | `/admin/av-client-state-sessions` |
| `AdminAvClientStateSession` | `/admin/av-client-state-sessions/:sessionId` |
| `AdminAvClientStateUserFeedback` | `/admin/av-client-state-sessions/:sessionId/userFeedback` |
| `AdminAuditEvents` | `/admin/audit-events` |
| `AdminUserAccounts` | `/admin/users` |
| `AdminUserAccount` | `/admin/users/email-or-id/:emailOrId` |
| `AdminUserArtifacts` | `/admin/users/:userAccountId/artifacts` |
| `AdminUserSpaces` | `/admin/users/:userAccountId/spaces` |
| `AdminUserRevokeTokens` | `/admin/users/:userAccountId/revoke-tokens` |
| `AdminUserDeletionPreflight` | `/admin/users/deletion-preflight` |
| `AdminUserCancelSubscriptions` | `/admin/users/:userAccountId/cancel-subscriptions` |
| `AdminSpace` | `/admin/spaces/:spaceId` |
| `AdminSpaceName` | `/admin/spaces/:spaceId/name` |
| `AdminSpaceUsers` | `/admin/spaces/:spaceId/users` |
| `AdminSpaceUserRole` | `/admin/spaces/:spaceId/users/:spaceUserId/role` |
| `AdminSpaceRevokeTokens` | `/admin/spaces/:spaceId/revoke-tokens` |
| `AdminSpaceOrganization` | `/admin/spaces/:spaceId/organization` |
| `SuperAdminUserRoles` | `/admin/super-admin-users/:userAccountId/roles` |
| `SuperAdminUsers` | `/admin/super-admin-users` |
| `SuperAdminUser` | `/admin/super-admin-users/:userAccountId` |
| `AdminWearables` | `/admin/wearables` |
| `AdminWearable` | `/admin/wearables/:wearableId` |
| `AdminCatalogItems` | `/admin/catalog-items` |
| `AdminCatalogItem` | `/admin/catalog-items/:catalogItemId` |
| `AdminCatalogItemVariants` | `/admin/catalog-items/:catalogItemId/variants` |
| `AdminCatalogItemVariant` | `/admin/catalog-item-variant/:catalogItemVariantId` |
| `AdminMeetingConversationMetadata` | `/admin/conversation-metadata/meeting/:meetingId` |
| `AdminTelemetryFiretigerTraceEvents` | `/admin/telemetry/:serviceName/firetiger-traces` |
| `AdminTelemetryFiretigerTraceEventsByMeetingId` | `/admin/telemetry/:serviceName/firetiger-traces/meeting/:meetingId` |
| `AdminTelemetryFiretigerTraceEventsByClusterId` | `/admin/telemetry/:serviceName/firetiger-traces/cluster/:clusterId` |
| `AdminTelemetryFiretigerTraceEventsByOperationName` | `/admin/telemetry/:serviceName/firetiger-traces/operation/:operationName` |
| `AdminTelemetryNewRelic` | `/admin/telemetry/:serviceName/newrelic` |
| `AdminTelemetryNewRelicByMeetingId` | `/admin/telemetry/:serviceName/newrelic/meeting/:meetingId` |
| `AdminTelemetryNewRelicByClusterId` | `/admin/telemetry/:serviceName/newrelic/cluster/:clusterId` |
| `AdminTelemetryNewRelicByOperationName` | `/admin/telemetry/:serviceName/newrelic/operation/:operationName` |
| `AdminSubscription` | `/admin/subscriptions/:subscriptionId` |
| `AdminSubscriptionChangeOwner` | `/admin/subscriptions/:subscriptionId/change-owner` |
| `AdminSubscriptionGetLinkedV1SpaceCapacity` | `/admin/subscriptions/:subscriptionId/linked-v1-space-capacity` |
| `AdminSpaceSubscriptions` | `/admin/spaces/:spaceId/subscriptions` |
| `AdminSpaceCreatePaidSubscription` | `/admin/spaces/:spaceId/create-paid-subscription` |
| `AdminSubscriptionIntervals` | `/admin/subscriptions/:subscriptionId/intervals` |
| `AdminSubscriptionInterval` | `/admin/subscriptions/:subscriptionId/intervals/:intervalId` |
| `AdminSpaceSettingsAllowAccessWhenDeactivated` | `/admin/spaces/:spaceId/settings/allowAccessWhenDeactivated` |
| `AdminSpaceSettingsDailyInviteLimit` | `/admin/spaces/:spaceId/settings/dailyInviteLimit` |
| `AdminOrganizations` | `/admin/organizations` |
| `AdminOrganizationsImport` | `/admin/organizations/import` |
| `AdminOrganizationsDbSearch` | `/admin/organizations/db-search` |
| `AdminOrganization` | `/admin/organizations/:organizationId` |
| `AdminOrganizationEmailDomains` | `/admin/organizations/:organizationId/email-domains` |
| `AdminOrganizationEmailDomain` | `/admin/organizations/:organizationId/email-domains/:domain` |
| `AdminOrganizationSpaces` | `/admin/organizations/:organizationId/spaces` |
| `AdminOrganizationSpace` | `/admin/organizations/:organizationId/spaces/:spaceId` |

### Webhooks (10)

| Name | Path |
|---|---|
| `WorkOSWebhook` | `/webhooks/workos/<redacted — the path segment is a shared secret>` |
| `HookAssemblyAiTranscription` | `/hooks/assemblyai/transcription` |
| `GitHub` | `/hooks/github/spaces/:spaceId` |
| `GitHubApp` | `/hooks/github/app-webhook` |
| `StripeWebhook` | `/hooks/stripe/app-webhook` |
| `LivekitWebhook` | `/hooks/livekit/recording/:recordingId/status` |
| `HookAVAudioRecordingS3` | `/hooks/audio-recordings/s3` |
| `HookAVMeetingSummaryS3` | `/hooks/meeting-summaries/s3` |
| `GrapevineTaskExtractionCallback` | `/hooks/grapevine/task-extraction` |
| `HookSpaceObject` | `/hooks/spaces/:spaceId/objects/:objectId` |

### Releases (4)

| Name | Path |
|---|---|
| `DesktopClientInstaller` | `/releases/latest/:platform/:appVersion` |
| `BrowserClientReleases` | `/releases/browser/:browserName/:releaseCommit/:releaseChannel` |
| `DesktopClientReleases` | `/releases/desktop/:platform/:releaseVersion/:releaseChannel` |
| `DesktopClientLatest` | `/releases/desktop/latest` |

### Other (19)

| Name | Path |
|---|---|
| `_V1_STUB` | `/v1-implementation-stubbed-out` |
| `_Template` | `/_template/:id` |
| `ExpAiChatbotChat` | `/exp-ai/chatbot/chat` |
| `ExpAiPrSummary` | `/exp-ai/pr-summary` |
| `ExpAiGrapevineMcp` | `/exp-ai/grapevine-mcp` |
| `HubSpotCreateContact` | `/hubspot/contacts/create` |
| `HubSpotUpdateContact` | `/hubspot/contacts/update` |
| `HubSpotUpdateContactNumberProperties` | `/hubspot/contacts/update-number-properties` |
| `SupportRequests` | `/support-requests` |
| `Wearables` | `/wearables` |
| `Wearable` | `/wearables/:wearableId` |
| `CloudflareSiteVerify` | `/integrations/cloudflare/siteverify` |
| `SpotifyOAuthAuthenticate` | `/integrations/spotify/:spaceId/authenticate` |
| `SpotifyOAuthRedirect` | `/integrations/spotify/redirect` |
| `ScheduledDeleteRecordings` | `/scheduled-tasks/delete-recordings` |
| `PublishLog` | `/internal/logs` |
| `NewRelicCustomEvents` | `/newrelic/custom-events` |
| `EligibilitySurveySubmission` | `/eligibility-survey-submission` |
| `BrowserExtensionConfig` | `/browser-extension/config` |


## The activity feed

`GET /spaces/:spaceId/chat/activity-feed` — what the desktop client shows behind
`gather-chat-activity-feed-nav`, and the only durable history Gather keeps for you.
Measured 2026-08-13 against a real space: `200`, **75,407 bytes**,
`content-type: application/x.gather.msgpack`. REST speaks msgpack too, so the same
decoder the socket uses reads it; a JSON parse destroys the body.

The payload is normalised exactly like a state dump — id lists plus a model store:

```jsonc
{ "activityFeed": {
    "chatMessageIdsForActivityFeedWaveItems":       [ "<ChatMessage id>", … ], // 100
    "chatMentionIdsForActivityFeedMentionItems":    [ … ],                     //   0
    "chatMessageIdsForActivityFeedReactionItems":   [ … ],                     //   0
    "threadParentIdsForActivityFeedReplyItems":     [ … ],                     //   0
    "activityEventSubscriptionIds":                 [ "<sub id>", … ] },       //  16
  "serializedModels": {
    "ChatMessage":               [ … ],  // 100, all type:'System' with an empty body
    "ChatMessageMetadata":       [ … ],  // 100, all {type:'Waved', …}
    "ChatChannel":               [ … ],  //   7 DirectMessage channels
    "ActivityEvent":             [ … ],  //  16
    "ActivityEventSubscription": [ … ] } //  16
}
```

**A wave's sender is on the metadata, not the message.** The `ChatMessage` row is a
`System` row in a DM channel and its `spaceUserId` is the channel's author, not the
waver. `ChatMessageMetadata.metadata` is where it actually lives:

```jsonc
{ "type": "Waved", "waveRecipientId": "<me>", "actorSpaceUserId": "<them>" }
```

**`ActivityEvent.metadata` is discriminated by `type`.** Observed, 16 rows:

| `type` | Count | Payload |
|---|---|---|
| `MeetingArtifactReady` | 14 | `meetingId` `meetingTitle` `meetingAreaId` `hasMeetingMemo` `hasVideoRecording` `meetingArtifactId` `meetingParticipantCount` `artifactContentStartTimestamp` `artifactContentEndTimestamp` |
| `OnboardingChat` | 1 | none — `isGlobal: true` |
| `OnboardingDesk` | 1 | none — `isGlobal: true` |

**Read state is on the subscription, not the event.** `ActivityEventSubscription` is
`{id, spaceUserId, activityEventId, readAt, …}` and `readAt: null` means unread — 11
of 16 in the measured space.

### Marking activity read

`POST /spaces/:spaceId/chat/activity-feed/toggle-read-status`, captured off the
desktop client 2026-08-13 and then exercised from our own code against the live
account:

```http
Content-Type: application/json

{"activityEventId": "3aba2ff3-fc2d-5c48-9c05-e50f0945c50d"}
```

→ `200`, and a **msgpack** body holding the row that changed:

```jsonc
{ "ActivityEventSubscription": [
    { "id": "5eabaa25-…", "spaceUserId": "…", "activityEventId": "3aba2ff3-…",
      "readAt": "2026-08-13T17:52:15.417Z", "createdAt": "…", "updatedAt": "…" }]}
```

Four things here are the opposite of the obvious guess, and every one of them was
guessed wrong before it was measured:

- **The request is JSON while the response is msgpack.** The API is not symmetric.
  Beware of confirming otherwise by accident: a JSON body starts with `{`, which is
  `0x7b`, which is a valid msgpack fixint — so a msgpack decoder "succeeds" on the
  first byte of a JSON body and returns `123`. Try JSON first.
- **It names the *event*, not the subscription.** `readAt` lives on the
  subscription, which makes the subscription id look like the handle. It is not.
- **One event per request.** The client sends a separate call per item; no batch
  form was observed, and no plural field exists to invent.
- **It is a toggle, and there is no `read: true`.** The server flips whatever it
  finds and stamps its own timestamp, so sending an already-read id marks it
  *unread*. Anything offering "mark all read" must filter to the unread ones first
  or it will un-read most of the list. Verified by round trip: unread 6 → 5 → 6.

**Waves are not here at all.** They have no subscription row; their read state is a
`ChatReadCursor`, posted per channel to
`POST /spaces/:spaceId/chat/channels/:channelId/read-cursors` (also JSON), and read
back as `cursors: {previousCursorId, nextCursorId}` on the messages endpoint. So
"mark this wave read" and "mark this activity read" are two different mechanisms.

**There is no pagination.** `?limit`, `?cursor`, `?before`, `?page` and `?offset`
were each tried; every one returned a byte-identical body. The feed is a fixed
snapshot — the last 100 waves plus the live activity events.

**A bucket brings its models only when it is non-empty.** The measured space had zero
mentions and the response carried no mention model whatsoever, so a reader must
tolerate an id list it cannot resolve rather than assume the store is complete. For
the same reason the mention, reaction and reply joins in
`packages/gather_client/lib/src/activity_feed.dart` are **unverified**: no space
available to measure had one of them in it.

**This is not the same thing as `ActivityEvent` on the socket.** The model is in the
state dump too — 2 rows, in [the census](#what-arrives-in-a-state-dump) — but was
never seen in a delta patch, so the socket is not a live tail for it. Waves *are*
live on the socket, as `WaveEvent` on the event bus. That makes REST the backfill and
the bus the tail, and means nothing has to poll.

## The game socket

Binary msgpack frames, both directions. Handshake order, captured from a live
session:

```
Authenticate -> ConnectToSpace -> Subscribe -> SpaceStatus
  -> FullStateChunk xN     (initial dump, ~1500 patches, ~45 models, ONCE per connection)
  -> DeltaState / Action   (everything after)
  -> Heartbeat             (~1/s, the bulk of traffic)
```

### Frame types and envelopes

Observed server→client, all msgpack over binary frames:

| Frame | Keys |
|---|---|
| `SpaceStatus` | `warmInGatewayServer`, `warmInLogicServer` |
| `FullStateChunk` | `fullStatePatches[]`, `actionReturns[]`, `events[]`, `optimisticAckTxnIds[]`, `chunkConfig`, `sequenceNumber` |
| `DeltaState` | `patches[]`, `actionReturns[]`, `events[]`, `optimisticAckTxnIds[]`, `sequenceNumber` |
| `Heartbeat` | `timestamp`, `origin: 'Server'` |

The client heartbeats the same shape back with `origin: 'Client'`, roughly once a
second. `sequenceNumber` is Gather's own and unrelated to the bridge's `seq`.
`optimisticAckTxnIds` acknowledges client-predicted actions.

### Confirmed live, 2026-08-06

The socket URL is the one fact here that could not be corroborated from the bundle,
so it was measured directly. An **unauthenticated** connect with a nonsense
`spaceId` and `authUserId=probe`:

- the WebSocket upgrade was **accepted** — the host and path are still correct;
- the server immediately sent
  `{type:'Heartbeat', timestamp:1786017022587, origin:'Server'}`, which
  `bridge/lib/msgpack.js` decoded unchanged — the decoder is current against 2026
  server frames;
- the socket **stayed open past 10s** with no credentials presented at all.

So authentication happens in the `Authenticate` *frame*, not in the URL or the
upgrade: the query string is not a credential. A bad or absent identity is not
rejected at connect time, which means a probe can reach the protocol layer before
presenting anything — useful, because it separates "URL wrong" from "auth wrong"
when debugging the handshake.

State is patches against model rows, in two envelopes —
`FullStateChunk.fullStatePatches[]` and `DeltaState.patches[]` — carrying three ops
that are **not** JSON-Patch:

```
{op:'addmodel',    model, data}            whole row; the id is inside `data`
{op:'deletemodel', model, id}              row removed
{op:'replace',     model, id, path, data}  one field, e.g. '/position/x'
```

Implementation and the traps (position mutating in place, optional columns absent
rather than null) live in `bridge/lib/game-protocol.js:10-44`. The msgpack extension
codec — five ext types, `Position` arriving as `{$type:'Position', x, y}` — is
documented and implemented at `bridge/lib/msgpack.js:13-27`.

### The client→server handshake, captured

CDP reports `Network.webSocketFrameSent` as well as `…FrameReceived`. The bridge
only ever reads the latter, which is why these shapes were unknown. Captured
2026-08-06 by watching the desktop client's outbound frames while forcing a
reconnect with a renderer reload:

```
{type:'Authenticate',   credential:{type:'JWT', jwt:'<firebase idToken>'}}
{type:'ConnectToSpace', spaceId:'<uuid>'}
{type:'Subscribe'}
{type:'Action', txnId:'<uuid>', action:'loadSpaceUser',
                args:['SpaceUser', null, {connectionTarget:'OfficeView',
                                          clientPlatform:'Desktop'}]}
{type:'Action', txnId:'<uuid>', action:'enterSpace',
                args:['SpaceUser', '<my spaceUserId>']}
{type:'Action', txnId:'<uuid>', action:'reportActivity',
                args:['Connection', null, {isActive:true}]}
```

Three things this corrects, each of which silently breaks a client that guesses:

1. **`Authenticate` wraps the token** in `credential:{type:'JWT', jwt}`. A flat
   `token`/`idToken`/`authToken` field is not an error — the server simply never
   replies, keeps heartbeating, and drops you later. Measured: a wrong-shaped
   `Authenticate` yields 4 heartbeats and nothing else.
2. **`Subscribe` takes no arguments at all** — but that is not the same as being
   unable to narrow the stream, and this document said so twice before getting it
   right. `Subscribe` is the blanket "send me everything". Narrowing is a separate
   *action*, captured off the real client 2026-08-13:

   ```jsonc
   Action{createSubscription, args:['ModelSubscription', null,
     {modelKey:'BaseCombinedCalendarEvent', subscriptionType:'Include', modelIds:[…]}]}
   Action{updateSubscription, args:['ModelSubscription', '<id>', {modelIds:[…]}]}
   ```

   So `ModelSubscription` is a client-supplied filter after all, addressed by
   `modelKey` with an explicit row list. The desktop client uses it for calendar
   events rather than for presence. Nothing here needs it — we take everything and
   filter locally, as `bridge/lib/game-protocol.js:47` does — but "you cannot" was
   false, and the reason it survived is that nobody watched the client's *own*
   outbound frames for long enough to see it.
3. **State arrives because of an `Action`, not because you connected.**
   `loadSpaceUser` is what materialises your `SpaceUser` and triggers the dump.

`Action` frames carry a client-generated `txnId`, and the server acknowledges each
one in `DeltaState.actionReturns[]` as
`{connectionId, txnId, result:{type:'Success', value}}` — so actions are
request/response over the same socket, and failures are addressable per txn.

### Observer mode: `enterSpace` is a separate action

This is the important structural find. `loadSpaceUser` gets you the space's state;
**`enterSpace` is what actually puts your avatar in the space** and flips
`Connection.entered`. They are different frames, and the second is optional.

Verified by connecting with the first and omitting the second — the `Connection`
row the server created for us read:

```
{entered:false, target:'OfficeView', clientPlatform:'Desktop', isActive:false}
```

and we still received the complete state: `SpaceStatus`, `FullStateChunk` ×4, 223
patches, **111 SpaceUsers**, resolving to an 80-player roster after bots and
`RecordingClient`s are filtered — with real names and tile coordinates.

So a companion can read the whole space without joining it. No avatar, no
presence visible to colleagues, no second body in the room.

### Does a duplicate connection evict the desktop client? No.

The long-standing fear (recorded in the since-deleted `bridge/lib/cdp.js`) was that a second connection on
the same `spaceId` + `authUserId` would evict the user's own session with close
code 4031. **Measured 2026-08-06 and it does not.**

Method: watch the desktop client's own game socket over CDP
(`Network.webSocketCreated` / `…Closed`, counting received frames) while the probe
opens a fully authenticated second connection to the same space as the same
account. Result across a 45s window — the desktop socket kept the same requestId,
never closed, and kept receiving frames throughout (3 → 19). The client was not
disturbed and the process stayed up.

Caveats, stated precisely:

- An earlier run with a malformed `Authenticate` also failed to evict, but proves
  less: it never authenticated. The result above is from an authenticated
  connection that received full state.

### Entering the space does not collide either

Tested 2026-08-06 at the user's explicit request, against the same live space with
the desktop client joined:

- `enterSpace` returned `{type:'Success', value:'<spaceUserId>'}` — so the action
  genuinely took effect rather than being ignored, which matters because Gather's
  usual failure mode is silence.
- The server patched our own `Connection` row: `/clientPlatform → 'Desktop'`,
  `/target → 'OfficeView'`, `/entered → true`.
- The desktop client's socket was **not** closed and did not drop a frame across a
  40s window.
- Our `SpaceUser.position` was unchanged before and after (`62,34`) — no teleport to
  a spawn point.
- No server-side `events` were emitted on the wire.

**Why this is safe is structural, not luck.** `Connection` is per-connection, but
`SpaceUser` is per-person-per-space: both connections reference the *same*
`spaceUserId`, so there is no second avatar to collide with. Gather has to support
this regardless — the desktop app hosts multiple WebContents, and web plus desktop
can be signed in together. The `WSCloseCode.DUPLICATE_CONNECTION = 4031` belief in
That belief was therefore wrong for both observer *and* entered
connections.

Two things it does cost, which is why `DirectCollector` still does not enter:

- **`numTimesEnteredSpace` increments per entering connection** (observed 74 → 76
  across two tests). That is a stat on the user's own profile.
- Being `entered` presumably makes you present for idle/availability purposes.
  Not measured.

What was *not* measured: whether other clients rendered anything (a join/leave
blip), and whether the desktop client's mic/camera were disturbed. The socket was
untouched, but AV state was not instrumented.

## Actions — the write API

Everything a client *does* travels as an `Action` frame on the game socket. This is
the whole write surface; REST does none of it.

```
{type:'Action', txnId:'<uuid>', action:'<name>', args:['<Model>', '<id>', <payload>]}
```

`args` is positionally `[modelName, rowId, ...methodArgs]`. `rowId` may be `null`
when the method does not address an existing row (`loadSpaceUser` uses `null`).

Replies come back asynchronously in `DeltaState.actionReturns[]`, keyed by the
client-generated `txnId`:

```
{connectionId, txnId, result:{type:'Success', value:<...>}}
{connectionId, txnId, result:{type:'Error',   error:'<message or zod JSON>'}}
```

So actions are request/response over the same socket, and failures are addressable
per transaction rather than being connection-wide.

### The server tells you the API if you ask wrong

This is the most useful thing in this document. The action vocabulary is **not**
discoverable from the client bundle (see Negative results), but the server is
generous with errors:

| You send | Server replies |
|---|---|
| an action that does not exist | `Error "Method definitelyNotARealAction not found on model SpaceUser"` |
| a real action with a bad payload | `Error` containing the **full zod issue list** — expected types, and the exact `path` of each missing field |

That turns the write API into something you can enumerate by probing rather than
guess. `move` and `teleport` were both found this way in about two minutes, after
searching the bundle for them had failed entirely. Probing is cheap and safe:
a wrong name changes nothing, and a schema violation is rejected before execution.

### Known actions

Captured off the real client, or confirmed by probe:

| Action | Args | Notes |
|---|---|---|
| `loadSpaceUser` | `['SpaceUser', null, {connectionTarget, clientPlatform}]` | materialises your SpaceUser and triggers the state dump |
| `enterSpace` | `['SpaceUser', '<spaceUserId>']` | puts your avatar *in* the space; see its cost below |
| `reportActivity` | `['Connection', null, {isActive:boolean}]` | idle reporting |
| `getAuthenticationData` | `['SpotifyOAuthUserSecret', null]` | integration secrets |
| `createSubscription` | `['ModelSubscription', null, {modelKey, subscriptionType:'Include', modelIds[]}]` | narrows a model to specific rows — see below |
| `updateSubscription` | `['ModelSubscription', '<id>', {modelIds[]}]` | replaces that subscription's id list |
| `move` | `['SpaceUser', id, {direction:'Up'\|'Down'\|'Left'\|'Right'}]` | **one tile per call** |
| `teleport` | `['SpaceUser', id, {x, y, direction}]` | flat `x`/`y`; `floorId` optional |
| `walk` / `run` / `drive` | `['SpaceUser', id]` | **two args.** Three actions rather than one with a number in it; each body is `this.speed = new Speed(WALKING\|RUNNING\|DRIVING)` |
| `faceDirection` | `['SpaceUser', id, 'Down']` | **bare string.** Turns without stepping |
| `setAvailability` | `['SpaceUser', id, {availability:'Active'\|'Busy'\|'Away'}]` | writes `userSetAvailability` |
| `setCustomStatus` | `['SpaceUser', id, {text, emoji?, clearCondition?}]` | `clearCondition` is `{type:'DateTime', clearAt:<ext-1 DateTime>}` |
| `clearCustomStatus` | `['SpaceUser', id]` | **two args** |
| `setHandRaised` | `['SpaceUser', id, true]` | **bare bool** |
| `startSpeaking` / `stopSpeaking` | `['SpaceUser', id]` | **two args.** Voice activity, not mute |
| `leaveCluster` | `['SpaceUser', id]` | **two args.** Leaves the conversation, stays put |
| `broadcastEmote` | `['SpaceUser', id, {emote, count, ambientlyConnectedUserIds}]` | see below |
| `updateTargetMeetingArea` | `['SpaceUser', id, {meetingAreaId, shouldBeInClusterWithOthersWithSameTargetMeetingArea?}]` | read out of the bundle, not off the wire — `MeetingFrontendRepo.joinMeeting` sends it after `getOrSetMeetingArea` assigns a room. This row said "seen with an empty payload only" until the client was read directly; the capture that produced that was of a join that carried no area. Both fields line up with `SpaceUser.currentTargetMeetingAreaId` and `shouldBeInClusterWithOthersWithSameTargetMeetingArea` in the state dump. |
| `markContextualOnboardingPOICompleted` | `['SpaceUserOnboarding', id, 'Profile']` | **not `SpaceUser`** — the model is per-action |

Probed and confirmed **not** to exist on `SpaceUser`: `moveTo`, `setPosition`,
`updatePosition`, `walkTo`, `setDestination`, `goTo`. `teleport` rejects
`{position:{x,y}}` — the coordinates must be flat, and `direction` is required even
when teleporting. What the client *puts* in it is the way you travelled, not a
constant: `MoveController.teleport` derives it with
`position.positionToDirectionIgnoringAxis(goal)` and abandons the hop outright if that
answers null. `space_map.dart`'s `headingTo` is the transcription.

**Speed is three actions, and the go-kart is one of them.** There is no vehicle
model on the wire, no ride action, and nothing anywhere that says "in a kart".
`speed.modifier` is 1, 2 or 3, and `PlayerEntityRenderer` puts a kart under anybody
who reaches 3 — `if (getSpeedModifier() === Speed.DRIVING) this.setVehicle({id:
"goKart-for-speed-modifier"})`, over one shared 512×32 sheet at `GOKART_URL`. Nothing
about *position* depends on it either: the pace is entirely in how often `move` is
sent, at `getMoveInterval(m) = (1000/7) / m`. What the action buys is that
`speed.modifier` is a synced field, so it is the only thing every other client in the
space reads to pick the run cycle and to draw the kart. Which gait to be in is
`calculateSpeedModifierForPathStarting` (walk to 13 tiles, run to 23, drive past
that) and `calculateSpeedModifierForPathRemaining` (recomputed from what is *left*,
never above the ceiling, so every route decelerates and the last six tiles of
anything are walked; and a non-`isPublicWalkway` area forces a walk outright). The
shift key is a separate door with none of those rules:
`setSpeedModifier(shift ? DRIVING : WALKING)`.

`isPublicWalkway` is the rule that decides whether you may drive through somewhere, so
it is worth having in full rather than by reference. It is exhaustive over
`MapAreaType` — the six below are all of them, and the getter ends in
`assertUnreachable` rather than a default:

```js
get isPublicWalkway() { switch (this.mapAreaType) {
  case Public: case Lobby: case Team: return true;
  case Common: case MeetingRoom: case Desk: return false;
  default: assertUnreachable(A) } }
```

**A go-kart's cadence is accepted: 21 `move`s a second, measured.** Every capture
before this one happened to be walking — a median 142 ms between moves — so driving
was three times a rate nothing had ever tested. Measured 2026-08-15 on the throwaway
space, instance B, by walking the same corridor twice at each pace:

| | sent | acks | non-`Success` | travelled | `/position/x` patches | biggest jump |
|---|---|---|---|---|---|---|
| 7/s (143 ms) | 20 | 20 | 0 | 12 | 12 | 1 |
| 21/s (48 ms) | 20 | 20 | 0 | 12 | 9 | 2 |

Row `y = 29` is walled west of `x = 32` and west of `x = 45`, so the corridor is 12
steps wide and a 20-move run has 8 moves it cannot make. Holding the path constant is
the point: **both paces reached the same wall**. Every move geometry allowed landed,
every action returned `Success`, and nothing was throttled or dropped. This also
demonstrates the refusal from
[the section above](#move-is-collision-checked-and-the-check-is-inside-setposition)
from the wire rather than from the source — 20 moves, 12 position changes, no error.

**Position patches coalesce, and driving is where you notice.** Same 12 tiles, 12
patches at a walk and 9 in a kart, with single patches carrying a 2-tile jump. So a
position patch is not "one step" and must never be drawn as one; `map_motion.dart`
paces each leg over the *gap that produced it* for exactly this reason.

The negative evidence agrees, and is worth keeping: `move` carries no
`rateLimitCost`, which only the map-editing actions do, at 0.5.

Byte for byte the same body as `shouldNavigateToTile`, which Gather keeps as a
separate getter directly above it. Two questions — "may I drive across this?" and
"does tapping here mean the tile or the room?" — that happen to partition the same
way; `space_map.dart` keeps them as two functions for the same reason.

**The third argument is not always a map, and that is the trap.** Four of these
send a bare value (`faceDirection` a string, `setHandRaised` a bool) and six
send no third argument at all — their `args` is two elements long. Sending
`{raised:true}` where the server wants `true` is a zod failure, and a zod failure
executes nothing. A client that assumes the `move`/`teleport` shape will find that
half this vocabulary silently does nothing.

**Availability is a value object on the way back and a bare string on the way
out.** `userSetAvailability` arrives as `{$type, value}`; `setAvailability` takes
`{availability: 'Busy'}`. `Offline` is written by the server when a connection
goes away — it is not one a client should set. `Focused` and `FocusedCoworking`
arrive on the field but come from entering a focus area, not from this action.

**`broadcastEmote` is how a wave is sent.** The eight in Gather's own tray, with
the codepoints, because two of them carry a variation selector and the string is
echoed to every other client exactly as sent:

| 👋 | ❤️ | 🎉 | 👍️ | 🤣 | 👏 | 💯 | 🔥 |
|---|---|---|---|---|---|---|---|
| `U+1F44B` | `U+2764 U+FE0F` | `U+1F389` | `U+1F44D U+FE0F` | `U+1F923` | `U+1F44F` | `U+1F4AF` | `U+1F525` |

`count` was `1` on every observed send and `ambientlyConnectedUserIds` was `[]`
even from a client that was in a call at the time — the server evidently works the
fan-out out for itself. It comes back on the event bus as `EmoteEvent`, whose
`targetUserIds` includes the sender, so you receive your own.

**`EmoteEvent` names its sender `senderUserId`, not `senderId`.** `WaveEvent` uses
`senderId`. A reader that keys on one loses the sender of the other, silently,
because both carry `targetUserIds` and so still route correctly.

All of the above except `startSpeaking`/`stopSpeaking`/`updateTargetMeetingArea`
are implemented in `packages/gather_client/lib/src/direct_collector.dart` and
asserted frame-for-frame in its test.

### Profile pictures: the id is not a URL, and the row does not carry one either

`SpaceUser.profilePictureId` is a `UserFile` id. Measured 2026-08-13 on a live
98-row space: **45 people had one**, and the other 53 had the field *absent*
rather than empty — bots and `Anonymous` rows share a single placeholder that the
API rejects as `Invalid UUID`, so "no picture" has to be read as a missing field
and not as something worth requesting.

The `UserFile` rows are in the state dump (60 of them, every one `type: Profile`)
and they are **not** enough:

```jsonc
{"id":"…","path":"<spaceId>/<uuid>.jpg","type":"Profile","mimeType":"image/jpeg",
 "originalWidth":512,"originalHeight":512,
 "originalFileUrl":undefined,"imageThumbnailUrl":undefined,"downloadFileUrl":undefined}
```

All three URL fields came across msgpack-undefined on all sixty rows, and the
bucket answers `403` to an unsigned request built from `path`. There is exactly
one route:

```http
GET /spaces/:spaceId/files/:fileId
→ 200 {"url":"https://profile-photos.gather.town/<path>?Expires=…&Key-Pair-Id=…&Signature=…"}
```

A CloudFront signature, **24 hours** out, and it needs **no authorization
header** — so the URL can go straight to an image loader that knows nothing about
Gather. `packages/gather_client/lib/src/profile_photos.dart` caches it, failures
included, because a busy office is a hundred faces on a screen that repaints four
times a second.

### The status line hangs off the status row, not off the person

`SpaceUserStatus` carries `spaceUserId`, and that is the only usable link.
`SpaceUser` has two fields that look like the pointer — `activeCustomStatusId`
and `activeUserGeneratedStatusId` — and on 98 rows **neither was ever set**,
including on people whose status was on screen at the time. Read from that side
and every status in the space is invisible.

```jsonc
{"op":"addmodel","model":"SpaceUserStatus","data":{
  "id":"…","spaceUserId":"…","text":"Test","emoji":"❤️",
  "clearCondition":"DateTime","clearAt":<ext-1 DateTime>,
  "type":"Custom","calendarEventVirtualId":null}}
```

Three things about it:

- **`clearCondition` is asymmetric.** `setCustomStatus` sends it as an object,
  `{type:'DateTime', clearAt:…}`; it comes back as the bare string `"DateTime"`.
- **`type` is `Custom` or `CalendarInferred`.** The second is written by Gather
  from a connected calendar — "Lunch 🥗" — and on the reference space 8 of 14
  statuses were that kind. Dropping them leaves most of an office blank. A person
  can hold both at once, and the typed one is the one to show.
- **The row outlives the status.** An expired one stays on the wire unchanged,
  with `clearAt` in the past — one set at 16:33 to clear at 17:03 was still there
  at 20:20. Gather's own client evidently filters on read, so a client that does
  not shows people at lunch all evening. Clearing a status is a `deletemodel` on
  this row; nothing on the `SpaceUser` side moves.

### An observer can move. Entering is not a prerequisite for writing

Measured 2026-08-07, settling what used to be Unverified #3. Every earlier
movement test had called `enterSpace` first, so the requirement was assumed
rather than shown. It is not required: a connection that sent only
`Authenticate` / `ConnectToSpace` / `Subscribe` / `loadSpaceUser` issued
`teleport` and got `{type:'Success'}` back, and the position patch followed.

This is the structural consequence of `SpaceUser` being per-person-per-space
rather than per-connection. `enterSpace` flips `Connection.entered`, which is
about *that socket*; `teleport` addresses the person's row, which every one of
their connections shares. So the observer is not a spectator with a read-only
handle — it drives the same avatar the desktop client draws.

Two things follow, and both matter:

- **Writing costs nothing.** `numTimesEnteredSpace` is only touched by
  `enterSpace`, so a collector that moves the user around still never increments
  the one counter that cannot be undone.
- **Read-only is a choice, not a property.** `DirectCollector` sends two kinds of
  write — `teleport` for party mode and `move` for the D-pad — and nothing else,
  because the gateway would let it send anything.

`packages/gather_client/lib/src/party.dart` and `walk.dart` are the consumers —
party mode moved into the app when the app got its own socket, and the D-pad was
only ever possible there — and they are the reason the walkability finding below is
load-bearing rather than trivia.

### `move` is collision-checked, and the check is inside `setPosition`

Read off the model, 2026-08-13; **corrected 2026-08-15**, when the check was finally
found one call deeper. This section previously said "`move` checks nothing" on the
strength of the three visible lines below. That was wrong, and the correction resolves
what looked like a contradiction with the frame capture — see the end of this section.

The action Gather's own client sends for a keypress is three lines and a delta:

```js
w(this, "move", MethodAction({
  target: this, id: "move", optimistic: true,
  requiredPermission: SpaceUserPermission.Move,
  argSchema: () => z.object({direction: z.nativeEnum(MoveDirection)}),
  fn: () => A => {
    const e = new Direction(A.direction).toPositionDelta();
    const g = new Position({x: this.x + e.x, y: this.y + e.y});
    this.direction = new Direction(A.direction);
    this.setPosition(g, {map: this.floor.activeMapOrThrow, prevPosition: this.position})
  }
}));
```

The three lines carry no test, but the fourth call does. `setPosition` is where a
`move` is arbitrated, and it refuses rather than clamps:

```js
setPosition(A, e) {
  const g = e?.map ?? this.floor.activeMapOrThrow;
  if (isNotNil(e?.prevPosition) && A.isBlockedBy(g, e?.prevPosition)) { return false }
  if (!this.isPermittedToMoveTo(A, g)) return false;
  this.position.x = A.x; this.position.y = A.y;
  return true
}
```

`isBlockedBy` is `blockedAtPosition` for the destination tile and `canPassThrough`
for the line between the two — the same pair `space_map.dart` transcribes.

Four consequences for anything driving an avatar over this socket:

- **It turns whether or not it moves.** `direction` is assigned before `setPosition`
  is consulted, so a `move` into a wall turns you to face the wall and moves nobody.
  This is what the frame capture saw: 36 `/direction` patches against 26 position
  patches for the same 36 moves — see
  [`observed-wire-protocol.md`](protocol/observed-wire-protocol.md). Ten of those
  moves were refused, not "turns in place".
- **The client sends them anyway.** `gameMove(A)` is
  `currentSpaceUser.move({direction: A.value})` with no collision test in front of
  it, and `onArrowKeyDown` pumps it on an interval regardless of what is ahead. The
  desktop client does not decide whether a step is legal — it asks, every 143 ms,
  and lets the model answer.
- **A second client must still re-implement collision, for a different reason than
  this document used to give.** Not because nothing else would stop it, but because
  a refused `move` changes nothing and says nothing: there is no rejection on the
  wire, only a position patch that does not arrive. Without the same rule locally,
  an optimistic tile runs ahead of an avatar that never left. `SpaceMap.canStep` is
  that re-implementation; `walk.dart` is the caller, and it hands the *wall* case to
  Gather (so the turn happens) while keeping the off-grid case to itself.
- **`optimistic: true` is a hint about latency, not about trust.** The client applies
  the same `fn` locally, so its optimistic step runs the same `setPosition` gate and
  is refused in the same place — which is how it stays in sync without being told.
  The phone still has to track its own tile: the roster is coalesced at 250 ms and a
  walk runs at seven tiles a second, so the wire is always two steps behind the thumb.

**A second gate sits behind the first.** `isPermittedToMoveTo` refuses any position
inside a private area you may not enter, and it applies to `teleport` as well:

```js
isPermittedToMoveTo(A, e) {
  const g = e.areaPositions.privateAreaAtPosition(A);
  if (isNotNil(g) && !g.canBeEnteredBy(this)) {
    publishEvent(g.currentMeeting?.id
      ? GameEvents.UserIsNotPermittedToEnterMeetingArea
      : GameEvents.UserIsNotPermittedToEnterLockedArea, …,
      {targetUserIds: new Set([this.id])});
    return false
  }
  return true
}
```

Note where the refusal goes: an **event**, addressed to you alone, and no patch at
all. The action still returns `Success`. A client that only applies patches learns
nothing except that it did not move.

The door itself is `MapArea.canBeEnteredBy`, five clauses deep:

```js
canBeEnteredBy(A) {
  if (!this.isLocked) return true;                                          // 1
  if (this.isDesk) { if (this.deskOwner?.id === A.id) return true }         // 2
  const e = this.currentMeeting;
  if (isNotNil(e) && e.canSpaceUserAccess(A)) return true;                  // 3
  const g = Object.values(this.mapEntityIdentifier.areaAccessRequests)
    .find(e => e.spaceUserId === A.id && e.responseStatus === Accepted);
  if (g) return true;                                                       // 4
  if (A.isInOffice &&
      A.currentPrivateMapArea?.stableId_USE_THIS_INSTEAD_OF_ID === this.stableId…)
    return true;                                                            // 5
  return false
}
```

and the area it is asked about is `privateAreaAtPosition` — the **last walled** area
covering the tile, `last` rather than smallest, which is not the same question
`areaAtPosition` answers.

`space_map.dart`'s `canEnterRoom` answers all five, four of them whole;
`privateAreaAt` is the lookup. Clauses 3 and 4 need two more models, and **the join
is the part worth writing down** — both are
`ReverseRelationReference(this, …, "areaId")` on **`MapEntityIdentifier`**, so
`AreaAccessRequest.areaId` and `Meeting.areaId` carry the `stableId` an area hangs
off and never `MapArea.id`. Getting that backwards finds nothing, silently, and locks
everybody out.

| clause | model | rule |
|---|---|---|
| 4 | `AreaAccessRequest` | `spaceUserId` is mine and `responseStatus` is `Accepted` |
| 3 | `Meeting` + `MeetingParticipant` | I hold a participant row on a meeting whose `areaId` is this area |

Clause 3 is the partial one, and deliberately so. `canSpaceUserAccess` opens with
`if (isNotNil(this.meetingParticipantsBySpaceUserId[A.id])) return true` — being
*listed* is the whole test, with no response status about it — and then falls through
to `combinedCalendarEvent.isSpaceUserAttendeeOrOrganizer` for anybody who is not,
which is a chain of calendar models this app has no reason to read. So somebody
invited by calendar alone, never added as a participant, still answers false locally.

Two loosenesses go the other way, on purpose: any meeting on the area counts rather
than only the current one, and a participant row is taken at face value. **Erring
towards yes is the safe direction here**, because the server holds the real rule,
refuses the move, and publishes a refusal the app handles (`AppState.notices`).
Erring towards no is the failure with no way back — it never sends anything, so
nothing can correct it. Gather's own client pre-refuses in exactly the same place,
with `onLeftDoubleClick` publishing `AttemptToMoveToLockedArea`.

### The server does not validate walkability *for a teleport*

Eight teleports to uniformly random tiles across the full 124×82 grid were **all
accepted**, including tiles at the map edges that are certainly wall or void. No
rejection, no clamping, no collision check.

Corrected 2026-08-15: this said "**collision is enforced client-side only**", which
generalised the result from `teleport` to `move` and is wrong — see
[`move` is collision-checked](#move-is-collision-checked-and-the-check-is-inside-setposition).
One line of `teleport`'s body explains both halves at once:

```js
fn: () => A => {
  const e = {x: this.x, y: this.y};
  const g = this.setPosition(new Position(A.x, A.y), {map: this.floor.activeMapOrThrow});
  if (g) { this.direction = new Direction(A.direction); publishEvent(Teleport, …) }
}
```

`move` passes `prevPosition` and `teleport` does not, and `setPosition` guards its
collision test on `isNotNil(prevPosition)`. So the gate is not disabled for
teleports, it is *unreachable* — there is no previous tile to have crossed a wall
from. A hop is unvalidated because it has no line to check, not because the server
trusts clients.

Two details that follow, both load-bearing for `party.dart`:

- **`isPermittedToMoveTo` still runs.** A teleport into a locked or private area you
  cannot enter is refused like any move. Walkability is not checked; permission is.
- **A refused teleport does not even turn you.** `direction` is assigned inside the
  `if (g)`, so nothing at all changes.

Map bounds come from the base `MapArea`: `FloorMap.baseAreaId` names it, and its
`dimensionsInTiles` is an ext-0 `{$type:'Dimensions', width, height}` — 124×82 for
the space measured here.

### The whole map is in the state dump

Measured 2026-08-07 with `tool/probe-connect.mjs map` and `walkable`.

**There is no REST route for it.** `/spaces/<id>/maps`, `/spaces/<id>/floors` and
`/spaces/<id>/map` all 404; `/spaces/<id>` answers `{"exists":true}` and nothing
more. None is needed — the map arrives on the game socket like everything else, and
this client threw it away until now.

Four models carry it:

| model | rows | what it contributes |
|---|---|---|
| `FloorMap` | 1 | `baseAreaId` → the base area; `floorId` → which floor this is |
| `MapArea` | 93 | rectangles: the grid itself, rooms, desks, team zones |
| `MapObject` | 1140 | furniture, each naming a `CatalogItemVariant` |
| `CatalogItemVariant` | 477 | the shapes, including `collision` |

**`collision` is `{points: [{x, y}, …]}`** — a list of tile offsets the object
blocks, *not* a bitmask. 341 of the 477 variants block nothing at all (rugs,
posters, things standing on desks); the rest block one to six tiles. `sittable` has
the same shape.

#### The decoding, transcribed from the client

The first attempt at this inferred the rules by sweeping every plausible rounding
against the live roster and keeping whichever put nobody inside a wall. It produced
a self-consistent answer that was **wrong in 425 of about 500 tiles**, and the check
could not tell: only eleven people were connected, and four mutually contradictory
rules all scored zero. Eleven positions is not enough to derive anything from.

The rules below are therefore read out of the client instead. The desktop app is an
Electron shell with no game code in it (`app.asar` has no `dimensionsInTiles`, no
`catalogItemVariant`); it loads `app.v2.gather.town`, whose entry `main.js` names 79
lazy chunks. The collision engine is in `bundle.fcbc27cfb33c44ea.js` — class
`Collisions`, plus getters on `MapObject` and `MapArea`. Constants live in `main.js`:
`TILE_SIZE = 32`, `MAX_HIERARCHY_DEPTH = 20`.

#### Where to find the bundle again

Worth writing down, because it is not where anyone looks first and finding it took
longer than reading it. The installed app is **`GatherV2.app`**, not `Gather.app`, and
its `app.asar` is 7798 files of which only 84 are Gather's own — all shell, no game.
The engine is in the Electron HTTP cache, uncompressed:

```
~/Library/Application Support/GatherV2/Cache/Cache_Data/
```

Chromium's simple-cache format puts a header in front of the body: skip
`20 + readUInt32LE(offset 12)` bytes and the rest is plain JavaScript. The key string
sits at offset 20, so a directory of entries can be grepped for the one you want.
At the time of writing that was `bundle.c2029c930c00996`, 10.3 MB, containing
`webpackChunkgather_browser` — the pathfinder (module 22795, `Hh`), the tile
highlighter, `moveSpaceUserToMapArea`, and the `MapArea` getters. Bundle hashes change
on every release; the cache layout does not.

**Absolute position** — `MapEntity#absolutePosition`. The plain sum of
`relativeX`/`relativeY` up the parent chain, no rounding anywhere, depth-capped at 20:

```js
get absolutePosition(){
  const A = new Position({x:this.relativeX, y:this.relativeY});
  let e = this.parent, g = 0;
  while (e && g < MAX_HIERARCHY_DEPTH) { A.x += e.relativeX; A.y += e.relativeY; e = e.parent; g++ }
  return A;
}
```

**An object's collision tiles** — the pixel origin is backed out *before* rounding,
which is the step no amount of coordinate-staring would produce:

```js
get topLeftAbsolutePosition(){           // MapObject; on MapArea it is absolutePosition
  const A = this.absolutePosition;
  return {x: A.x - variant.originX/TILE_SIZE, y: A.y - variant.originY/TILE_SIZE};
}
get absoluteCollisionPositionHashes(){
  const A = this.topLeftAbsolutePosition;
  return variant.collisionPositions.map(e =>
    hashOf({x: Math.round(A.x + e.x), y: Math.round(A.y + e.y)}));
}
```

**Not every object collides.** `activeAbsoluteCollisionPositionHashes` returns `[]`
unless `isSpecialEffectActive`:

```js
get isSpecialEffectActive(){ return !this.parentObjectId && !this.isSnappedToWall }
get isSnappedToWall(){
  if (!this.canSnapToWalls) return false;
  if (!this.parentAreaId) return false;
  return Math.floor(this.relativeY) === 0;
}
get canSnapToWalls(){                    // abridged
  if (!this.parentMapArea?.isWalled) return false;
  if (family === "Chair" || family === "Desk") return false;
  return collisionTiles.every(sameY) || sittableTiles.every(sameY);
}
```

So anything sitting on top of something else, and anything flush against a wall,
contributes nothing — 28 and 50 objects respectively on the measured space. Counting
them was most of the original error. The `family` test is why `CatalogItem` has to be
retained alongside `CatalogItemVariant`.

**Walls do not block tiles.** The easiest thing here to get backwards.
`Collisions.addArea` records *blocked directions* — pairs of adjacent tiles you may
not move between — not impassable tiles:

```js
addArea(A){
  if (!A.isWalled) return;
  const e = A.absolutePosition;
  const g = new Set(A.doorwayPositionHashes);              // relative to the area
  for (let t = 0; t < A.dimensionsInTiles.width; t++) {
    if (t === 0 || t === A.dimensionsInTiles.width - 1) {  // the sides
      for (let I = 0; I < A.dimensionsInTiles.height; I++) {
        if (g.has(Position.hashOf({x: t, y: I}))) continue;
        const i = Position.hashOf({x: e.x + t, y: e.y + I});
        const outside = Position.hashOf({x: e.x + t + (t === 0 ? -1 : 1), y: e.y + I});
        this.addBlockedDirection(A.id, outside, i)
      }
    }
    if (!g.has(Position.hashOf({x: t, y: 0}))) {           // the top
      this.addBlockedDirection(A.id,
        Position.hashOf({x: e.x + t, y: e.y}),
        Position.hashOf({x: e.x + t, y: e.y - 1}))
    }
    if (!g.has(Position.hashOf({x: t, y: A.dimensionsInTiles.height - 1}))) {
      this.addBlockedDirection(A.id,                        // and the bottom
        Position.hashOf({x: e.x + t, y: e.y + A.dimensionsInTiles.height - 1}),
        Position.hashOf({x: e.x + t, y: e.y + A.dimensionsInTiles.height}))
    }
  }
}
blockedAtPosition(A){ return this.mapEntitiesAtPosition(A).size > 0 }   // objects only
canPassThrough(A,e){ return !blockedDirections.has(A.hashPair(e)) && !...has(e.hashPair(A)) }
```

`blockedAtPosition` consults only the object map, so **a wall tile is standable** —
488 perimeter tiles the first version excluded are perfectly good floor. Since a
teleport is not a move, blocked directions never apply to it at all; the D-pad walks,
so they are the only thing keeping it indoors.

Two details of `addArea` are not what the wall *art* would lead you to expect, and
both were only settled by reading it:

- **The side walls run the full height** — `I` from 0 to `height - 1`. The drawing
  loop in `space_art.dart` stops three rows short, because the north and south bands
  are two tiles tall and cover the corners visually. Following the art here would
  leave a walkable gap at the bottom of every room in the office.
- **`canPassThrough` asks its set both ways round**, so a wall keeps you in exactly
  as firmly as it keeps you out. `space_map.dart` gets the same answer by naming each
  line once — against the further of the two tiles it separates — instead of storing
  both orderings.

**`isWalled`** is `wallsTexture !== "NewStyleNoWall"` — 19 of 93 areas here. Gather
also defines `get isPrivate(){ return this.isWalled }`, which is a statement about
audio and not one about buildings: the walled areas here include the 44×34 `Public`
main floor and the Lobby, which between them hold every connected person. Reading it
as "do not teleport here" excluded the whole office. `space_map.dart` narrows it to
`MeetingRoom` and `Desk` — walls plus a door — and separately requires a party tile
to be inside some non-base area at all, since walls block directions rather than
tiles and the void outside the building is therefore "walkable" to a teleport.

|                                    | tiles |
| ---------------------------------- | ----: |
| grid (the base area)                | 10168 |
| walkable — furniture removed        |  9705 |
| inside the office (92 other areas)  |  2774 |
| minus closed rooms → party pool     |  1447 |

Of 112 captured people: 94 stood in the party pool, 7 in closed rooms, 11 on tiles
this decoding calls furniture, and **none outside the office footprint**.

**Doorways** are two tiles, expanded from each `{origin, orientation}` in coordinates
relative to the area:

```js
get doorwayPositionHashes(){
  return this.doorways.locations.flatMap(({origin:A, orientation:e}) => [
    hashOf(A),
    e === "Horizontal" ? hashOf({x:A.x+1, y:A.y}) : hashOf({x:A.x, y:A.y+1}),
  ]);
}
```

Result on the measured space: **463 blocked of 10168 tiles, 9705 walkable.**
`packages/gather_client/lib/src/space_map.dart` is the transcription; live positions
are kept as a regression check (nobody may stand on a blocked tile) rather than as
the source of truth.

### The art is fetched one file at a time, and there is no tileset

Measured 2026-08-13, against the same space. `packages/gather_client/lib/src/space_art.dart`
is the transcription, `lib/src/art_cache.dart` the fetching.

**There is no per-space art bundle.** The client resolves one image per floor
texture, per wall piece and per furniture variant, fetches each on its own, and packs
them into a texture atlas in a web worker at runtime (`Atlas Manager`, class `Aq`).
Two of the three kinds of image live on the app origin and one on the catalog CDN:

| what | where | size |
|---|---|---|
| floor tiles | `app.v2.gather.town/images/studio/new-assets/walls-and-floors/floors/…` | 32×32, tiled |
| wall pieces | `…/walls/<Style>/thin wall <n\|ne\|e\|…>.png` | 32×64 top and bottom, 32×32 sides |
| furniture | `static.gather.town` + `CatalogItemVariant.mainRenderable.imageUrl` | the variant's `dimensionsInPixels` |
| avatars | `sprite.v2.gather.town/v2/sprite/avatar-<hash>.png` | 2304×64 — 72 frames of 32×64 |

**All of it is public.** Fetched with no cookies and no `Authorization`, every one
answers 200. The whole office measured here is **573 images totalling 222 KB**,
because pixel art at 32×32 is a few hundred bytes a file — which is why a phone can
simply download the lot.

**A floor's filename is composed, not stored.** `MapArea` carries `floorTexture` and
`floorColor`; the client joins them:

```js
function d(A,e,g){                          // texture, colour, isDark
  const t=o[A]; if(!t) return undefined;    // WoodSlats -> Wood_Slats
  const I=r[A]; if(I&&!I.includes(e)) return undefined;   // NewStyleGrass: Green only
  return `${t}_${E[e]}${g?"_Dark":""}.png`; // -> Wood_Slats_Wood_Dark.png
}
```

Falling back, when that yields nothing, to a flat per-theme table keyed by texture
alone. Dark is a **different set of files**, not a suffix: the wood floors are a
later re-cut (`Redux_Wood_Slats_Dark_v2.png`).

**The ground is layered, and the layers are a lookup rather than a coordinate.**
This is the part that looks like a bug when it is got wrong. `updateFloorsDepth`
starts from `getBaseDepthForSimplifiedAreaFloor`:

```js
if (A.isBaseArea) return YZ.BaseAreaGround;                           // 0
if (A.mapAreaType === MapAreaType.Public) return YZ.PublicAreaGround;  // 2
return YZ.AreaGround;                                                  // 4
```

and only then adds `AD(bottomEdge)/9999 + depth/1000`, both under a thousandth of the
gap between layers. Sorted by position instead, the base area — the whole grid, so
the lowest bottom edge on the map — paints over every room inside it, and the office
renders as bare ground.

**Walls belong to their area's ground band.** An area is one Phaser container whose
depth is its floor's, so every wall sits under every piece of furniture: an object in
front of a wall covers it. Occlusion the other way is what `foregroundRenderable` is
for — 61 of 477 variants carry a second image that draws over whoever is standing
behind it.

**Furniture sorts by its fold, not its row.** `updateDepth` is
`topLeftAbsolutePosition.y * 32 + renderable.fold`, where `fold` (0…137 here) is the
pixel line inside the sprite that meets the floor. Anything nested inside another
object takes its parent's depth with its own tucked in behind the decimal point, so a
lamp travels with the desk it stands on.

### Avatars are composited by the server, and the hash is not a hash

`SpriteService.hashOutfit` reads like a digest and is not one. It is the outfit's
wearable ids joined with `SPRITESHEET_DELIMITER` — which is `"."` — followed by the
newest `lastSyncAuthoredAt` among those wearables, formatted `yyyyMMdd'T'HHmmss'Z'`:

```
avatar-<skin>.<hair>.<top>.…20260804T081737Z.png
```

Three things are load-bearing and all three were checked against the live service,
because getting any of them wrong is a 404 rather than an odd-looking person:

- the delimiter is a dot, so a hash is a run of UUIDs and the timestamp is one more
  field;
- the order is `toOutfit()`'s pick order (`skin`, `hair`, `facialHair`, `top`,
  `bottom`, `shoes`, `hat`, `glasses`, `other`, `costume`, `mobility`, `jacket`), not
  the wire's;
- the timestamp is Luxon's format string to the second, not an ISO-8601 round trip.

Two models are needed and neither answers alone: `SpaceUserOutfit` (66 rows here, for
111 people — an outfit is not guaranteed) and `Wearable` (144–157). The sheet that
comes back is 72 frames of 32×64 in one row, and the frame to draw is in the client's
own animation table: `idle-s` 0, `idle-w` 9, `idle-n` 18, `idle-e` 23; `walk-s`
32–35, `walk-w` 40–43, `walk-n` 48–51, `walk-e` 56–59; `run-s` 36–39, `run-w` 44–47,
`run-n` 52–55, `run-e` 60–63 (chosen on `speed.modifier > 1`, which was 1 on all 98
rows measured); `dance` 12–15; the sitting poses at 5, 14, 21, 28. Frame rates come
with the table: the walk and the run at **7fps**, the talking loops at 4, a blink at
10, and a still pose declared as one frame at 60. The talking loops are the idle frame
with the mouth-open frame — always idle + 1 — laid over it by a hand-authored mask,
three variants per direction picked at random so a table of people is not chewing in
unison. Sprites hang one tile above the body's own tile (`defaultAvatarOffsetY =
-32`), which is what puts the feet on the floor.

**`direction` is a value object, not a string.** It arrives as `{$type: 'Direction',
value: 'Right'}` — the same shape as `userSetAvailability` — and a field patch on it
comes through as `/direction/value`. Read as a bare string it is null for everybody,
and since anything unrecognised means south, the symptom is a whole office facing the
camera rather than an obviously missing field.

**Movement is not on the wire either.** Positions are whole tiles, so a client that
draws them literally shows people teleporting. `PlayerEntityV2.preUpdate` interpolates
linearly between the old and new position over `MOVEMENT_DURATION = 1e3/7` ms per
tile — the same seven the walk cycle runs at, so a body advances one frame per tile —
and `setTargetPosition` snaps instead of sliding when the distance exceeds
`TILE_SIZE * 8` or when the user prefers reduced motion. Separately,
`SpaceUser.isMoving` is `!doneMoving`, an observable threshold that stays true for
**250 ms** after the last change to `position.x`/`y`.

**Sitting is not on the wire.** `PlayerEntity.isSitting` reads `playerState`, which
is the client's own field and is never published — so a second client cannot be told
who is sitting and has to derive it the way Gather does: you are sitting when you are
standing on a chair's `sittable` tile. Those tiles are placed exactly like collision
tiles (`activeSittableAbsoluteTiles`: origin backed out, rounded, gated on
`isSpecialEffectActive`), and unlike collision tiles they stay walkable — a chair you
could not stand on would be a chair nobody could sit in. The seated frame then uses
the person's own `direction`, which the server does publish and does update when they
sit down.

### Entering costs something

`enterSpace` increments **`numTimesEnteredSpace`** on your own `SpaceUser`, once per
call. Across one session of testing it went 74 → 83. It is a permanent counter on
the user's profile and there is no way to decrement it, which is the main reason
`DirectCollector` stays in observer mode: a collector that reconnects on every
network blip would inflate it forever.

Being `entered` presumably also marks you present for idle/availability purposes.
Not measured.

## What arrives in a state dump

Captured from one observer connection to a 111-member space. **4 `FullStateChunk`s, 5355 patches, 46 distinct models.** Row counts are specific to that space; the shape is what generalises. Value types: `$X` is a msgpack ext-0 value object, `absent` is ext-4 (undefined).

| Model | Rows | Fields |
|---|---|---|
| **BaseCombinedCalendarEvent** | 1739 | `id` `spaceId` `externalEventId` `provider` `title` `description` `rawLocation` `startDateTime` `startDate` `startTimeZone` `endDateTime` `endDate` `endTimeZone` `originalStartDateTime` `originalStartDate` `originalStartTimeZone` `attendees` `recurrence` `recurringEventId` `organizerEmail` `isDeleted` `meetingJoinInfoId` `sourceEventId` |
| **MapObject** | 1140 | `id` `parentAreaId` `parentGroupId` `parentObjectId` `relativeX` `relativeY` `deletedAt` `spaceId` `mapId` `hashIdentifier` `catalogItemVariantId` `createdAt` `updatedAt` |
| **CatalogItem** | 558 | `id` `category` `family` `type` `description` `tags` `version` `lastSyncAuthoredAt` `order` `mapObjectBehaviorTemplate` `behaviorConfig` `createdAt` `updatedAt` |
| **CatalogItemVariant** | 477 | `id` `color` `orientation` `dimensionsInPixels` `offsetInPixels` `mainRenderable` `foregroundRenderable` `visualStates` `originX` `originY` `isDefault` `catalogItemId` `collision` `sittable` `isPublished` `createdAt` `updatedAt` |
| **GithubPullRequest** | 171 | `id` `spaceUserId` `authorGithubId` `githubPrNumber` `repositoryId` `repoFullName` `title` `state` `reviewers` `reviewerIds` `openedAt` `lastUpdatedAt` `spaceId` `createdAt` `updatedAt` |
| **Wearable** | 144 | `id` `color` `name` `type` `previewUrl` `lastSyncAuthoredAt` `order` `isPublished` `createdAt` `updatedAt` |
| **UserAccount** | 111 | `id` `firebaseAuthId` `email` `hubSpotContactId` `selectedLanguage` `isBot` `createdAt` `updatedAt` |
| **SpaceUser** | 111 | `id` `name` `coreRole` `position` `spaceId` `direction` `floorId` `speed` `profilePictureId` `followTargetId` `userAccountId` `userSetAvailability` `clusterId` `deskId` `shouldBeInClusterWithFollowTarget` `connected` `isIdle` `activeApp` `handRaisedAt` `isBot` `speaking` `dancing` `lastOnlineAt` `aiSummary` `firstBecameMemberAt` `currentTargetMeetingAreaId` `shouldBeInClusterWithOthersWithSameTargetMeetingArea` `calculatedPrimaryCalendarEmail` `deskAssignmentStatus` `numTimesEnteredSpace` `activeCustomStatusId` `activeCalendarInferredId` `activeUserGeneratedStatusId` `type` `githubHandleExperimental` `assignedGitHubUserId` `hasConnectedCalendars` `activeMapObjectInteractionId` `createdAt` `updatedAt` |
| **ChatMessageMetadata** | 108 | `id` `chatMessageId` `metadata` `createdAt` |
| **MeetingJoinInfo** | 107 | `id` `spaceId` `linkId` `areaId` `status` `hostId` |
| **MapEntityIdentifier** | 93 | `id` `spaceId` `floorId` `chatChannelUrl` `isLocked` `lockState` |
| **MapArea** | 93 | `id` `parentAreaId` `parentGroupId` `parentObjectId` `relativeX` `relativeY` `deletedAt` `spaceId` `mapId` `mapEntityIdentifierId` `dimensionsInTiles` `mapAreaType` `aiSummary` `capacity` `name` `doorways` `wallsTexture` `floorTexture` `floorColor` `createdAt` `updatedAt` |
| **SpaceUserOutfit** | 66 | `id` `skin` `hair` `facialHair` `top` `bottom` `shoes` `hat` `glasses` `other` `costume` `mobility` `jacket` `spaceId` `spaceUserId` `createdAt` `updatedAt` |
| **SpaceTemplate** | 61 | `id` `spaceId` `numberOfDesks` `deskType` `officeStyle` `createdAt` `updatedAt` |
| **UserFile** | 60 | `id` `uploaderUserId` `chatMessageId` `spaceId` `path` `type` `originalWidth` `originalHeight` `mimeType` `fileName` `sizeBytes` `originalFileUrl` `imageThumbnailUrl` `downloadFileUrl` `createdAt` `updatedAt` |
| **ThirdPartyEvent** | 51 | `id` `spaceId` `type` `eventType` `title` `url` `handle` `gitHubUserId` `createdAt` `updatedAt` |
| **MeetingParticipant** | 48 | `id` `spaceUserId` `meetingId` `inviterId` `isHost` `inviteStatus` `responseStatus` `firstJoinedAt` `lastDepartedAt` `intentionallyLeftAt` `createdAt` `updatedAt` |
| **ChatChannelMember** | 47 | `id` `spaceUserId` `chatChannelId` `createdAt` `updatedAt` |
| **ChatMessage** | 37 | `id` `message` `spaceId` `spaceUserId` `chatChannelId` `threadParentId` `showThreadReplyInChannel` `editedAt` `computedThreadPreview` `type` `createdAt` `updatedAt` |
| **SpaceUserStatus** | 24 | `id` `spaceUserId` `text` `emoji` `clearCondition` `clearAt` `type` `calendarEventVirtualId` `createdAt` `updatedAt` |
| **CoworkingSession** | 19 | `id` `creatorId` `areaId` `spaceId` `type` `scheduledToStartAt` `scheduledToEndAt` `canceledAt` `focusedSeconds` `pomodoroRounds` `pomodoroWorkSeconds` `pomodoroBreakSeconds` `inPomodoroWorkSegment` `spotifyJamUrl` `topic` `createdAt` `updatedAt` |
| **MapObjectBehaviors** | 13 | `id` `mapObjectId` `mapObjectBehaviorTemplate` `githubWorkloadTrackerBehavior` `gongBehavior` `embeddedWebsiteBehavior` `webhookObjectPreset` `webhookObjectCapabilities` `spaceId` `createdAt` `updatedAt` |
| **ChatChannel** | 10 | `id` `spaceId` `creatorId` `meetingId` `name` `description` `type` `unreadPreview` `createdAt` `updatedAt` |
| **GitHubOAuthUserSecret** | 9 | `id` `accessToken` `refreshToken` `accessTokenEncrypted` `refreshTokenEncrypted` `accessTokenExpiryDate` `refreshTokenExpiryDate` `kmsKeyId` `encryptionContext` `accessTokenEnvelope` `refreshTokenEnvelope` `spaceUserId` `spaceId` `gitHubUserId` `createdAt` `updatedAt` |
| **Meeting** | 8 | `id` `status` `recurringMeetingId` `meetingType` `visibility` `actualStartDate` `actualEndDate` `meetingRestartedAt` `isResuming` `scheduledToEndAt` `virtualCalendarEventRefId` `canInviteesInviteOthers` `canInviteesModifyDetails` `canInviteesSeeOtherInvitees` `isTranscribing` `areaId` `spaceId` `primaryHostId` `isCanceled` `meetingCreationDate` `meetingJoinInfoId` `baseCombinedCalendarEventId` `areaLastAutoAssignedAt_TEMP` `externalMeetingLocationType` `activeRecordingId` `createdAt` `updatedAt` |
| **MeetingArtifact** | 8 | `id` `meetingId` `artifactType` `chatChannelId` `meetingMemoId` `meetingRecordingId` `createdAt` |
| **MeetingArtifactAccess** | 8 | `id` `meetingId` `artifactId` `targetType` `accessLevel` `grantedByUserId` `targetUserId` `targetChatChannelId` `createdAt` `updatedAt` |
| **SpaceInvitation** | 8 | `id` `spaceId` `coreRole` `inviterId` `createdAt` `updatedAt` |
| **OutfitTemplate** | 3 | `id` `skin` `hair` `facialHair` `top` `bottom` `shoes` `hat` `glasses` `other` `costume` `mobility` `jacket` `createdAt` `updatedAt` |
| **ExternalCalendar** | 2 | `id` `spaceId` `name` `externalId` `createdAt` `updatedAt` |
| **ExternalCalendarConnectionAccess** | 2 | `id` `externalCalendarConnectionId` `externalCalendarId` `primary` `color` `visible` `accessRole` `aclList` `createdAt` `updatedAt` |
| **SpaceCustomerPlanInterval** | 2 | `id` `spaceId` `customerPlanIntervalId` `createdAt` `updatedAt` |
| **CustomerPlanInterval** | 2 | `id` `startDate` `endDate` `plan` `activatedAt` `entitlementOverrides` `ubbLimitOverrides` `pricingServiceSubscriptionId` `createdAt` `updatedAt` |
| **PricingServiceSubscription** | 2 | `id` `externalProvider` `externalProviderSubscriptionId` `canceledAt` `status` `collectionMethod` `billingInterval` `stripeBillingPeriodPriceId` `prorationUnitAmount` `memberCount` `freeMemberCount` `linkedV1SpaceId` `billingPeriodStart` `billingPeriodEnd` `oneTimeDiscounts` `paymentFailedAt` `paymentFailureContext` `pricingServiceCustomerId` `createdAt` `updatedAt` |
| **ActivityEvent** | 2 | `id` `metadata` `spaceId` `isGlobal` `createdAt` `updatedAt` |
| **Connection** | 1 | `id` `spaceId` `authUserId` `spaceUserId` `entered` `target` `studioUserSessionId` `clientPlatform` `isActive` `lastActiveAt` |
| **Space** | 1 | `id` `name` `landingFloorId` `createdAt` `updatedAt` |
| **SpaceSettings** | 1 | `id` `spaceId` `memberToMemberInvitesEnabled` `guestCheckInEnabled` `emailDomainAuthEnabled` `allowedEmailDomains` `gatherStaffAccessEnabled` `showAssist` `isStudioEnabled` `paymentsEnabled` `isMeetingForwardOnboardingEnabled` `isStatusForwardOnboardingEnabled` `autoLockDesksDefault` `enableAmbientAudio` `ambientAudioRange` `allowAccessWhenSpaceDeactivated` `enableGatherChatChannels` `enableGatherChatInMeetings` `enableSendNearbyInMapView` `enableDirectMessages` `smartObjectsEnabled` `dailyInviteLimit` `createdAt` `updatedAt` |
| **SpaceUserOnboarding** | 1 | `id` `spaceUserId` `completedOnboardingTasks` `completedContextualOnboardingPOIs` `hasDismissedOnboardingModal` `hasDismissedGatherAssistPrompt` `hasDismissedOnboardingModalPrompt` `hasCompletedAllAmbientConnectionTasks` `hasCompletedAllStrongConnectionTasks` `shouldSeeSpaceCreatorFlow` `inviterSpaceUserIds` `createdAt` `updatedAt` |
| **Floor** | 1 | `id` `spaceId` `name` `order` `previewFilePath` `createdAt` `updatedAt` |
| **FloorMap** | 1 | `id` `status` `baseAreaId` `lastSyncAt` `lastEditedAt` `sourceTemplateFloorId` `floorId` `spaceId` `createdAt` `updatedAt` |
| **UserMapHistory** | 1 | `id` `historyCommands` `undoOffset` `mapId` `userId` `createdAt` `updatedAt` |
| **StudioUserSession** | 1 | `id` `spaceId` `mapId` `spaceUserId` `isDirty` `isOpen` `lastHeartbeat` `target` `createdAt` `updatedAt` |
| **ExternalCalendarConnection** | 1 | `id` `externalId` `spaceId` `spaceUserId` `type` `lastSyncedAt` `lastSyncTokenOrUrl` `syncing` `createdAt` `updatedAt` |
| **GrapevineIntegration** | 1 | `id` `spaceId` `tenantId` `createdAt` `updatedAt` |
| **GitHubAppInstallation** | 1 | `id` `spaceId` `gitHubOrganizationId` `gitHubAppInstallationId` `gitHubAppInstallationRequestId` `gitHubAppInstallationStatus` `createdAt` `updatedAt` |

The count drifts between connections (46–48 observed) because rows like
`StudioUserSession` or `SpaceUserCluster` only exist while something is live.

Three things to take from this table:

- **The bridge consumes 3 of ~47 models** (`SpaceUser`, `Connection`, `UserAccount`)
  and applies ~223 of ~5,350 patches. The other 96% is map geometry, the furniture
  catalog and calendar events.
- **`Connection` has exactly one row: yours.** Other clients' connections are not
  visible, including your own desktop client's. So you cannot detect another
  session of your own from state — that is why the eviction test needed CDP.
- Everyone's `UserAccount` is included, and in the measured space **67 of 111 rows
  carried a real email address**. Outfits (`SpaceUserOutfit`) and custom statuses
  (`SpaceUserStatus`) are there too. A direct collector therefore holds a lot of
  colleague PII in memory even though only eight fields per player reach the phone.

### Checked because they looked alarming

- `GitHubOAuthUserSecret` arrives with **one row per member who connected GitHub**,
  including other people's — and the field list contains `refreshToken`. Checked:
  **no row carries token material.** The encrypted variants are absent and the token
  strings are empty, so the server strips them. Not a leak.
- `ChatMessage` rows arrive (43, from 18 distinct authors) but **every body is empty
  and `type` is `'System'`**. Message text is not exposed to an observer connection,
  so the bridge's unused `chat.message` event cannot be filled from here.

  **Scope corrected 2026-08-13: this is a property of the game socket, not of the
  account.** The same rows fetched over REST *do* carry their text. Two Meeting
  channels read through `/chat/channels/:id/messages` returned 11 of 30 and 4 of 48
  messages with non-empty bodies, all `type: 'Regular'`; the empty ones are
  `'System'` rows, which is what a wave is, and those are genuinely empty
  everywhere. So message text is withheld from the *socket*, and is one REST call
  away. See [The activity feed](#the-activity-feed).

## Media — the SFU

Separate from the game socket, and **standard mediasoup**, not a bespoke protocol.
Re-read from the bundle 2026-08-13; this section used to be a partial grep for
`sendWithResponse(` literals and listed seven methods, which is not enough to build
a client — transport creation was missing entirely.

### The strategy is not configurable

The A/V strategy map is hardcoded to two entries and only one is implemented:

```js
const rW = { base: () => undefined, gather: (e,t) => new rG(e,t) };
```

The interface declares `base | gather | livekit | livekitselfhost`, but the LiveKit
variants are **never provided**, and the server-side gate returns `"gather"` on both
branches. **LiveKit is meeting *recording* only** (`/hooks/livekit/recording/…`,
`LivekitRecordingObjectKey`). Agora survives only as dead v1 telemetry columns
(`agoraVideoId`, `agoraScreenId`) with no SDK present.

### Authentication — this was Unverified #4, and it is solved

**Captured on the wire 2026-08-13** with `tool/probe-sfu.mjs reload`, not inferred.
Both signalling sockets are **Socket.IO v4** (`EIO=4&transport=websocket`, path
`/socket.io/`), and they authenticate in the Socket.IO `CONNECT` packet rather than
in a first application frame:

```jsonc
// client → server, engine "message", socket CONNECT
{ "spaceId": "584d27b3-…", "token": "<a 1037-byte Firebase ID token>" }
// server → client
{ "sid": "_GmgZxNrlDzXVsQOAukF" }
```

Identical on the router socket and on the SFU node socket. **The same Firebase ID
token the game socket uses** — no separate video token, no REST token-fetch, which is
consistent with the 217-endpoint sweep finding nothing media-shaped. Nothing rides in
the URL or in a cookie; the upgrade carries twelve ordinary headers and `Origin:
https://app.v2.gather.town`.

**The correlation key is the Socket.IO ack id.** `sendWithResponse` is not a bespoke
mechanism — it is `socket.emit(name, args, callback)`, so a request goes out as
`42<ackId>["name",{…}]` and the reply comes back as `43<ackId>[{…}]`. A Dart client
gets this for free from any Socket.IO v4 library.

The `{wsSequenceNumber, …}` envelope is real but **not universal**, and the exemption
list in the bundle is accurate. Measured: `get-rtp-capabilities` sent
`{"wsSequenceNumber":1}`, while `get-addr` sent `{"srcId":…,"srcStreamId":…}` with no
sequence number at all.

### `srcId` is the UserAccount id, not the SpaceUser id

The single most expensive thing to get wrong here, and it is not guessable — the two
planes are keyed on different identities:

| Wire field | What it actually holds | Where else it appears |
|---|---|---|
| `srcId` | **`UserAccount.id`** | `UserAccount{id, firebaseAuthId, email}` in the dump |
| `srcStreamId` | the **space id** | the game socket's `?spaceId=` query |

Measured against the same capture: the client asked the router for
`srcId: 88551ba4-…`, which is the `UserAccount` row whose `firebaseAuthId` matches our
own token — while `enterSpace` in the same session addressed
`SpaceUser 752f6182-…`. A client that assumed `srcId == spaceUserId` would ask the
router about a stream that does not exist and get a silent nothing back, which is
Gather's usual failure mode.

`UserAccount.id` is already in the state dump, and `GameProtocolReader` already finds
that row: it is `_myUserAccountId`, the fallback identity route.

### Two sockets, then a pool

| Purpose | URL |
|---|---|
| Router — SFU *assignment* | `wss://router.v2.gather.town/socket.io/?EIO=4&transport=websocket` |
| SFU media node | `<sfuAddr>/socket.io/?sessionId=<uuid>&EIO=4&transport=websocket` |
| SFU health | `https://<sfu-host>/healthCheck` |
| TURN | `cf.turn.gather.town` (Cloudflare) |

The measured exchange, in full:

```jsonc
→ get-addr  #0  {"srcId":"<UserAccount.id>", "srcStreamId":"<spaceId>"}
← addrs         {"srcId":"<UserAccount.id>",
                 "sfuAddr":"wss://sfu-v2.eu-central-1-a.prod.aws.gather.town:443/ip-10-206-193-211",
                 "distance":0.522}
← ACK       #0  [{"addrFound":true}]
```

Three corrections to what the bundle implied. The host prefix is **`sfu-v2.`**, not
`sfu.`; the `ip-…` is a **path segment** naming the node's private address, not a
subdomain; and `sfuAddr` arrives with an explicit `:443`. The region is the
account's, not a constant — this capture is `eu-central-1-a`, while the telemetry
hosts in the bundle read `us-east-1-a`. `addrs` also carries an undocumented
**`distance`** (0.522 here), presumably the assignment score.

The client appends `/socket.io/?sessionId=<uuid>&…` to `sfuAddr`. That `sessionId` is
**not** in the `addrs` reply, so it is generated client-side or held from elsewhere —
unconfirmed, and it matters, because a wrong one may be how the SFU rejects you.

Router vocabulary also includes `unsubscribe`, `reassign`, `debug-router`,
`remote-log`, and a server-pushed `cordon-sfu {sfuAddr}` draining a node.

### Both sockets open at space join, before any call

Worth knowing before designing a lifecycle around it: the capture above involved **no
call at all**. On entering the space the client immediately asked the router for its
own address, connected to the assigned node, and pulled `get-rtp-capabilities`. So
assignment and capability negotiation are startup work, and only produce/consume wait
for somebody to stand next to you. A client that defers opening the SFU socket until a
cluster forms is doing something the real client does not.

**What this app does, and why it is a deviation worth naming.** It opens the media
plane when a *conversation* forms rather than at space join — a phone spends most of
its day in a pocket, and an assignment held all day for a call that never happens is a
socket and a battery spent on nothing. The consequence, which is the part that has to
be got right: opening it on the first **tap** instead, which is what it used to do,
means the phone cannot hear anybody until it starts talking. Walking up to a group and
listening — the ordinary thing to do in an office — was the one thing it could not do.
So the trigger is the cluster, not the microphone button, and nothing about capture or
permissions rides along with it.

### What the router actually offers

The measured `routerRtpCapabilities`, which is what `Device.load()` consumes:

| Kind | Codec | PT | Parameters | Feedback |
|---|---|---|---|---|
| audio | `audio/opus` 48000 ×2 | 100 | `useinbandfec:1`, `usedtx:1` | `nack`, `transport-cc` |
| video | `video/VP8` 90000 | 102 | — | `nack`, `nack/pli`, `ccm/fir`, `goog-remb`, `transport-cc` |

Plus 18 header extensions, including `urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id`
and `…repaired-rtp-stream-id` (simulcast, `recvonly`), `ssrc-audio-level`,
`abs-capture-time`, and mediasoup's own `urn:mediasoup:params:rtp-hdrext:packet-id`.

Two absences that contradict the bundle reading and matter for planning:

- **No H264.** The bundle suggested H264 for screen share; this router advertises
  VP8 only. Either screen share is VP8 too, or H264 is offered by a different router.
- **No RTX.** mediasoup usually offers a retransmission codec alongside video; this
  router does not, so there is no `apt` mapping to reconcile.

### The call protocol, measured

Captured 2026-08-13 across a real two-person call with camera, mic, mute toggles and
screen share. Every payload below is off the wire.

The envelope is exactly what the bundle claimed: `{wsSequenceNumber, zodData}`, with
`get-addr` / `addrs` / `unsubscribe` exempt and sending their arguments bare.

**Client → server**, each returning its answer in the Socket.IO ack:

| Message | `zodData` | Ack returns |
|---|---|---|
| `consume-request` | `{srcId, srcStreamId, requested: bool}` | `[]` |
| `consume` | `{transportId, srcId, srcStreamId, tag, rtpCapabilities}` | `{id, producerId, producerPaused, rtpParameters}` |
| `consume-created` | `{srcId, srcStreamId, tag, consumerId}` | `[]` |
| `consume-pause` / `consume-resume` | `{srcId, srcStreamId, tag, consumerId}` | `[]` |
| `consume-set-spatial` | `{srcId, srcStreamId, tag, spatialLayer}` | `[]` |
| `consume-set-priority` | `{srcStreamId, tag, srcIds[]}` | `{result:[{srcId, priority}]}` |
| `consume-allow` | `{dstId, allowed: bool}` | — |
| `produce` | `{transportId, tag, kind, rtpParameters}` | `{id}` |
| `produce-pause` / `produce-resume` / `produce-close` | `{tag}` | — |
| `set-player-conversation-metadata` | `{meetingId, clusterId}` | `[]` |
| `get-addr` *(router, bare)* | `{srcId, srcStreamId}` | `{addrFound: bool}` |
| `unsubscribe` *(router, bare)* | `{srcId, srcStreamId}` | — |

Note `produce-pause`/`resume`/`close` take **only a tag** — the SFU knows which
producer is yours. And `tag` is not the same axis as `kind`: screen share is
`{tag:'screen', kind:'video'}`.

**Server → client**, unsolicited:

| Message | Payload |
|---|---|
| `consume-try` | `{srcId, srcStreamId, producerIdMap}` — see below |
| `consume-close` | `{srcId, tag, consumerId}` |
| `producer-paused` / `producer-resumed` | `{srcId, tag}` |
| `set-max-spatial-layer` | `{layer, kind}` |
| `server-info` | `{transport:{id, availableBitrate, bitrate}, producers:{a[],v[]}, consumers{}}`, ~every 5s |

### `consume-try` is how you learn a remote producer exists

This was the last real unknown, and the answer is friendlier than expected: the server
pushes the peer's **complete** producer set every time it changes.

```jsonc
{ "srcId": "<their UserAccount.id>", "srcStreamId": "<spaceId>",
  "producerIdMap": { "audio": "97b1fa40-…", "video": "fe165daf-…", "screen": "ea8d04de-…" } }
```

It is a **full-state announcement, not a delta.** Across the capture the same peer's
map went `{audio}` → `{}` → `{audio}` → `{audio,video}` → `{audio,video,screen}` →
`{audio,video}` as they muted, enabled video and shared their screen. An empty map
means they are publishing nothing.

So the correct client design is *reconciliation*, not event-handling: keep a desired
set of `(srcId, tag)` and diff it against `producerIdMap` on every `consume-try`.
That is what the plan already assumed, for once for the right reason.

The full subscribe path, in order:

```
← consume-try {srcId, producerIdMap:{audio:…}}
→ get-addr    {srcId, srcStreamId}            (router — where is their stream?)
← addrs       {srcId, sfuAddr, distance}
→ consume     {transportId, srcId, srcStreamId, tag, rtpCapabilities}
← ack         {id, producerId, producerPaused, rtpParameters}
→ consume-created {srcId, srcStreamId, tag, consumerId}
→ consume-resume  {…, consumerId}
```

`consume-created` going *back* to the server after the ack is unusual and easy to miss:
the SFU wants confirmation that the client actually built the consumer.

### Simulcast: three layers declared, one active

The client declares all three encodings and activates only the lowest:

```jsonc
[{ "rid":"r0", "active":true,  "scaleResolutionDownBy":4, "maxBitrate":120000,  "maxFramerate":18, "scalabilityMode":"L1T2" },
 { "rid":"r1", "active":false, "scaleResolutionDownBy":2, "maxBitrate":350000,  "maxFramerate":24, "scalabilityMode":"L1T2" },
 { "rid":"r2", "active":false, "scaleResolutionDownBy":1, "maxBitrate":1500000, "maxFramerate":24, "scalabilityMode":"L1T2" }]
```

This matters for a phone. The worry about three concurrent software VP8 encodes is
misplaced: **Gather itself encodes one layer at a time** and flips `active` as
consumers ask for more, with the server steering via `set-max-spatial-layer {layer,
kind}`. Declaring three costs nothing; only active ones are encoded.

### The video bubble over someone's head is drawn from the media plane alone

There is **no game-socket field for "my camera is on"**. Checked against all three
captures — 774 records of a real two-person call with a screen share included — and the
only media-ish keys anywhere are `video`, `screen` and `highQualityScreenShare`, all of
them inside SFU frames. No `micOn`, no `cameraOn`, no `isSharingScreen`, nothing on
`SpaceUser`.

So the bubble is not announced, it is *inferred*: every client learns who is publishing
what from `consume-try`'s `producerIdMap` and draws the circle itself. The consequence
for us is a happy one — **publishing video is the whole job.** Colleagues see your face
over your avatar because their clients consume your video producer, with nothing extra
sent on the game socket. The dormant `PlayerRef.micOn` / `.cameraOn` / `.screensharing`
fields can therefore be filled from our own media state, but they are a local convenience
and never something the wire tells us about anybody else.

### `double-connected`, and what a phone can and cannot do about the desktop

The SFU pushes `double-connected` when two connections claim one `srcId` — which is
exactly what a phone and a desktop client signed into one account are, since `srcId` is
the `UserAccount.id`.

Gather's own client answers it with `reload()`, which tears the signalling down, calls
`start()` again and runs `_reconcileProducedTracks` — **it republishes.** That matters:
two clients both doing this would knock each other off in turn, indefinitely.

**Nothing in the protocol drops another client.** There is no "take over" call in the
twelve-plus measured methods; the takeover, if it happens, is the *server's* doing.
So a client's only real choices are to hold what it has or to let go. This app holds —
the phone in your hand is where you are — but stops after the third notice, because a
third means the two ends are swapping the call back and forth rather than settling, and
flapping audio is worse than a sentence explaining which app to quit.

**Still unmeasured** (plan risk #1): whether the SFU replaces the older publisher, rejects
the newer one, or forwards both. That needs two clients and a scratch space.

### The server steers the sending quality: `set-max-spatial-layer`

Server→client `{kind, layer}`, and the client's handler is one line:
`_onProducerSpatialLayer({kind, layer})` → debounced → `producer.setMaxSpatialLayer(layer)`.
mediasoup flips the encodings' `active` flags itself; there is no manual surgery.

This is the other half of "declare three layers, activate one". Without handling it a
client encodes the bottom layer forever, and a colleague watching full-screen never gets
more than a quarter-resolution picture no matter how much bandwidth is going spare.

### TURN rotation: `restart-ice`

Also transcribed rather than guessed:

```js
const {iceParameters, iceServers} = await sendWithResponse('restart-ice',
    {transportId, iceTransportRequestOptions});
if (iceServers.length > 0) await transport.updateIceServers({iceServers});
await transport.restartIce({iceParameters});
```

Guarded by an `isIceRestartPending` flag, and the servers go in *before* the restart.
`TURN_CREDENTIAL_EXPIRY_S = 86400`, `TURN_REFRESH_INTERVAL_S = 14400`.

### Screen share is VP8, not H264

Settled by capture. A real screen share produced
`{tag:'screen', kind:'video', rtpParameters:{codecs:[{mimeType:'video/VP8', payloadType:96}]}}`.
The bundle's H264 mention is either a fallback that never fires or was misread. The
router's advertised capabilities contain no H264 at all, which agrees.

So the codec set is **VP8 for both camera and screen share**, and Opus with
DTX/NACK/FEC for audio. (A paragraph here used to repeat "**H264** screen share"
three lines under the heading correcting it, along with a second copy of the TURN
constants above — both were left behind when the capture settled the question.)

Peers can be spread across **several SFU nodes at once** — `getSFUsByPlayerId`,
`getPrimarySFUByPlayerId`, `moveSFU`, `migratingParticipants`. One media connection is
not a valid model.

### Proximity is computed client-side

There is no server "call started" event. The client keeps `playerMediaMags`
(`playerId → {video, audio, screen, stronglyConnected}`), recomputed on
`position.x`, `position.y`, `clusterId`, `availability`, `cluster.isLocked`,
`speaking`:

```
DIST_THRESHOLD = 12
inRange = a.floorId == b.floorId && a.position.euclideanDistanceSqr(b.position) < 12*12

calculatePerceptionMag(d):        // normal ambient range
  d <= 5 : video = 1 - d/15                      ; audio = 1 - d/10
  else   : video = max((1-5/15)/1.5**(d-5), 0.1) ; audio = max((1-5/10)/1.485**(d-5), 0.1)
```

Twelve pipeline stages run in order, each able to raise or zero the magnitudes:
`connectToNearbyPlayer`, `connectToPlayerInSameTeamArea`,
`connectToNearbyClusterMembers`, `disconnectFromPlayersInDifferingPrivateAreas`,
`connectStronglyToPlayersInSameCluster`,
`disconnectFromPlayersInDifferentLockedCluster`, `disconnectFromHeadphoneUsers`,
`disconnectFromAllAudioIfMuteForPlayback`,
`disconnectFromAmbientAudioIfFocusedCoworking`, `enforceAmbientAudioSetting`,
`disconnectFromRecordingClients`, `disconnectFromUsersNotInOffice`,
`boundMyPlayerAudio`.

**The half that matters most for a custom client:** only
`connectStronglyToPlayersInSameCluster` reads `clusterId`, and that is the "we are in
a bubble together" relation Gather computes server-side and publishes in state. The
*distance* math is for ambient audio from people merely nearby. So a client can join
and leave calls on `clusterId` alone and skip this pipeline entirely; it needs the
arithmetic only for ambient volume. `packages/gather_client` now tracks `clusterId`
and exposes `Roster.myCluster` on exactly that basis.

Subscribe flow: nonzero mags → `subscribe(playerId, tags)` with tags ⊆ `{audio, video,
sound, screen}` → if the SFU is unknown, router `get-addr` → `addrs` → connect or reuse
that node → `consume-request {requested:true}`. Leaving range → debounced
`consume-request {requested:false}` + router `unsubscribe`. `consume-allow {dstId,
allowed}` is the reciprocal grant controlling who may consume *our* streams.

### Feasibility of sending media from a custom client

The protocol is a known quantity and the auth is now mapped, so this is not blocked on
secrecy. Two corrections to what this section used to say:

- **`mediasoup_client_flutter` is abandoned** — last release 2023-06-08, SDK
  `>=2.12.0 <3.0.0`, so it cannot resolve against Dart 3 at all. The maintained
  Dart-3 fork is `mediasfu_mediasoup_client` (0.1.4, 2026-07-12), on
  `flutter_webrtc ^1.5.2`. Pin `flutter_webrtc` to **`^1.6.0`** yourself: 1.6.0 is the
  release that added Swift Package Manager support, and resolving to 1.5.x silently
  drags the project back onto CocoaPods.
- **Gather has shipped their mobile app.** The roadmap line quoted here as "2.0 Mobile
  App (iOS & Android) — In Progress" is out of date: "Gather Meetings" v1.0.43 by
  Gather Presence, Inc. has been on the iOS App Store since 2026-07-06. That cuts both
  ways — the vendor is ahead of where this document assumed, but a shipped first-party
  mobile client also means the mediasoup path is now exercised from phones by Gather
  themselves.

What remains genuinely unpromised is SFU assignment, which is operational machinery
with no compatibility guarantee.

**Not a shortcut:** every chunk ends with a live `sourceMappingURL` pointing at
`sourcemaps.us-east-1-a.prod.aws.gather.town`, which looks like it would make all of
this trivial. That host resolves to RFC1918 addresses (10.202.1.40, 10.202.0.144)
behind an internal ELB and does not answer from outside. Internal-only.

## Negative results

Things that do **not** work, recorded so nobody spends a day rediscovering them.

- **The action vocabulary is not in the client bundle.** Neither `enterSpace` nor
  `loadSpaceUser` appears in `main.6756e69ea136ffbc.js` in any casing, and nor does
  the game socket path `gather-game-v2`. The bundle was verified byte-identical to
  what the running desktop client loads (`document.scripts` confirms the same URL),
  so this is not a version mismatch. The names must be produced some other way. Use
  the probing channel above instead of grepping.
- **CDP input events do not move the avatar.** `Input.dispatchKeyEvent` delivers
  arrow keys as genuinely trusted events (verified with a counter: `window` and
  `document` both fire, `isTrusted: true`), but the canvas receives none —
  `document.activeElement` is `BODY` and the canvas has `tabIndex: -1`. Gather binds
  movement to the canvas, so window-level events never reach the game. Sending
  `teleport`/`move` over the socket is the working route.
- **There is no presence anywhere in REST.** No roster, no positions, no
  game-server-assignment route across all 217 endpoints.
- **Email OTP sign-in does not complete** for an existing account — see above.
- **`SpaceUserMediaStatus` is not mic/camera state.** It is music: `source`, `name`,
  `artist`, `artworkUrl`, `isExplicit`. Mic, camera and screenshare appear in no
  Prisma model and no state row; they are transient AV state. Only `speaking` (voice
  activity) and `dancing` exist on `SpaceUser`.

## Data model

The bundle ships **150 Prisma `*ScalarFieldEnum` objects** — the server's own schema
field lists, leaked wholesale by the shared types package. The models that matter
for presence:

`Connection` (10): `id`, `spaceId`, `authUserId`, `spaceUserId`, `entered`, `target`, `studioUserSessionId`, `clientPlatform`, `isActive`, `lastActiveAt`

`UserAccount` (8): `id`, `firebaseAuthId`, `email`, `hubSpotContactId`, `selectedLanguage`, `isBot`, `createdAt`, `updatedAt`

`Floor` (7): `id`, `spaceId`, `name`, `order`, `previewFilePath`, `createdAt`, `updatedAt`

`Connection` is how you learn which row is *you*: it carries `authUserId` (Firebase
uid) and `spaceUserId` together — and the server creates this row for us on connect,
so `GameProtocolReader` resolves self correctly on a direct connection with no
IndexedDB read at all (observed: "own space user … (via Connection)").
`entered` / `target` / `clientPlatform` are set from the handshake — see
"Observer mode" above.

### `SpaceUser` — 37 in the schema, 41 on the wire

The presence model. `position__x` / `position__y` / `direction__value` /
`speed__modifier` are flattened value objects; on the wire they arrive as ext-0
value objects, and as `replace` patches on `/position/x`.

**Trust the wire over the bundled enum.** The live dump carries four fields the
Prisma enum does not list: **`speaking`**, **`dancing`**, `hasConnectedCalendars`
and `activeMapObjectInteractionId`. `speaking` is live voice activity — which means
game state *does* expose who is talking, even though mic/camera/screenshare state
is absent. **The bridge now consumes `speaking`**, which is what replaced the
deleted mic/camera flags; the other three are still unused.

| Field | Consumed by the bridge |
|---|---|
| `id` | no |
| `name` | **yes** |
| `coreRole` | no |
| `spaceId` | no |
| `floorId` | **yes** |
| `profilePictureId` | **yes** — a `UserFile` id, resolved to a signed URL over REST |
| `followTargetId` | **yes** |
| `userAccountId` | **yes** |
| `clusterId` | no — was Gather's own "standing together" signal; dropped with proximity |
| `deskId` | no — but **the app reads it**: a `MapEntityIdentifier` id, matched against `MapArea.mapEntityIdentifierId` to find the desk. It is what "back to my desk" walks to, and `isAtOwnDesk` is `currentMapArea?.stableId_USE_THIS_INSTEAD_OF_ID === deskId` |
| `shouldBeInClusterWithFollowTarget` | no |
| `connected` | **yes** |
| `isIdle` | **yes** |
| `speaking` | **yes** |
| `activeApp` | no |
| `handRaisedAt` | no |
| `isBot` | no |
| `lastOnlineAt` | no |
| `aiSummary` | no |
| `firstBecameMemberAt` | no |
| `currentTargetMeetingAreaId` | no |
| `shouldBeInClusterWithOthersWithSameTargetMeetingArea` | no |
| `calculatedPrimaryCalendarEmail` | no |
| `deskAssignmentStatus` | no |
| `numTimesEnteredSpace` | no |
| `activeCustomStatusId` | no |
| `activeCalendarInferredId` | no |
| `activeUserGeneratedStatusId` | no |
| `type` | no |
| `githubHandleExperimental` | no |
| `assignedGitHubUserId` | no |
| `createdAt` | no |
| `updatedAt` | no |
| `position__x` | **yes** |
| `position__y` | **yes** |
| `direction__value` | no |
| `speed__modifier` | no — but **the app reads it**: 1, 2 or 3, and the only thing that says somebody is in a go-kart |
| `userSetAvailability__value` | no |

The bridge consumes 8 of 37, plus `Space.name`. Unused fields that look
immediately useful: `handRaisedAt`, `activeApp`, `activeCustomStatusId` /
`activeUserGeneratedStatusId` (custom status), `profilePictureId`, `aiSummary`,
`currentTargetMeetingAreaId`.

### What is *not* in the game state

`SpaceUserMediaStatus` sounds like mic/camera state. It is not — it is **music**:

`SpaceUserMediaStatus` (11): `id`, `spaceId`, `spaceUserId`, `source`, `name`, `artist`, `artworkUrl`, `hyperlink`, `isExplicit`, `createdAt`, `updatedAt`

Mic, camera and screenshare are transient AV state on the SFU/IPC side and appear
in no Prisma model. **The log collector was deleted anyway, on 2026-08-07, and
those three booleans went with it** — see the Verdict below for why that was the
right call and what `speaking` replaced them with. What survives of the log
collector is `bridge/lib/desktop-notifications.js`, which reads Gather's own
notifications and nothing else.

## Incidental finds

- **Push notifications.** `PushDevice` —
  `PushDevice` (10): `id`, `userAccountId`, `provider`, `token`, `platform`, `nativeBuildVersion`, `updateId`, `disabledAt`, `createdAt`, `updatedAt` — plus REST `/users/me/push-devices` and
  `/users/me/push-devices/:pushDeviceId`. Gather has a first-party push registration
  API; the companion currently uses local notifications only.
- **Statsig and Amplitude client keys are in the bundle** (values deliberately not
  reproduced here — see the note below). Feature flags are evaluated client-side, so
  flag names are discoverable from a local bundle if ever needed.
- `exposeManagers` is `false` in prod (module `15683`), which is why no MobX store is
  reachable on `window` and why the bridge reads the socket instead.
- An `ExpAiGrapevineMcp` endpoint (`/exp-ai/grapevine-mcp`) exists — Gather ships an
  MCP surface of its own.
- **Sending chat works over plain REST** — no Action needed, contract read from the
  bundle's zod schema:

  ```
  POST   /api/v2/spaces/:spaceId/chat/channels/:channelId/messages
         {message: string|null, id?: uuid, files?: uuid[], threadParentId?: uuid,
          showThreadReplyInChannel?: boolean, metadata?: {...}}
  DELETE /api/v2/spaces/:spaceId/chat/channels/:channelId/messages/:messageId
  ```

  This is the cheapest genuine *write* feature available to the companion, and the
  only one needing no reverse-engineering.
- **Creating a space** is `POST /api/v2/spaces` with `{name, showAssist?, source?,
  isMFOEnabled?, isSFOEnabled?}` — only `name` is required. There is **no DELETE
  route for a space** in the contract, so a space created by API can only be removed
  through the UI. Worth knowing before scripting scratch spaces.
- `GET /api/v2/users/me` answers `{userAccount:{id, email, firebaseAuthId,
  selectedLanguage, createdAt}, serverRegion}`.

## Verdict

**Shipped 2026-08-07.** The direct connection is now the bridge's only source of
presence; the CDP collector and the broad log parser were deleted.

| | CDP collector (deleted) | Direct connection (shipped) |
|---|---|---|
| Needs `--remote-debugging-port` | yes | **no** |
| Needs the desktop client running | yes | **no** (after a one-time `adopt`) |
| Full state on demand | no — once per connection, hence `resync` | **yes, every connect** |
| Names, positions, follow, cluster | yes | yes |
| Voice activity (`speaking`) | not read | **yes** |
| Mic / cam / screenshare | log parser only | **not available at all** |
| Evicts the user's session | n/a | **no** (observer mode, measured) |
| Shows up as a presence in the space | no | **no** (no `enterSpace`) |

### What could not be replaced

Two things resisted, and the difference between them matters.

**Mic, camera and screenshare are gone.** They were IPC state inside the desktop
client (`AUDIO_UPDATED`, `VIDEO_UPDATED`, `START_SCREEN_SHARE`) and appear in no
Prisma model, no REST route and no delta patch. `SpaceUser.speaking` is the
replacement and is arguably the better signal — it says who is *talking* rather
than who has a mic enabled. Measured over three minutes on a live 111-person
space it was the single most frequent patch of any kind: **13 of 46 deltas**.

The old parser could not really produce them anyway. Gather logs
`setStreamPausedState <id> <track> false` when the client *subscribes* to a
remote track — which happens when somebody comes close, not when they start sending —
and never logs the matching `true`. Across 249 samples in two real logs: 74
`screen false`, 175 `video false`, zero `true`, ever. So the flags could only be
turned off, never on.

**Gather's own notifications are still scraped, deliberately.** A `wave`, a
`meeting invite` and an `event reminder` are decisions the *client* makes and
hands to the OS. They are in no model either — but unlike the media booleans they
are genuinely valuable, being exactly the events worth waking a phone for. So
`bridge/lib/desktop-notifications.js` reads one line shape and nothing else:

```
IPC Event: SHOW_NOTIFICATION { type: 'wave' }
```

It keys off that line rather than the `Showing notification <uuid>: wave` that
normally follows, because Gather **suppresses its own notification when its
window has focus** — and then the second line never appears. The phone is a
different device and should still be told.

### The game socket is a state channel **and** an event bus

This section used to say the opposite, and the correction is the most expensive
mistake recorded in this document — so the wrong reasoning is kept below rather
than deleted.

`DeltaState` carries a **third** array beside `patches` and `actionReturns`:
`events[]`. Measured 2026-08-07 on an **observer** connection (no `enterSpace`),
over five minutes: **41 `WaveEvent`s and 45 `ChatBroadcastNewMessage`es.**

```jsonc
{ "type": "DeltaState", "patches": [], "actionReturns": [], "sequenceNumber": 17059,
  "events": [
    { "payload": { "eventName": "WaveEvent",
                   "senderId":  "<their SpaceUser id>",
                   "sentTime":  "2026-08-07T14:22:20.563Z" },
      "options": { "targetUserIds": ["<my SpaceUser id>"] } }]}
```

Known `eventName`s so far: `WaveEvent`, `ChatBroadcastNewMessage`. The envelope
splits "who did it" (`payload.senderId`) from "who they did it at"
(`options.targetUserIds`), and the payload is otherwise event-specific.

**Why this went unnoticed for weeks.** `collectPatches` read only
`fullStatePatches` and `patches`. A frame carrying nothing but `events[]` has an
*empty* `patches` array, so it fell straight through to `_unknownFrames++` — and
`desktop-notifications.js` was then built to scrape the same waves back out of the
desktop client's log file, where they arrive later, without a sender, and only
when that client happens to be running. The counter in `stats()` had been pointing
at this the whole time.

**The reasoning that was wrong, and why.** Three minutes of deltas on a live
111-person space produced 46 patches across four models — `SpaceUser` (28),
`SpaceUserStatus` (12), `ExternalCalendarConnection` (5), `SpaceUserCluster` (1) —
with no `ActivityEvent`, `Meeting`, `MeetingParticipant` or `ChatMessage`, from
which this document concluded "nothing event-shaped at all". Two flaws:

1. **Nobody waved during those three minutes.** Absence of evidence.
2. **The reader filtered to four models before anyone could look,** so a wave
   could not have been seen even if it had arrived.

The lesson generalises: a negative result from an instrument that discards the
thing you are looking for is not a negative result.

### Two of the three "log-only" notifications are also in state

Beyond the bus, and also contrary to what this document used to claim:

- **Meeting invites.** `MeetingParticipant{spaceUserId, inviterId, inviteStatus}`
  — an `addmodel` where `spaceUserId` is yours and `inviterId` is set *is* the
  invite. Observed values: `inviteStatus` ∈ `InvitedRequired` | `NotInvited`,
  `responseStatus` ∈ `Accepted` | …
- **Event reminders.** 1,771 `BaseCombinedCalendarEvent` rows carry
  `startDateTime`. The client raises reminders from that state; anything holding
  the state can do the same.
- **`MeetingJoinRequest`** — not in the model table below, and event-shaped:
  `{spaceUserId, meetingId, responderId, responseStatus, respondedAt}`. A row
  arriving with no `respondedAt` is "somebody is asking to join and waiting on
  you". Neither the bridge nor the app reads it yet.

Neither invites nor reminders are implemented from state, so
`desktop-notifications.js` still scrapes those two. Waves it no longer touches.

The census also drifts wider than the table below: **49 models** observed
2026-08-07, adding `MeetingJoinRequest`, `GoogleCalendarEvent` and
`SpaceUserCluster`. Reproduce with `node tool/probe-events.mjs`, which prints the
full census, dumps the interaction-shaped models, and then watches every delta
patch and every bus event unfiltered.

Two further caveats carried forward. The `sequenceNumber` on
`FullStateChunk`/`DeltaState` is Gather's, unrelated to the bridge's own `seq`
for the app. And `Connection` has exactly one row — yours — so a second session
of your own is invisible from state.

## Reproducing any of this

`tool/probe-connect.mjs` is the spike harness. It reuses the bridge's own decoder
and protocol reader, so a working run proves the production path too.

```sh
node tool/probe-connect.mjs adopt                      # reuse the desktop session
node tool/probe-connect.mjs whoami                     # prove the token on REST
node tool/probe-connect.mjs spaces                     # space ids + your spaceUserId
node tool/probe-connect.mjs connect --space <uuid> --yes
```

Techniques worth knowing, in rough order of usefulness:

1. **Probe an action to learn its schema.** Send `{type:'Action', txnId, action,
   args:['SpaceUser', id, {}]}` and read `actionReturns`. A wrong name names itself;
   a real one returns its zod issue list. Nothing executes on a schema failure.
2. **Capture the client's own frames.** CDP reports
   `Network.webSocketFrameSent`, not just `…FrameReceived` — the bridge only ever
   read the latter, which is why the handshake went unmapped for so long. Attach at
   the browser endpoint, `Network.enable`, then force a fresh handshake with
   `Page.reload` on the renderer (~2s interruption, same as `resync`).
3. **Watch your own state from a second connection.** An observer connection is
   read-only and does not disturb the client, so it makes a good instrument while
   something else is being tested.
4. **Watch the desktop's socket over CDP** (`webSocketCreated` / `…Closed` plus a
   frame counter) when the question is whether an action disturbed the real client.
   This is what settled the eviction question objectively.

Redact before pasting anywhere: state dumps contain colleague names, emails and
positions, and `Authenticate` frames contain a live JWT.

## Unverified

1. **Why email OTP verify returns 404 for an existing account**, and therefore
   whether a second/bot account can be created at all. Blocks the
   dedicated-companion-account model, which observer mode makes unnecessary anyway.
2. **`clientPlatform` and `connectionTarget` accepted values.** We send `'Desktop'` /
   `'OfficeView'` because that is what the desktop client sends. The only
   platform-ish enum in the bundle is `WebApp | OutlookApp | MobileApp | Unknown`,
   which does **not** contain `'Desktop'`, so that is a different enum and the real
   vocabulary is unconfirmed.
3. **Whether other clients render anything** when a second connection enters, and
   whether the desktop client's mic/camera are disturbed by it. The socket was
   untouched, but AV state was never instrumented.
4. ~~**The SFU signalling socket's authentication.**~~ **Resolved 2026-08-13** — a
   Socket.IO v4 `CONNECT` payload of `{spaceId, token}`, the same Firebase ID token
   the game socket carries. Remote producer discovery is resolved too: the server
   pushes `consume-try` carrying the peer's whole `producerIdMap`. See "Media — the
   SFU". One narrow thing is still open: **where the `sessionId` in the SFU socket's
   URL query comes from.** It is not in the `addrs` reply, and the socket that
   carried it opened before the capture attached, so it is either client-generated
   or held from an earlier exchange. A `probe-sfu.mjs reload` while *in* a call
   would settle it.
5. **Token lifetime in practice.** Refresh works (~60 min ID tokens), but nothing has
   run long enough to see whether a refresh token survives the desktop client
   signing out.
6. **The rest of the action vocabulary.** Twenty names are known now — a capture on
   2026-08-13 of somebody switching every setting in the desktop client resolved
   status, availability, hand-raising, emotes, facing and leaving a cluster. What is
   still unswept: **chat**, **following somebody**, and **desks**. All are
   presumably actions and all are discoverable by the probing channel above.
   Unresolved on the ones that *are* known: whether `broadcastEmote`'s `count`
   accepts anything above 1, and what `clearCondition` types exist besides
   `DateTime`.
7. `unknownFrames` occasionally counts 1–2 server frames the interpreter does not
   recognise. Harmless for presence, unidentified.
8. Delta envelope names were matched structurally, not against a labelled frame.
9. **`transport-create` — request *and* response.** It appears in no capture at all:
   both probes attached at space join, by which time the desktop had already built
   its transports, and the second rig published no media so the produce path never
   ran. Everything on the send and receive sides hangs off it, and the client here
   sends `{direction, iceTransportRequestOptions}` and expects the standard
   mediasoup `{id, iceParameters, iceCandidates, dtlsParameters}` plus Gather's
   `iceServers` — assumed, not measured. `transport-connect` and `restart-ice` were
   transcribed from the bundle rather than seen. A `probe-sfu.mjs reload` *during* a
   live call is still the one measurement that settles all three, and it is the same
   run that would settle the `sessionId` in #4.
10. **What `set-player-conversation-metadata` is for.** The shape is measured
    (`{meetingId, clusterId}`) and the desktop sends it on every cluster change, so
    this client does too — but nothing observable changed when it did, so whether it
    affects routing, recording or only telemetry is unknown.
11. **`disable-video`, `move-off`, `consume-not-allowed` and `consume-connected`.**
    Declared in the bundle's server→client set, never caught on the wire, payloads
    unknown. This client logs them and acts on none of them; guessing at `move-off`
    in particular risks a reconnection loop over a message nobody has seen.
