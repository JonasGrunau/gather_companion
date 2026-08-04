/**
 * Folds the event stream into "what does the world look like right now", and
 * suppresses the duplicates the client emits.
 *
 * There are two fidelities of input, and the tracker accepts both:
 *
 *  - **Log events** (always available). Proximity is *inferred* from Gather's
 *    proximity-gated media connections; there are no names and no coordinates.
 *  - **CDP roster rows** (when the collector is attached). These are the web
 *    app's own `SpaceUser` records, so proximity and following are *observed*:
 *    `clusterId` says who you are grouped with and `followTargetId` says who is
 *    following whom, by name.
 */

import { bridgeStatus, emptySelf, follow, newPlayer, proximity } from './events.js';

/** How close, in tiles, counts as "standing next to me" when we have coordinates. */
export const ADJACENT_TILES = 3;

/**
 * Someone already counted as near stays near until they pass this. The gap
 * between the two is deliberate: positions arrive debounced, so a single
 * threshold makes anyone loitering at exactly the boundary flap between
 * "arrived" and "left" indefinitely — and every flap is a notification.
 */
export const LEAVE_TILES = 4.5;

export class PresenceTracker {
  constructor({ followDetector = null } = {}) {
    this.followDetector = followDetector;
    /** @type {Map<string, object>} */
    this._players = new Map();
    this._self = emptySelf();
    this._health = { logTail: false, cdp: false, detail: null };
    this._selfPosition = null;
    /** My own SpaceUser id and cluster, learned from the CDP roster. */
    this._selfId = null;
    this._selfClusterId = null;
    this._selfFloorId = null;
  }

  get self() {
    return this._self;
  }

  get health() {
    return this._health;
  }

  get players() {
    return [...this._players.values()];
  }

  snapshot() {
    return {
      type: 'presence.snapshot',
      at: new Date().toISOString(),
      self: this._self,
      players: this.players,
      health: this._health,
    };
  }

  setHealth(patch) {
    this._health = { ...this._health, ...patch };
  }

  _player(id) {
    let p = this._players.get(id);
    if (!p) {
      p = newPlayer(id);
      this._players.set(id, p);
    }
    return p;
  }

  /**
   * Apply one event. Returns `{ emit, stateChanged }` where `emit` holds only
   * the events worth showing a human — the client double-reports plenty (a
   * proximity change arrives once from the media handler and again from the
   * volume line), and the app should not show that twice.
   */
  apply(event) {
    const none = { emit: [], stateChanged: false };

    switch (event.type) {
      case 'proximity.entered':
      case 'proximity.left': {
        const near = event.type === 'proximity.entered';
        const p = this._player(event.playerId);
        if (p.isNear === near) {
          if (event.distance != null) {
            p.distance = event.distance;
            return { emit: [], stateChanged: true };
          }
          return none;
        }
        p.isNear = near;
        p.distance = event.distance ?? p.distance;
        p.nearSince = near ? event.at : null;
        return { emit: [event], stateChanged: true };
      }

      case 'audio.range': {
        const p = this._player(event.playerId);
        if (p.inAudioRange === event.inRange) return none;
        const hadProximity = p.isNear;
        p.inAudioRange = event.inRange;
        // Audio range is a weaker signal than the media handler; only surface it
        // when we have no proximity information for this player at all.
        return { emit: hadProximity ? [] : [event], stateChanged: true };
      }

      case 'player.joinedSpace': {
        const existing = this._players.get(event.playerId);
        if (existing?.inSpace === true) return none;
        const p = this._player(event.playerId);
        p.inSpace = true;
        return { emit: [event], stateChanged: true };
      }

      case 'player.leftSpace': {
        const p = this._players.get(event.playerId);
        if (!p) return none;
        p.inSpace = false;
        p.isNear = false;
        p.inAudioRange = false;
        p.isFollowingMe = false;
        p.nearSince = null;
        p.followingMeSince = null;
        this.followDetector?.forget(event.playerId);
        return { emit: [event], stateChanged: true };
      }

      case 'media.changed': {
        const p = this._player(event.playerId);
        const value = !event.paused;
        const key =
          event.track === 'audio' ? 'micOn' : event.track === 'video' ? 'cameraOn' : 'screensharing';
        if (p[key] === value) return none;
        p[key] = value;
        // Only screen sharing is worth a line in the feed; mic and camera
        // flicker constantly as people talk.
        return {
          emit: event.track === 'screen' ? [event] : [],
          stateChanged: true,
        };
      }

      case 'media.connection':
        // Transport noise. Recorded so the player is known to exist, never shown.
        this._player(event.playerId);
        return none;

      case 'player.moved': {
        const p = this._player(event.playerId);
        p.x = event.x;
        p.y = event.y;
        if (event.distance != null) p.distance = event.distance;
        const out = [];
        const verdict = this.followDetector?.observe({
          playerId: event.playerId,
          x: event.x,
          y: event.y,
          selfPosition: this._selfPosition,
          at: new Date(event.at),
        });
        if (verdict) out.push(...this._applyFollow(verdict));
        return { emit: out, stateChanged: true };
      }

      case 'follow.started':
      case 'follow.stopped':
        return { emit: this._applyFollow(event), stateChanged: true };

      case 'self.changed': {
        const before = { ...this._self };
        if (event.userId != null) this._self.userId = event.userId;
        if (event.audioEnabled != null) this._self.micOn = event.audioEnabled;
        if (event.videoEnabled != null) this._self.cameraOn = event.videoEnabled;
        if (event.inOffice != null) this._self.inOffice = event.inOffice;
        if (event.screensharing != null) this._self.screensharing = event.screensharing;
        const changed =
          before.userId !== this._self.userId ||
          before.micOn !== this._self.micOn ||
          before.cameraOn !== this._self.cameraOn ||
          before.inOffice !== this._self.inOffice ||
          before.screensharing !== this._self.screensharing;
        if (!changed) return none;
        // Leaving the office invalidates everything we knew about who was around.
        if (event.inOffice === false) this._clearRoom();
        return { emit: [event], stateChanged: true };
      }

      case 'space.changed': {
        const changed = event.spaceId != null && event.spaceId !== this._self.spaceId;
        if (event.spaceId != null) this._self.spaceId = event.spaceId;
        if (event.spaceName != null) this._self.spaceName = event.spaceName;
        if (changed) this._clearRoom();
        return { emit: [event], stateChanged: true };
      }

      case 'bridge.status':
        this.setHealth({
          [event.collector]: event.healthy,
          detail: event.detail ?? this._health.detail,
        });
        return { emit: [event], stateChanged: true };

      default:
        // chat.message, notification.shown, app.badge, raw — pass through.
        return { emit: [event], stateChanged: false };
    }
  }

  _applyFollow(event) {
    if (!event.targetIsSelf) {
      this._self.followingPlayerId = event.started ? event.targetId : null;
      return [event];
    }
    const p = this._player(event.followerId);
    if (p.isFollowingMe === event.started) return [];
    p.isFollowingMe = event.started;
    p.followingMeSince = event.started ? event.at : null;
    return [event];
  }

  _clearRoom() {
    this._players.clear();
    this.followDetector?.reset();
    this._selfClusterId = null;
  }

  /**
   * Replace what we know from the live web app's own `SpaceUser` records.
   *
   * `rows` are the decoded model rows the CDP collector scraped out of the
   * renderer. This is the authoritative path: proximity comes from `clusterId`
   * (Gather groups people who are standing together into a cluster) and
   * following from `followTargetId`, so both become `observed` rather than
   * inferred.
   *
   * @param {{ selfId: string|null, rows: Array<object> }} roster
   * @returns {{ emit: object[], stateChanged: boolean }}
   */
  applyRoster({ selfId, rows }) {
    const emit = [];
    let stateChanged = false;
    const at = new Date();

    if (selfId) this._selfId = selfId;
    const me = rows.find((r) => r.id === this._selfId) ?? null;
    if (me) {
      this._selfClusterId = me.clusterId ?? null;
      this._selfFloorId = me.floorId ?? null;
      if (me.x != null && me.y != null) {
        this._selfPosition = [me.x, me.y];
        this.followDetector?.observeSelf({ x: me.x, y: me.y, at });
      }
      if (me.followTargetId !== undefined) {
        const wanted = me.followTargetId ?? null;
        if (wanted !== this._self.followingPlayerId) {
          this._self.followingPlayerId = wanted;
          stateChanged = true;
        }
      }
    }

    // Without knowing which row is *me*, "next to me" and "following me" are
    // both undefined. Merge the identity information the roster does give us —
    // names and coordinates are still worth having — and leave proximity to the
    // log collector, which needs no self identity.
    const knowSelf = this._selfId != null;

    const seen = new Set();

    for (const row of rows) {
      if (!row?.id || row.id === this._selfId) continue;
      seen.add(row.id);
      const p = this._player(row.id);

      if (row.name && row.name !== p.name) {
        p.name = row.name;
        stateChanged = true;
      }
      if (row.x != null) p.x = row.x;
      if (row.y != null) p.y = row.y;

      const distance =
        this._selfPosition && row.x != null && row.y != null
          ? Math.hypot(row.x - this._selfPosition[0], row.y - this._selfPosition[1])
          : null;
      if (distance != null) p.distance = distance;

      // Gather's own proximity predicate requires the same floor before any
      // distance comparison — two people on the same tile of different floors are
      // not near each other. Treat unknown floors as "no objection".
      const sameFloor =
        this._selfFloorId == null || row.floorId == null || row.floorId === this._selfFloorId;

      // Adjacency: sharing a cluster is Gather's own notion of "we are standing
      // together". Distance decides when clusters are unavailable, with a wider
      // radius for leaving than for arriving.
      const sameCluster =
        this._selfClusterId != null && row.clusterId != null && row.clusterId === this._selfClusterId;
      const closeEnough =
        distance != null && distance <= (p.isNear ? LEAVE_TILES : ADJACENT_TILES);
      const near = sameFloor && (sameCluster || closeEnough);

      // With neither a position nor a cluster there is nothing to judge on. Say
      // nothing rather than reporting everyone as having walked off — the log
      // collector may well know they are near.
      const canJudge = sameCluster || distance != null;

      if (knowSelf && canJudge && near !== p.isNear) {
        p.isNear = near;
        p.nearSince = near ? at.toISOString() : null;
        stateChanged = true;
        emit.push(
          proximity({
            at,
            source: 'cdp',
            confidence: sameCluster ? 'observed' : 'inferred',
            playerId: row.id,
            near,
            distance,
          }),
        );
      }

      // Following: their followTargetId pointing at me is the real thing, no
      // heuristics needed.
      if (knowSelf && row.followTargetId !== undefined) {
        const followsMe = row.followTargetId === this._selfId;
        if (followsMe !== p.isFollowingMe) {
          p.isFollowingMe = followsMe;
          p.followingMeSince = followsMe ? at.toISOString() : null;
          stateChanged = true;
          emit.push(
            follow({
              at,
              source: 'cdp',
              confidence: 'observed',
              followerId: row.id,
              targetId: this._selfId ?? 'self',
              started: followsMe,
              targetIsSelf: true,
            }),
          );
        }
      }

      if (row.connected != null && p.inSpace !== row.connected) {
        p.inSpace = row.connected;
        stateChanged = true;
      }
    }

    // Anyone previously in the roster but absent now has left.
    for (const [id, p] of this._players) {
      if (!knowSelf) break;
      if (seen.has(id) || !p.inSpace) continue;
      if (rows.length === 0) break; // an empty scrape means "unknown", not "empty"
      p.inSpace = false;
      if (p.isNear) {
        p.isNear = false;
        p.nearSince = null;
        emit.push(proximity({ at, source: 'cdp', playerId: id, near: false }));
      }
      if (p.isFollowingMe) {
        p.isFollowingMe = false;
        p.followingMeSince = null;
        emit.push(
          follow({
            at,
            source: 'cdp',
            followerId: id,
            targetId: this._selfId ?? 'self',
            started: false,
            targetIsSelf: true,
          }),
        );
      }
      stateChanged = true;
    }

    return { emit, stateChanged };
  }

  statusEvent(collector, healthy, detail) {
    this.setHealth({ [collector]: healthy, detail: detail ?? null });
    return bridgeStatus({ at: new Date(), collector, healthy, detail });
  }
}

/**
 * Infers "this person is following me" from movement alone.
 *
 * Only used when the roster does not give us `followTargetId` — the log-only
 * path has no such field. The idea: a follower repeatedly closes the gap after
 * *I* move. Someone who merely happens to stand near me never re-converges,
 * because they never move at all.
 */
export class FollowDetector {
  constructor({ windowMs = 25_000, minConvergences = 3, reactionMs = 4000 } = {}) {
    this.windowMs = windowMs;
    this.minConvergences = minConvergences;
    this.reactionMs = reactionMs;
    /** @type {Array<{x:number,y:number,t:number}>} */
    this._mine = [];
    /** @type {Map<string, Array<{x:number,y:number,t:number}>>} */
    this._theirs = new Map();
    /** @type {Map<string, boolean>} */
    this._verdict = new Map();
  }

  reset() {
    this._mine = [];
    this._theirs.clear();
    this._verdict.clear();
  }

  forget(playerId) {
    this._theirs.delete(playerId);
    this._verdict.delete(playerId);
  }

  observeSelf({ x, y, at }) {
    this._mine.push({ x, y, t: at.getTime() });
    this._prune(this._mine, at.getTime());
  }

  /** Returns a follow event only when the verdict flips, so callers see edges. */
  observe({ playerId, x, y, selfPosition, at }) {
    if (!selfPosition) return null;
    const t = at.getTime();
    let samples = this._theirs.get(playerId);
    if (!samples) {
      samples = [];
      this._theirs.set(playerId, samples);
    }
    samples.push({ x, y, t });
    this._prune(samples, t);

    const following = this._looksLikeFollowing(samples);
    if (this._verdict.get(playerId) === following) return null;
    this._verdict.set(playerId, following);

    return follow({
      at,
      source: 'cdp',
      confidence: 'inferred',
      followerId: playerId,
      targetId: 'self',
      started: following,
      targetIsSelf: true,
    });
  }

  _looksLikeFollowing(samples) {
    if (this._mine.length < 2 || samples.length < 2) return false;
    let convergences = 0;
    for (let i = 1; i < this._mine.length; i++) {
      const myMove = this._mine[i];
      if (dist(this._mine[i - 1], myMove) < 1) continue; // I barely moved

      const before = latestBefore(samples, myMove.t);
      const after = firstAfter(samples, myMove.t, this.reactionMs);
      if (!before || !after) continue;

      const gapBefore = dist(before, myMove);
      const gapAfter = dist(after, myMove);
      if (gapAfter <= ADJACENT_TILES && gapAfter < gapBefore) convergences++;
    }
    return convergences >= this.minConvergences;
  }

  _prune(samples, now) {
    const cutoff = now - this.windowMs;
    while (samples.length && samples[0].t < cutoff) samples.shift();
  }
}

function dist(a, b) {
  return Math.hypot(a.x - b.x, a.y - b.y);
}

function latestBefore(samples, t) {
  let found = null;
  for (const s of samples) {
    if (s.t > t) break;
    found = s;
  }
  return found;
}

function firstAfter(samples, t, within) {
  for (const s of samples) {
    if (s.t > t && s.t <= t + within) return s;
  }
  return null;
}
