import test from 'node:test';
import assert from 'node:assert/strict';

import { MIN_JUMP_TILES, PartyMode, SAFE_TILES } from '../lib/party.js';

const ME = '11111111-1111-1111-1111-111111111111';
const FLOOR = 'ffffffff-0000-0000-0000-000000000000';
const UPSTAIRS = 'ffffffff-1111-1111-1111-111111111111';

function person(id, x, y, { connected = true, floorId = FLOOR } = {}) {
  return { id, name: `p-${id.slice(0, 4)}`, x, y, floorId, connected, clusterId: null };
}

/** A roster in the shape `GameProtocolReader.roster()` produces. */
function roster(rows) {
  return { selfId: ME, rows, spaceName: 'Test Space' };
}

/**
 * A collector stand-in that records teleports instead of sending them.
 *
 * Deliberately not the real `DirectCollector`: what is under test is which tile
 * gets chosen, and a real one would need a socket to refuse on.
 */
function fakeCollector({ selfId = ME, fails = false } = {}) {
  return {
    selfId,
    sent: [],
    teleport(args) {
      if (fails) return { ok: false, detail: 'not connected to Gather' };
      this.sent.push(args);
      return { ok: true };
    },
  };
}

/** A party wired to `collector`, with randomness and the clock made boring. */
function party(collector, options = {}) {
  return new PartyMode({
    collector: () => collector,
    random: () => 0,
    ...options,
  });
}

test('a tile is only offered when it clears everyone who is connected', () => {
  const collector = fakeCollector();
  const p = party(collector);

  // Three known tiles, learned from where these people are standing.
  p.noteRoster(
    roster([
      person(ME, 10, 10),
      person('2222', 12, 10), // here now, so their tile is out
      person('3333', 60, 60, { connected: false }), // logged off across the map
    ]),
  );

  const { tiles } = p.safeTilesNow();
  const keys = tiles.map((t) => `${t.x},${t.y}`);

  // Our own tile is not a hop, an occupied tile is never a candidate, and the
  // tile that survives is the one nobody is anywhere near.
  assert.deepEqual(keys, ['60,60']);
});

test('everyone connected is cleared, not just the nearest one', () => {
  const collector = fakeCollector();
  const p = party(collector);

  p.noteRoster(
    roster([
      person(ME, 0, 0),
      person('2222', 30, 30),
      person('3333', 34, 30), // 4 tiles from 2222's tile
    ]),
  );

  // 30,30 and 34,30 are each within SAFE_TILES of the *other* person, so
  // neither survives even though both are somewhere a body demonstrably fits.
  assert.equal(p.safeTilesNow().tiles.length, 0);
});

test('a parked avatar donates its tile without defending it', () => {
  const collector = fakeCollector();
  const p = party(collector);

  p.noteRoster(
    roster([
      person(ME, 0, 0),
      // Logged off at their desk. The tile is proof a body fits there, and there
      // is nobody on it to walk into — which is what makes the offline half of a
      // large space the best source of safe tiles rather than dead weight.
      person('2222', 40, 40, { connected: false }),
    ]),
  );

  assert.deepEqual(
    p.safeTilesNow().tiles.map((t) => `${t.x},${t.y}`),
    ['40,40'],
  );
});

test('tiles on another floor are not offered', () => {
  const collector = fakeCollector();
  const p = party(collector);

  p.noteRoster(
    roster([
      person(ME, 0, 0, { floorId: FLOOR }),
      person('2222', 40, 40, { connected: false, floorId: UPSTAIRS }),
    ]),
  );

  // The only tile we know about on our floor is the one we are standing on.
  const { tiles, detail } = p.safeTilesNow();
  assert.equal(tiles.length, 0);
  assert.match(detail, /no tiles known on this floor/);
});

test('the clearance it keeps is wider than the range that opens a video bubble', () => {
  const collector = fakeCollector();
  const p = party(collector);

  // Someone standing one tile outside the ~3-tile radius at which Gather
  // connects media. An implementation that only cleared that would jump here.
  p.noteRoster(roster([person(ME, 0, 0), person('2222', 4, 0)]));

  assert.equal(p.safeTilesNow().tiles.length, 0);
  assert.ok(SAFE_TILES > 4);
});

test('it skips the hop rather than settling for the least bad tile', () => {
  const collector = fakeCollector();
  const p = party(collector, { maxDurationMs: 60_000 });

  p.noteRoster(roster([person(ME, 0, 0), person('2222', 3, 0)]));
  p.start();

  assert.equal(collector.sent.length, 0);
  assert.equal(p.state().active, true);
  assert.match(p.state().detail, /within \d+ tiles of someone/);
});

test('a hop lands on a tile it was told about, and is counted', () => {
  const collector = fakeCollector();
  const p = party(collector, { maxDurationMs: 60_000 });

  p.noteRoster(roster([person(ME, 0, 0), person('2222', 50, 50, { connected: false })]));
  p.start();
  p.stop();

  assert.equal(collector.sent.length, 1);
  assert.equal(collector.sent[0].x, 50);
  assert.equal(collector.sent[0].y, 50);
  // `direction` is required by the server even when teleporting.
  assert.ok(['Up', 'Down', 'Left', 'Right'].includes(collector.sent[0].direction));
  assert.equal(p.state().hops, 1);
});

test('it refuses to start when the bridge cannot act, and says why', () => {
  const p = party(fakeCollector({ selfId: null }));
  const result = p.start();

  assert.equal(result.ok, false);
  assert.equal(result.active, false);
  assert.match(result.detail, /which avatar is yours/);
});

test('hopping does not emit a change per hop', () => {
  const collector = fakeCollector();
  const p = party(collector, { maxDurationMs: 60_000, intervalMs: 1 });

  p.noteRoster(
    roster([
      person(ME, 0, 0),
      person('2222', 50, 50, { connected: false }),
      person('3333', 70, 70, { connected: false }),
    ]),
  );

  let changes = 0;
  p.on('change', () => changes++);

  p.start();
  // Every `change` publishes a snapshot to every connected phone. Four a second
  // for as long as party mode is on would fill the replay history with noise —
  // the same failure the collector's status detail once had.
  for (let i = 0; i < 20; i++) p._tick();
  p.stop();

  assert.equal(p.state().hops, 21);
  assert.equal(changes, 2, 'one for on, one for off');
});

test('it switches itself off rather than running unattended for ever', () => {
  const collector = fakeCollector();
  let clock = 0;
  const p = party(collector, { maxDurationMs: 1000, now: () => clock });

  p.noteRoster(roster([person(ME, 0, 0), person('2222', 50, 50, { connected: false })]));
  p.start();
  assert.equal(p.state().active, true);

  clock = 1001;
  p._tick();

  assert.equal(p.state().active, false);
  assert.match(p.state().detail, /ended on its own/);
});

test('a teleport the collector refuses is reported, not counted', () => {
  const collector = fakeCollector({ fails: true });
  const p = party(collector, { maxDurationMs: 60_000 });

  p.noteRoster(roster([person(ME, 0, 0), person('2222', 50, 50, { connected: false })]));
  p.start();

  assert.equal(p.state().hops, 0);
  assert.match(p.state().detail, /not connected to Gather/);
});

// ---- how the hopping looks --------------------------------------------------

/**
 * A grid of parked avatars, which is a grid of safe tiles.
 *
 * Spread over 0..40 in both axes and all logged off, so every tile is a candidate
 * and nobody can be walked into — leaving the choice of tile as the only variable.
 */
function danceFloor({ step = 8, span = 40 } = {}) {
  const rows = [person(ME, 0, 0)];
  let n = 0;
  for (let x = 0; x <= span; x += step) {
    for (let y = 0; y <= span; y += step) {
      if (x === 0 && y === 0) continue;
      rows.push(person(`p${n++}`.padEnd(4, '0'), x, y, { connected: false }));
    }
  }
  return roster(rows);
}

test('every hop carries you most of the way across the floor', () => {
  const collector = fakeCollector();
  // Real randomness: the guarantee has to hold for any draw, not a chosen one.
  const p = party(collector, { maxDurationMs: 60_000, random: Math.random });
  const floor = danceFloor();
  p.noteRoster(floor);

  p.start();
  // Feed our own new position back after each hop, exactly as a roster would, so
  // "far from where I was" is measured against where we actually are.
  for (let i = 0; i < 40; i++) {
    const last = collector.sent.at(-1);
    p.noteRoster(roster([person(ME, last.x, last.y), ...floor.rows.slice(1)]));
    p._tick();
  }
  p.stop();

  // Where we stood, in order: the tile we started on, then every tile we hopped
  // to. Consecutive pairs are therefore exactly the jumps that were made.
  const seen = [{ x: 0, y: 0 }, ...collector.sent];

  // The hard floor holds for every single hop. The old picker sampled uniformly
  // from the safe set and cheerfully stepped one tile, which does not read as a
  // teleport at all.
  const jumps = [];
  for (let i = 1; i < seen.length; i++) {
    const jump = Math.hypot(seen[i].x - seen[i - 1].x, seen[i].y - seen[i - 1].y);
    assert.ok(jump >= MIN_JUMP_TILES, `hop ${i} only travelled ${jump.toFixed(1)} tiles`);
    jumps.push(jump);
  }

  // And the floor is the floor, not the norm: on a 40x40 grid the typical hop
  // should be crossing a real part of the map, not scraping the minimum.
  jumps.sort((a, b) => a - b);
  const median = jumps[Math.floor(jumps.length / 2)];
  assert.ok(median >= 20, `the median hop was only ${median.toFixed(1)} tiles`);
});

test('it covers the floor instead of wearing out one corner', () => {
  const collector = fakeCollector();
  const p = party(collector, { maxDurationMs: 60_000, random: Math.random });
  const floor = danceFloor();
  p.noteRoster(floor);

  p.start();
  for (let i = 0; i < 30; i++) {
    const last = collector.sent.at(-1);
    p.noteRoster(roster([person(ME, last.x, last.y), ...floor.rows.slice(1)]));
    p._tick();
  }
  p.stop();

  const distinct = new Set(collector.sent.map((t) => `${t.x},${t.y}`)).size;
  // A 12-entry blocklist over a 35-tile pool let hop 13 land back on hop 1's tile,
  // so 31 hops covered a fraction of the floor and hammered it. Preferring the
  // least recently used tile makes repeats the exception rather than the rule.
  assert.ok(distinct >= 24, `only ${distinct} distinct tiles in ${collector.sent.length} hops`);
});

test('a cramped floor still dances rather than standing still', () => {
  const collector = fakeCollector();
  const p = party(collector, { maxDurationMs: 60_000, random: Math.random });

  // Three tiles, all close together, all safe. The minimum-distance rule must
  // relax rather than refuse: a short hop beats a skipped one.
  p.noteRoster(
    roster([
      person(ME, 0, 0),
      person('2222', 30, 30, { connected: false }),
      person('3333', 31, 30, { connected: false }),
      person('4444', 30, 31, { connected: false }),
    ]),
  );

  p.start();
  for (let i = 0; i < 6; i++) {
    const last = collector.sent.at(-1);
    p.noteRoster(
      roster([
        person(ME, last.x, last.y),
        person('2222', 30, 30, { connected: false }),
        person('3333', 31, 30, { connected: false }),
        person('4444', 30, 31, { connected: false }),
      ]),
    );
    p._tick();
  }
  p.stop();

  assert.equal(p.state().hops, 7, 'no hop was skipped for want of distance');
  assert.ok(new Set(collector.sent.map((t) => `${t.x},${t.y}`)).size >= 2);
});

test('the clearance still wins when it conflicts with wanting a long jump', () => {
  const collector = fakeCollector();
  const p = party(collector, { maxDurationMs: 60_000, random: Math.random });

  // The far side of the floor is where somebody is standing. Wanting distance must
  // not become a reason to jump onto a colleague.
  p.noteRoster(
    roster([
      person(ME, 0, 0),
      person('2222', 40, 40), // here now
      person('3333', 41, 40, { connected: false }), // their neighbour's parked tile
      person('4444', 20, 0, { connected: false }), // the only safe tile
    ]),
  );

  p.start();
  p.stop();

  assert.deepEqual(
    collector.sent.map((t) => `${t.x},${t.y}`),
    ['20,0'],
  );
});

test('the walkable pool grows as people walk around', () => {
  const p = party(fakeCollector());

  p.noteRoster(roster([person(ME, 0, 0), person('2222', 50, 50)]));
  assert.equal(p.knownTiles, 2);

  // Same two people, two tiles further along. Their old tiles stay in the pool:
  // somewhere a body has been is somewhere a body fits.
  p.noteRoster(roster([person(ME, 0, 1), person('2222', 51, 50)]));
  assert.equal(p.knownTiles, 4);
});
