/**
 * Folds the roster into "what does the world look like right now".
 *
 * There used to be two fidelities of input here: inferred log events and observed
 * `SpaceUser` rows. Only the second remains. Everything now arrives as Gather's
 * own model rows from `DirectCollector`, so proximity comes from `clusterId`
 * (Gather's own notion of "standing together") and following from
 * `followTargetId`, and both are *observed* rather than guessed.
 *
 * What that removed, and why it is not missed:
 *
 *  - The movement-based follow detector. It existed because the log had no
 *    `followTargetId` to read. With the real field always present, guessing from
 *    convergence is strictly worse — and it had already stopped being reachable.
 *  - Per-player mic/camera/screenshare. Those came from the client's log and are
 *    in no Gather model at all. `speaking` — live voice activity — is in the game
 *    state and is the better signal anyway: it says who is *talking*, not who
 *    happens to have a mic enabled.
 *
 * One log-derived event still passes through `apply`: `notification.shown`, for
 * the waves and meeting invites Gather's own client raises. It needs no folding —
 * it is news, not state — so it falls through to the default branch.
 */

import { bridgeStatus, emptySelf, follow, newPlayer, playerMoved, proximity } from './events.js';

/** How close, in tiles, counts as "standing next to me". */
export const ADJACENT_TILES = 3;

/**
 * Someone already counted as near stays near until they pass this. The gap
 * between the two is deliberate: positions arrive debounced, so a single
 * threshold makes anyone loitering at exactly the boundary flap between
 * "arrived" and "left" indefinitely — and every flap is a notification.
 */
export const LEAVE_TILES = 4.5;

export class PresenceTracker {
  constructor() {
    /** @type {Map<string, object>} */
    this._players = new Map();
    this._self = emptySelf();
    this._health = { gather: false, cdp: false, logTail: false, detail: null };
    /**
     * Party mode, mirrored here so it rides along on the snapshot the phone
     * already receives. It is the one piece of state the app can *change* rather
     * than only observe, which makes reporting it back the difference between a
     * button that knows what it did and one that only hopes.
     */
    this._party = { active: false, hops: 0, safeTiles: 0, detail: null };
    this._selfPosition = null;
    /** My own SpaceUser id and cluster, learned from the roster. */
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

  get party() {
    return this._party;
  }

  snapshot() {
    return {
      type: 'presence.snapshot',
      at: new Date().toISOString(),
      self: this._self,
      players: this.players,
      health: this._health,
      party: this._party,
    };
  }

  setHealth(patch) {
    this._health = { ...this._health, ...patch };
  }

  setParty(state) {
    this._party = { ...this._party, ...state };
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
   * Apply one event the collector produced directly, rather than via the roster.
   *
   * That is now a short list — status and the space the bridge was told to watch.
   * Everything about *people* comes through `applyRoster`.
   *
   * Returns `{ emit, stateChanged }` where `emit` holds only the events worth
   * showing a human.
   */
  apply(event) {
    switch (event.type) {
      case 'self.changed': {
        const before = { ...this._self };
        if (event.userId != null) this._self.userId = event.userId;
        if (event.inOffice != null) this._self.inOffice = event.inOffice;
        const changed =
          before.userId !== this._self.userId || before.inOffice !== this._self.inOffice;
        if (!changed) return { emit: [], stateChanged: false };
        return { emit: [event], stateChanged: true };
      }

      case 'space.changed': {
        const changed = event.spaceId != null && event.spaceId !== this._self.spaceId;
        if (event.spaceId != null) this._self.spaceId = event.spaceId;
        if (event.spaceName != null) this._self.spaceName = event.spaceName;
        if (changed) this._clearRoom();
        return { emit: [event], stateChanged: true };
      }

      case 'bridge.status': {
        const patch = {
          [event.collector]: event.healthy,
          detail: event.detail ?? this._health.detail,
        };
        // `cdp` is a compatibility alias, not a second collector. App builds
        // already on people's phones compute `hasRichData` from
        // `CollectorHealth.cdp`, so publishing only the honest name would make
        // them show the "log-only mode: no names" banner while we hold the full
        // roster. Newer builds read `gather` and ignore this.
        if (event.collector === 'gather') patch.cdp = event.healthy;
        this.setHealth(patch);
        return { emit: [event], stateChanged: true };
      }

      default:
        return { emit: [event], stateChanged: false };
    }
  }

  _clearRoom() {
    this._players.clear();
    this._selfClusterId = null;
  }

  /**
   * Replace what we know from Gather's own `SpaceUser` records.
   *
   * @param {{ selfId: string|null, rows: Array<object>, spaceName?: string|null }} roster
   * @returns {{ emit: object[], stateChanged: boolean }}
   */
  applyRoster({ selfId, rows, spaceName = null }) {
    const emit = [];
    let stateChanged = false;
    const at = new Date();

    if (spaceName && spaceName !== this._self.spaceName) {
      this._self.spaceName = spaceName;
      stateChanged = true;
    }

    if (selfId) this._selfId = selfId;
    const me = rows.find((r) => r.id === this._selfId) ?? null;

    // Whether *you* are in the space at all. Our own connection is an observer —
    // it never calls `enterSpace` — so this reflects your real clients, not us.
    //
    // It matters because your avatar does not disappear when you close Gather: it
    // stays parked wherever you left it, usually at your desk. Judging proximity
    // against a parked avatar reports every passer-by as standing next to you, all
    // night. So when you are offline, nobody is near you, by definition.
    const selfOnline = me?.connected !== false;
    if (me && this._self.inOffice !== selfOnline) {
      this._self.inOffice = selfOnline;
      stateChanged = true;
    }

    if (me) {
      this._selfClusterId = me.clusterId ?? null;
      this._selfFloorId = me.floorId ?? null;
      if (me.x != null && me.y != null) this._selfPosition = [me.x, me.y];
      if (me.followTargetId !== undefined) {
        const wanted = me.followTargetId ?? null;
        if (wanted !== this._self.followingPlayerId) {
          this._self.followingPlayerId = wanted;
          stateChanged = true;
        }
      }
    }

    // Without knowing which row is *me*, "next to me" and "following me" are both
    // undefined. Merge the identity information the roster does give us — names
    // and coordinates are still worth having — and judge nothing.
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
      if (row.speaking != null && row.speaking !== p.speaking) {
        // State only, never an event: voice activity toggles every few seconds
        // while someone talks, and a feed of that is unreadable.
        //
        // It is also only a *state change* for somebody the app draws. The app
        // shows the talking indicator on the people standing next to you and the
        // ones following you, and on nobody else — but the measured space holds 79
        // rows, so counting every one of them made a stranger three rooms away
        // clearing their throat publish a 23 KiB roster to every phone. That was
        // the bulk of an observed 0.86 snapshots/second, ~1.1 MB/minute, which is
        // what made the link feel fragile: the phone spent its time decoding
        // rosters and rebuilding its whole widget tree. Whoever is invisible keeps
        // the new value on the player record, so it is already correct in the
        // snapshot that goes out when they *do* walk up.
        const visible = p.isNear || p.isFollowingMe;
        p.speaking = row.speaking;
        if (visible) stateChanged = true;
      }
      // Whether they actually changed tiles, decided before the row overwrites
      // what we held. A first sighting is not a move — on the initial state dump
      // every player would otherwise "move" from nowhere to where they stand.
      const hadPosition = p.x != null && p.y != null;
      const moved =
        hadPosition && ((row.x != null && row.x !== p.x) || (row.y != null && row.y !== p.y));

      if (row.x != null) p.x = row.x;
      if (row.y != null) p.y = row.y;

      const distance =
        this._selfPosition && row.x != null && row.y != null
          ? Math.hypot(row.x - this._selfPosition[0], row.y - this._selfPosition[1])
          : null;
      // Rounded for the wire only. The full-precision `distance` is what the
      // near/far thresholds below compare against, so this cannot move anyone
      // across a boundary — it just stops `19.4164878389476` costing 19 bytes per
      // player per snapshot to say "about 19 tiles away".
      if (distance != null) p.distance = Math.round(distance * 10) / 10;

      // A row that is not connected is a stale avatar left wherever that person
      // logged off — which, for most people, is their desk. It keeps its name and
      // its coordinates, so on distance alone it is indistinguishable from
      // somebody standing next to you, and walking past an empty desk reports its
      // owner as having walked up. The full state dump carries every member of
      // the space, not just the ones online: 111 rows in the measured space, most
      // of them offline and still holding coordinates. Only the connected ones can
      // be standing anywhere. `null` stays judgeable — unknown is not absent.
      const online = row.connected !== false;

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
      const near = selfOnline && online && sameFloor && (sameCluster || closeEnough);

      // With neither a position nor a cluster there is nothing to judge on. Say
      // nothing rather than reporting everyone as having walked off. Going offline
      // is always judgeable: whatever we thought before, they are not standing
      // there now. So is our own absence.
      const canJudge = !selfOnline || !online || sameCluster || distance != null;

      // Someone next to you shifting around is worth saying out loud; the other
      // hundred rows changing tiles four times a second is not, and the snapshot
      // already carries every position for anyone who wants the map. So this is
      // deliberately scoped to the people the app is actually watching.
      if (moved && online && p.isNear) {
        emit.push(playerMoved({ at, playerId: row.id, x: p.x, y: p.y, distance }));
      }

      if (knowSelf && canJudge && near !== p.isNear) {
        p.isNear = near;
        p.nearSince = near ? at.toISOString() : null;
        stateChanged = true;
        emit.push(
          proximity({
            at,
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
      if (rows.length === 0) break; // an empty roster means "unknown", not "empty"
      p.inSpace = false;
      if (p.isNear) {
        p.isNear = false;
        p.nearSince = null;
        emit.push(proximity({ at, playerId: id, near: false }));
      }
      if (p.isFollowingMe) {
        p.isFollowingMe = false;
        p.followingMeSince = null;
        emit.push(
          follow({
            at,
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
