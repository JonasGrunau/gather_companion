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
 * [SAFE_TILES] away from everyone currently connected — comfortably outside
 * Gather's proximity radius, and outside the `ADJACENT_TILES` this bridge itself
 * uses to decide somebody is standing next to you.
 *
 * When nowhere is safe, the hop is **skipped** rather than approximated. A party
 * that pauses is a smaller problem than a party that walks into someone.
 */

import { EventEmitter } from 'node:events';

/** How often to hop. */
export const HOP_INTERVAL_MS = 250;

/**
 * Tiles of clearance from every connected person.
 *
 * Gather connects media at around 3 tiles, which is also `ADJACENT_TILES` in
 * `presence.js`. This is deliberately more than double that: positions arrive
 * coalesced over a 250ms window, so the roster is always slightly behind, and
 * somebody walking towards a tile we picked a moment ago should still not end up
 * next to us.
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
 * Recently used tiles, avoided so the hopping looks random to a human.
 *
 * True uniform sampling revisits tiles often enough to read as a stutter rather
 * than as movement — the birthday problem applies to dance floors too.
 */
const RECENT_MEMORY = 12;

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
    /** @type {string[]} keys of the last few tiles visited. */
    this._recent = [];

    this._timer = null;
    this._stopAt = 0;
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
    this._recent = [];
    this._stopAt = this._now() + this.maxDurationMs;
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

    const { tiles, detail } = this.safeTilesNow();
    this._safeCount = tiles.length;
    if (tiles.length === 0) {
      this._setDetail(detail ?? 'nowhere far enough from everyone to jump to');
      return;
    }

    const tile = this._pick(tiles);
    const direction = DIRECTIONS[Math.floor(this._random() * DIRECTIONS.length) % DIRECTIONS.length];
    const sent = collector.teleport({ x: tile.x, y: tile.y, direction });
    if (!sent.ok) {
      this._setDetail(sent.detail ?? 'could not reach Gather');
      return;
    }

    this._hops++;
    this._remember(tile);
    this._setDetail(null);
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
      return { tiles: [], detail: 'no tiles known on this floor yet' };
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
      };
    }
    return { tiles, detail: null };
  }

  /** A tile we have not used lately, falling back to any of them. */
  _pick(tiles) {
    const recent = new Set(this._recent);
    const fresh = tiles.filter((t) => !recent.has(`${t.x},${t.y}`));
    const from = fresh.length > 0 ? fresh : tiles;
    return from[Math.floor(this._random() * from.length) % from.length];
  }

  _remember(tile) {
    this._recent.push(`${tile.x},${tile.y}`);
    if (this._recent.length > RECENT_MEMORY) this._recent.shift();
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
