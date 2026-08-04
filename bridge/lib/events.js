/**
 * The wire format between the bridge and the iPhone app.
 *
 * Every event is `{ type, at, source, confidence, ...payload }`:
 *
 *  - `type`       stable discriminator; the app switches on it
 *  - `at`         ISO-8601, taken from the client's own clock, not ours
 *  - `source`     `log` | `cdp` | `bridge` — which collector saw it
 *  - `confidence` `observed` | `inferred` — whether we read the thing itself
 *                 or derived it from a proxy signal
 *
 * These names are the contract with `packages/gather_events` on the Dart side.
 * Renaming a field breaks the app.
 */

/** @typedef {'log'|'cdp'|'bridge'} EventSource */
/** @typedef {'observed'|'inferred'} Confidence */
/** @typedef {'audio'|'video'|'screen'} MediaTrack */

/** @param {Date} at @param {EventSource} source @param {Confidence} confidence */
function base(at, source, confidence = 'observed') {
  return { at: at.toISOString(), source, confidence };
}

export function spaceChanged({ at, source = 'log', spaceId = null, spaceName = null }) {
  return { type: 'space.changed', ...base(at, source), spaceId, spaceName };
}

export function selfChanged({
  at,
  source = 'log',
  userId = null,
  audioEnabled = null,
  videoEnabled = null,
  inOffice = null,
  screensharing = null,
}) {
  return {
    type: 'self.changed',
    ...base(at, source),
    userId,
    audioEnabled,
    videoEnabled,
    inOffice,
    screensharing,
  };
}

export function playerSpace({ at, source = 'log', playerId, joined }) {
  return {
    type: joined ? 'player.joinedSpace' : 'player.leftSpace',
    ...base(at, source),
    playerId,
  };
}

/**
 * Someone came into, or dropped out of, your immediate surroundings.
 * This is the "standing next to me" signal.
 */
export function proximity({
  at,
  source = 'log',
  confidence = 'inferred',
  playerId,
  near,
  distance = null,
}) {
  return {
    type: near ? 'proximity.entered' : 'proximity.left',
    ...base(at, source, confidence),
    playerId,
    distance,
  };
}

export function audioRange({ at, source = 'log', playerId, inRange, volume = null }) {
  return { type: 'audio.range', ...base(at, source), playerId, inRange, volume };
}

export function mediaChanged({ at, source = 'log', playerId, track, paused }) {
  return { type: 'media.changed', ...base(at, source), playerId, track, paused };
}

export function mediaConnection({ at, source = 'log', playerId, state }) {
  return { type: 'media.connection', ...base(at, source), playerId, state };
}

/** `targetIsSelf: true` is the one that matters: you are being followed. */
export function follow({
  at,
  source = 'cdp',
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

export function playerMoved({ at, source = 'cdp', playerId, x, y, distance = null }) {
  return { type: 'player.moved', ...base(at, source), playerId, x, y, distance };
}

export function chatMessage({ at, source = 'cdp', playerId, text, channel = null }) {
  return { type: 'chat.message', ...base(at, source), playerId, text, channel };
}

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

/** Anything interesting we don't model yet — keeps the pipeline lossless. */
export function raw({ at, source = 'log', type, text }) {
  return { type, ...base(at, source), text };
}

/** The other player an event is about, when there is one. */
export function playerIdOf(event) {
  if (event.type === 'follow.started' || event.type === 'follow.stopped') {
    return event.targetIsSelf ? event.followerId : event.targetId;
  }
  return typeof event.playerId === 'string' ? event.playerId : null;
}

export function newPlayer(id) {
  return {
    id,
    name: null,
    inSpace: true,
    isNear: false,
    inAudioRange: false,
    isFollowingMe: false,
    micOn: null,
    cameraOn: null,
    screensharing: false,
    distance: null,
    x: null,
    y: null,
    nearSince: null,
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
