/**
 * The wire format between the bridge and the phone app.
 *
 * Every event is `{ type, at, source, confidence, ...payload }`:
 *
 *  - `type`       stable discriminator; the app switches on it
 *  - `at`         ISO-8601, taken from the client's own clock, not ours
 *  - `source`     `gather` | `bridge` — where it came from
 *  - `confidence` `observed` | `inferred` — whether we read the thing itself
 *                 or derived it from a proxy signal
 *
 * These names are the contract with `packages/gather_events` on the Dart side.
 * Renaming a field breaks the app.
 *
 * ## Why `source` still admits `log` and `cdp`
 *
 * Both collectors that produced those values are gone — everything now comes from
 * Gather's own game socket. The two strings survive in the *type* only because
 * phones in the wild parse them, and an app build that predates this change must
 * not choke on an event stream it can otherwise read perfectly well.
 */

/** @typedef {'gather'|'bridge'|'log'|'cdp'} EventSource */
/** @typedef {'observed'|'inferred'} Confidence */

/** @param {Date} at @param {EventSource} source @param {Confidence} confidence */
function base(at, source, confidence = 'observed') {
  return { at: at.toISOString(), source, confidence };
}

export function spaceChanged({ at, source = 'gather', spaceId = null, spaceName = null }) {
  return { type: 'space.changed', ...base(at, source), spaceId, spaceName };
}

/**
 * Something about *you* changed.
 *
 * `inOffice` is the only field still carried. Mic, camera and screenshare were
 * read out of the desktop client's IPC log and are in no part of Gather's game
 * state, so they are no longer knowable — see docs/gather-api.md. They stay in
 * the signature as explicit nulls rather than vanishing, because the app's
 * `SelfState` still has the fields and a missing key and a null key are
 * different things to a JSON decoder.
 */
export function selfChanged({ at, source = 'gather', userId = null, inOffice = null }) {
  return {
    type: 'self.changed',
    ...base(at, source),
    userId,
    audioEnabled: null,
    videoEnabled: null,
    inOffice,
    screensharing: null,
  };
}

/** `targetIsSelf: true` is the one that matters: you are being followed. */
export function follow({
  at,
  source = 'gather',
  confidence = 'observed',
  followerId,
  targetId,
  started,
  targetIsSelf,
}) {
  return {
    type: started ? 'follow.started' : 'follow.stopped',
    ...base(at, source, confidence),
    followerId,
    targetId,
    targetIsSelf,
  };
}

/**
 * Gather's own desktop client raised a notification: a wave, a meeting invite, an
 * event reminder.
 *
 * The one thing still read from the client's log rather than from Gather's API,
 * because it exists nowhere else. See `desktop-notifications.js`.
 */
export function notificationShown({
  at,
  source = 'log',
  notificationType,
  title = null,
  body = null,
}) {
  return {
    type: 'notification.shown',
    ...base(at, source),
    notificationType,
    title,
    body,
  };
}

export function bridgeStatus({ at, collector, healthy, detail = null }) {
  return { type: 'bridge.status', ...base(at, 'bridge'), collector, healthy, detail };
}

export function newPlayer(id) {
  return {
    id,
    name: null,
    inSpace: true,
    isFollowingMe: false,
    /** Live voice activity, straight from `SpaceUser.speaking`. */
    speaking: false,
    // Kept null forever. The app still has the fields; nothing can fill them.
    micOn: null,
    cameraOn: null,
    screensharing: false,
    followingMeSince: null,
  };
}

export function emptySelf() {
  return {
    userId: null,
    spaceId: null,
    spaceName: null,
    micOn: null,
    cameraOn: null,
    screensharing: false,
    inOffice: null,
    followingPlayerId: null,
  };
}
