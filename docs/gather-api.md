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
  - [The server does not validate walkability](#the-server-does-not-validate-walkability)
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
2. **`Subscribe` takes no arguments at all.** The earlier reading of this document
   was wrong: you cannot narrow the stream by model key from the client.
   `ModelSubscription` (`{connectionId, modelIds, modelKey, subscriptionType, …}`)
   is server-side bookkeeping, not a client-supplied filter. You get everything
   and filter locally, exactly as `bridge/lib/game-protocol.js:47` already does.
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
| `move` | `['SpaceUser', id, {direction:'Up'\|'Down'\|'Left'\|'Right'}]` | **one tile per call** |
| `teleport` | `['SpaceUser', id, {x, y, direction}]` | flat `x`/`y`; `floorId` optional |

Probed and confirmed **not** to exist on `SpaceUser`: `moveTo`, `setPosition`,
`updatePosition`, `walkTo`, `setDestination`, `goTo`. `teleport` rejects
`{position:{x,y}}` — the coordinates must be flat, and `direction` is required even
when teleporting.

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
- **Read-only is a choice, not a property.** `DirectCollector` sends exactly one
  kind of write (`teleport`, for party mode) and nothing else, because the
  gateway would let it send anything.

`bridge/lib/party.js` is the consumer, and the reason the walkability finding
below is load-bearing rather than trivia.

### The server does not validate walkability

Eight teleports to uniformly random tiles across the full 124×82 grid were **all
accepted**, including tiles at the map edges that are certainly wall or void. No
rejection, no clamping, no collision check. **Collision is enforced client-side
only.** Worth knowing both as a capability and as a measure of how much the game
server trusts its clients.

Map bounds come from the base `MapArea`: `FloorMap.baseAreaId` names it, and its
`dimensionsInTiles` is an ext-0 `{$type:'Dimensions', width, height}` — 124×82 for
the space measured here.

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

## Media — the SFU

Separate from the game socket, and **standard mediasoup**, not a bespoke protocol.
`wss://router.v2.gather.town` (bundle module `15683`, under the key `routerURLs`).
The client bundles mediasoup-client and signals with `sendWithResponse(method, args)`:

| Method | Payload |
|---|---|
| `get-rtp-capabilities` | → `{routerRtpCapabilities}` |
| `produce` | `{transportId, tag, kind, rtpParameters, highQualityScreenShare}` |
| `consume` | `{transportId, srcId, srcStreamId, tag, rtpCapabilities, spatialLayer}` |
| `pause` / `resume` / `Reconnect` / `RefreshTURNCredentials` | — |

Codecs: **VP8** for camera, **H264** for screen share, Opus with DTX/NACK/FEC for
audio. Three simulcast layers toggled via `scaleResolutionDownBy` and per-layer
`active` flags. TURN credentials are refreshed on a timer, and SFU assignment is
dynamic — `sfuAddr`, `retainSFUAssignment`, and cordoning via `onCordonSFU`.

**Feasibility of sending media from a custom client:** the protocol is a known
quantity and Dart has `flutter_webrtc` + `mediasoup_client_flutter`, so it is not
blocked on protocol secrecy. What stands in the way is that the signalling socket's
auth is unmapped, SFU assignment is operational machinery with no compatibility
promise, and Gather's own roadmap lists **"2.0 Mobile App (iOS & Android) — In
Progress"** with "join meetings and use Gather chat on the go". Building this means
racing the vendor on the churniest part of their stack.

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
| `profilePictureId` | no |
| `followTargetId` | **yes** |
| `userAccountId` | **yes** |
| `clusterId` | **yes** |
| `deskId` | no |
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
| `speed__modifier` | no |
| `userSetAvailability__value` | no |

The bridge consumes 9 of 37, plus `Space.name`. Unused fields that look
immediately useful: `deskId`
(which desk someone is at), `handRaisedAt`, `activeApp`, `activeCustomStatusId` /
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
remote track — which happens on proximity, not when the person starts sending —
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

### The game socket is a state channel, not an event bus

Worth recording, because it is what closes off any hope of getting the
notifications from the protocol. Three minutes of deltas on a live 111-person
space produced **46 patches across four models**:

| Model | Patches |
|---|---|
| `SpaceUser` | 28 (13 `/speaking`, 5 `/updatedAt`, 2 `/position`, 2 `/clusterId`, 2 `/connected`, 2 `/lastOnlineAt`, 1 `/direction`, 1 `/activeApp`) |
| `SpaceUserStatus` | 12 |
| `ExternalCalendarConnection` | 5 |
| `SpaceUserCluster` | 1 |

No `ActivityEvent`, no `Meeting`, no `MeetingParticipant`, no `ChatMessage`.
Nothing event-shaped at all. The socket reports what *is*, not what *happened*.

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
4. **The SFU signalling socket's authentication.** Mapped for the game socket only.
5. **Token lifetime in practice.** Refresh works (~60 min ID tokens), but nothing has
   run long enough to see whether a refresh token survives the desktop client
   signing out.
6. **The rest of the action vocabulary.** Six names are known; status, chat, follow,
   desks and hand-raising are all presumably actions too, and all discoverable by
   probing. Nobody has swept it.
7. `unknownFrames` occasionally counts 1–2 server frames the interpreter does not
   recognise. Harmless for presence, unidentified.
8. Delta envelope names were matched structurally, not against a labelled frame.
