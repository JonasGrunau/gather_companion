import test from 'node:test';
import assert from 'node:assert/strict';

import { PartyMode, SAFE_TILES } from '../lib/party.js';

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

  // Someone standing exactly one tile outside our own "next to me" radius. A
  // naive implementation reusing ADJACENT_TILES (3) would happily jump here.
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

test('the walkable pool grows as people walk around', () => {
  const p = party(fakeCollector());

  p.noteRoster(roster([person(ME, 0, 0), person('2222', 50, 50)]));
  assert.equal(p.knownTiles, 2);

  // Same two people, two tiles further along. Their old tiles stay in the pool:
  // somewhere a body has been is somewhere a body fits.
  p.noteRoster(roster([person(ME, 0, 1), person('2222', 51, 50)]));
  assert.equal(p.knownTiles, 4);
});
