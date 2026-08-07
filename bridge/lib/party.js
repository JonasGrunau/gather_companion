/**
 * Party mode: teleport around the map, without walking into anyone.
 *
 * Four hops a second for as long as it is switched on. Two things make that
 * harder than picking random coordinates.
 *
 * ## Where you *can* stand
 *
 * Gather's game server does not validate walkability — every tile on the grid is
 * accepted, walls and void included (see docs/gather-api.md). Collision is
 * enforced client-side only, so a random tile lands you inside scenery about as
 * often as not.
 *
 * Rather than reconstruct the collision map out of `MapObject` and
 * `CatalogItemVariant.collision`, this takes the empirical route: **a tile
 * somebody has stood on is a tile you can stand on.** The full state dump carries
 * every member of the space with their last position — 111 of them in the space
 * this was built against, most of them parked at a desk — which is a large,
 * free, and definitionally valid set to draw from. It grows as the session runs,
 * because everyone who walks anywhere contributes the tiles they walk through.
 *
 * ## Where you *should not* stand
 *
 * Landing next to a colleague opens the video bubble on their screen. Doing that
 * four times a second, to a different person each time, would be a genuinely
 * antisocial thing to inflict on an office. So every candidate is held at least
 * [SAFE_TILES] away from everyone currently connected — comfortably outside the
 * radius at which Gather connects media.
 *
 * When nowhere is safe, the hop is **skipped** rather than approximated. A party
 * that pauses is a smaller problem than a party that walks into someone.
 *
 * ## Where you *want* to go
 *
 * Picking uniformly from the safe set is random but does not look it. The set is
 * small — 35 of 107 known tiles in the measured space — so hops land in the same
 * corner over and over, and consecutive picks are often two tiles apart, which
 * reads as a twitch rather than a teleport. So every hop must clear a minimum
 * distance measured against the size of the floor itself ([JUMP_FRACTIONS]), and
 * among the tiles that qualify the stalest win ([_leastVisited]) — the floor gets
 * covered before anywhere is repeated.
 */

import { EventEmitter } from 'node:events';

/** How often to hop. */
export const HOP_INTERVAL_MS = 250;

/**
 * Tiles of clearance from every connected person.
 *
 * Gather connects media at around 3 tiles. This is deliberately more than double
 * that: positions arrive coalesced over a 250ms window, so the roster is always
 * slightly behind, and somebody walking towards a tile we picked a moment ago
 * should still not end up next to us.
 */
export const SAFE_TILES = 8;

/**
 * How long party mode runs before switching itself off.
 *
 * The toggle lives on a phone; the hopping happens on a computer that will
 * happily keep going for days. Between a dead battery, a closed app and a phone
 * left in a drawer, "on until someone says otherwise" eventually means "on for a
 * week", writing to a real workspace at 4Hz the whole time. Ending on its own is
 * the difference between a feature and a hazard.
 */
export const MAX_DURATION_MS = 15 * 60_000;

/** Faced at random, because always looking Down is a tell. */
const DIRECTIONS = ['Up', 'Down', 'Left', 'Right'];

/**
 * How often a running party says how it is going.
 *
 * Separate from `change`, and much cheaper. `change` means the answer to "is this
 * on, and if not why not" moved, and it publishes a whole snapshot; the hop counter
 * moving is not that, but a counter frozen at 4 on a screen the user is watching
 * reads as a crash. So progress is its own event, on its own small frame — see
 * `BridgeServer._publishParty`.
 */
const PROGRESS_INTERVAL_MS = 1000;

/**
 * How far a hop has to carry you, as a fraction of how big the floor is.
 *
 * Tried in order, first one that has anywhere to go wins. Uniform sampling from
 * the safe set does not read as dancing — the pool is small (35 safe tiles of 107
 * known in the measured space), so it revisits the same corner every few hops and
 * looks like a stutter. Worse, two consecutive picks are often neighbours, and a
 * two-tile shuffle does not look like a teleport at all.
 *
 * Measuring against the floor's own size rather than a fixed tile count is what
 * makes this work in a broom cupboard and in a 50×50 office: 0.55 of the diagonal
 * is always "most of the way across the map". The ladder down exists because the
 * constraint must never be able to stall the party — when everyone crowds one end
 * and the only safe tiles are close together, a short hop beats a skipped one.
 */
const JUMP_FRACTIONS = [0.55, 0.35, 0.2, 0.08, 0];

/**
 * How many tiles a hop wants to choose between.
 *
 * Distance and variety pull against each other, and the safe pool is small — 22
 * tiles of 78 known, in the space this was measured against, because holding
 * [SAFE_TILES] clear of 21 people eats most of a 52x49 floor. Demanding the
 * longest jump available then leaves only two or three places to go, and the dance
 * degenerates into bouncing between opposite corners: 120 hops used 23 tiles and
 * landed on one of them 42 times.
 *
 * So the rule is not "jump as far as possible", it is **"jump as far as possible
 * while still having somewhere to choose from"**. Taking the longest rung of
 * [JUMP_FRACTIONS] that offers this many candidates costs a little distance and
 * buys back the whole floor.
 */
const MIN_CHOICES = 6;

/**
 * The shortest thing that counts as a teleport at all.
 *
 * [JUMP_FRACTIONS] is relative to the floor, which is what makes it portable — but
 * relative alone is not enough. The safe tiles are not spread evenly: this space
 * has a dense knot of them in one corner, and "as far as possible while having six
 * choices" was happy to shuffle five tiles inside that knot. Five tiles is not a
 * teleport, it is a walk.
 *
 * Ten is past every radius that means anything here — Gather opens a video bubble
 * around three, `SAFE_TILES` is eight — so a hop that clears it has unambiguously
 * gone somewhere else. Only a floor with nothing at all this far away relaxes it.
 */
export const MIN_JUMP_TILES = 10;

export class PartyMode extends EventEmitter {
  /**
   * @param {object} options
   * @param {() => (import('./direct.js').DirectCollector|null)} options.collector
   *   Looked up per hop rather than held: the collector is replaced when the
   *   bridge reconnects, and a stale reference would teleport into a dead socket.
   */
  constructor({
    collector,
    log = () => {},
    intervalMs = HOP_INTERVAL_MS,
    safeTiles = SAFE_TILES,
    maxDurationMs = MAX_DURATION_MS,
    // Test seams. Production uses neither.
    random = Math.random,
    now = () => Date.now(),
  }) {
    super();
    this._collector = collector;
    this.log = log;
    this.intervalMs = intervalMs;
    this.safeTiles = safeTiles;
    this.maxDurationMs = maxDurationMs;
    this._random = random;
    this._now = now;

    /** @type {Map<string, Map<string, {x:number,y:number}>>} floorId -> tiles. */
    this._tiles = new Map();
    /** The most recent roster, which is what "where is everyone" is answered from. */
    this._roster = null;
    /**
     * @type {Map<string, number>} tile key -> the hop that last used it.
     *
     * A blocklist of the last dozen tiles used to stand here, which kept the very
     * next hop from repeating but did nothing about the pool as a whole: with 35
     * safe tiles, hop 13 was free to land back where hop 1 did, so the dance
     * covered one quarter of the floor and hammered it. Recording *when* each tile
     * was used instead turns avoidance into coverage — the whole floor gets
     * visited before anywhere is repeated.
     */
    this._visits = new Map();

    this._timer = null;
    this._stopAt = 0;
    /** When the last `progress` went out, so it stays at one a second. */
    this._progressAt = 0;
    this._active = false;
    this._hops = 0;
    this._safeCount = 0;
    this._detail = null;
  }

  get active() {
    return this._active;
  }

  /** What the app renders, and what `/party` answers with. */
  state() {
    return {
      active: this._active,
      hops: this._hops,
      safeTiles: this._safeCount,
      detail: this._detail,
    };
  }

  /**
   * Learn from a roster: every position in it is somewhere a body fits.
   *
   * Offline rows count. Their coordinates are wherever that person logged off,
   * which is a real tile they really stood on — and, being offline, one nobody
   * is standing on now. That makes the parked half of a large space the single
   * best source of safe tiles rather than dead weight.
   */
  noteRoster(roster) {
    this._roster = roster;
    for (const row of roster?.rows ?? []) {
      if (!Number.isFinite(row.x) || !Number.isFinite(row.y)) continue;
      const floorId = row.floorId ?? '';
      let pool = this._tiles.get(floorId);
      if (!pool) {
        pool = new Map();
        this._tiles.set(floorId, pool);
      }
      pool.set(`${row.x},${row.y}`, { x: row.x, y: row.y });
    }
  }

  /** How many tiles we know about, across all floors. Diagnostics only. */
  get knownTiles() {
    let total = 0;
    for (const pool of this._tiles.values()) total += pool.size;
    return total;
  }

  start() {
    if (this._active) return this.state();

    // Refuse rather than start something that cannot work: a button that lights
    // up and does nothing is worse than one that says why not.
    const blocked = this._blocker();
    if (blocked) {
      this._setDetail(blocked);
      return { ...this.state(), ok: false };
    }

    this._active = true;
    this._hops = 0;
    this._visits.clear();
    this._stopAt = this._now() + this.maxDurationMs;
    // Not zero: `start` already publishes the state, so the first counter update
    // is due a second from now rather than immediately after it.
    this._progressAt = this._now();
    this._setDetail(null, { silent: true });
    this.log(`party mode: on — hopping every ${this.intervalMs}ms`);

    this._timer = setInterval(() => this._tick(), this.intervalMs);
    this._timer.unref?.();
    this._emitChange();
    // The first hop happens immediately: a quarter of a second of nothing reads
    // as the button having failed.
    this._tick();
    return { ...this.state(), ok: true };
  }

  stop(reason = null) {
    if (!this._active) return this.state();
    if (this._timer) clearInterval(this._timer);
    this._timer = null;
    this._active = false;
    this.log(`party mode: off after ${this._hops} hops${reason ? ` — ${reason}` : ''}`);
    this._setDetail(reason, { silent: true });
    this._emitChange();
    return this.state();
  }

  /** Why party mode cannot run right now, or null if it can. */
  _blocker() {
    const collector = this._collector();
    if (!collector) return 'the bridge is not connected to Gather';
    if (!collector.selfId) return 'still working out which avatar is yours';
    if (!this._roster) return 'waiting for the first roster from Gather';
    return null;
  }

  _tick() {
    if (!this._active) return;

    if (this._now() >= this._stopAt) {
      this.stop(`ended on its own after ${Math.round(this.maxDurationMs / 60_000)} minutes`);
      return;
    }

    const collector = this._collector();
    if (!collector) {
      this._setDetail('the bridge is not connected to Gather');
      return;
    }

    const { tiles, detail, me } = this.safeTilesNow();
    this._safeCount = tiles.length;
    if (tiles.length === 0) {
      this._setDetail(detail ?? 'nowhere far enough from everyone to jump to');
      return;
    }

    const tile = this._pick(tiles, me);
    const direction = DIRECTIONS[Math.floor(this._random() * DIRECTIONS.length) % DIRECTIONS.length];
    const sent = collector.teleport({ x: tile.x, y: tile.y, direction });
    if (!sent.ok) {
      this._setDetail(sent.detail ?? 'could not reach Gather');
      return;
    }

    this._hops++;
    this._remember(tile);
    this._setDetail(null);

    const now = this._now();
    if (now - this._progressAt >= PROGRESS_INTERVAL_MS) {
      this._progressAt = now;
      this.emit('progress', this.state());
    }
  }

  /**
   * Every known tile on my floor that is at least [safeTiles] from everyone
   * connected.
   *
   * Exposed rather than private because it is the whole interesting part, and
   * the only thing worth testing directly.
   */
  safeTilesNow() {
    const roster = this._roster;
    if (!roster) return { tiles: [], detail: 'waiting for the first roster from Gather' };

    const me = roster.rows?.find((r) => r.id === roster.selfId) ?? null;
    if (!me) return { tiles: [], detail: 'still working out which avatar is yours' };

    const floorId = me.floorId ?? '';
    const pool = this._tiles.get(floorId);
    if (!pool || pool.size === 0) {
      return { tiles: [], detail: 'no tiles known on this floor yet', me };
    }

    // Only people who are actually here can be walked into. An offline row is an
    // avatar parked at a desk — the same reasoning `presence.js` uses to avoid
    // reporting empty desks as colleagues standing next to you.
    const others = [];
    for (const row of roster.rows) {
      if (row.id === roster.selfId) continue;
      if (row.connected === false) continue;
      if (!Number.isFinite(row.x) || !Number.isFinite(row.y)) continue;
      // An unknown floor is not an objection — the same "no objection" reading
      // presence.js takes, and here it errs towards being *more* careful.
      if (row.floorId != null && floorId !== '' && row.floorId !== floorId) continue;
      others.push(row);
    }

    const clearance = this.safeTiles;
    const tiles = [];
    for (const tile of pool.values()) {
      // Standing still is not a hop.
      if (tile.x === me.x && tile.y === me.y) continue;
      let clear = true;
      for (const other of others) {
        if (Math.hypot(tile.x - other.x, tile.y - other.y) < clearance) {
          clear = false;
          break;
        }
      }
      if (clear) tiles.push(tile);
    }

    if (tiles.length === 0) {
      return {
        tiles,
        detail:
          others.length > 0
            ? `everywhere known is within ${clearance} tiles of someone`
            : 'no tiles known on this floor yet',
        me,
      };
    }
    return { tiles, detail: null, me };
  }

  /**
   * The next tile: as far from where I am as the floor allows, favouring the parts
   * of it I have not been to yet.
   *
   * Two constraints, applied in that order, because they answer different
   * complaints. Distance is what makes a single hop *look* like a teleport instead
   * of a step. Coverage is what stops a hundred hops from being the same six
   * tiles.
   */
  _pick(tiles, me) {
    const away = (t) => Math.hypot(t.x - me.x, t.y - me.y);

    // The hard floor first, and everything after it works inside the result — so
    // relaxing for choice or for a cramped floor can never talk us back into a
    // short hop.
    const eligible = tiles.filter((t) => away(t) >= MIN_JUMP_TILES);
    const pool = eligible.length > 0 ? eligible : tiles;

    // Then the longest rung that still offers a real choice. Each rung down is a
    // superset of the one above, so the search is monotonic: this lands on the most
    // demanding distance this floor can actually satisfy.
    const reach = this._spread(pool);
    let candidates = pool;
    for (const fraction of JUMP_FRACTIONS) {
      const min = reach * fraction;
      if (min <= 0) break; // The last rung admits everything, which `candidates` already is.
      const far = pool.filter((t) => away(t) >= min);
      if (far.length === 0) continue;
      candidates = far;
      if (far.length >= MIN_CHOICES) break;
    }
    return this._leastVisited(candidates);
  }

  /**
   * How far apart the two most distant candidates could be: the diagonal of their
   * bounding box. A cheap stand-in for the diameter of the walkable area, and the
   * yardstick [JUMP_FRACTIONS] is a fraction of.
   */
  _spread(tiles) {
    let minX = Infinity;
    let minY = Infinity;
    let maxX = -Infinity;
    let maxY = -Infinity;
    for (const t of tiles) {
      if (t.x < minX) minX = t.x;
      if (t.x > maxX) maxX = t.x;
      if (t.y < minY) minY = t.y;
      if (t.y > maxY) maxY = t.y;
    }
    return Math.hypot(maxX - minX, maxY - minY);
  }

  /**
   * One of the candidates that has been used least recently, chosen at random
   * among them.
   *
   * Never-visited tiles win outright, so a fresh party sweeps the whole floor
   * before repeating anything. Once everywhere has been used the field narrows to
   * the stalest half and picks randomly inside it — deterministic enough to keep
   * moving across the map, random enough that a human cannot see the pattern.
   */
  _leastVisited(candidates) {
    const unseen = candidates.filter((t) => !this._visits.has(`${t.x},${t.y}`));
    let from = unseen;
    if (from.length === 0) {
      const stalest = [...candidates].sort(
        (a, b) => this._visits.get(`${a.x},${a.y}`) - this._visits.get(`${b.x},${b.y}`),
      );
      from = stalest.slice(0, Math.max(1, Math.ceil(stalest.length / 2)));
    }
    return from[Math.floor(this._random() * from.length) % from.length];
  }

  _remember(tile) {
    this._visits.set(`${tile.x},${tile.y}`, this._hops);
  }

  /**
   * Records why the party is or is not going, and tells the app **only when the
   * answer changes**.
   *
   * Load-bearing: this runs four times a second, and every change event
   * publishes a snapshot to every connected phone. An unconditional emit would
   * be 4 snapshots per second per client for as long as party mode is on.
   */
  _setDetail(detail, { silent = false } = {}) {
    const next = detail ?? null;
    if (next === this._detail) return;
    this._detail = next;
    if (next) this.log(`party mode: ${next}`);
    if (!silent) this._emitChange();
  }

  _emitChange() {
    this.emit('change', this.state());
  }
}
