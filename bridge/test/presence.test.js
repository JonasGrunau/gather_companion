import assert from 'node:assert/strict';
import { test } from 'node:test';

import { PresenceTracker } from '../lib/presence.js';

/**
 * Regressions for ways the tracker used to describe the world wrongly: empty
 * desks reported as people standing next to you, and `player.moved` never being
 * emitted at all. Plus the shape of what the roster can and cannot know.
 */

const ME = '11111111-1111-1111-1111-111111111111';
const THEM = '22222222-2222-2222-2222-222222222222';
const FLOOR = 'ffffffff-ffff-ffff-ffff-ffffffffffff';

/** A roster row as `GameProtocolReader.roster()` builds them. */
const row = (id, extra = {}) => ({
  id,
  name: `user-${id.slice(0, 4)}`,
  x: 10,
  y: 10,
  clusterId: null,
  floorId: FLOOR,
  connected: true,
  ...extra,
});

/** Puts the tracker at (10,10) with `them` wherever the test wants them. */
function trackerAt(themExtra) {
  const tracker = new PresenceTracker();
  tracker.applyRoster({ selfId: ME, rows: [row(ME), row(THEM, themExtra)] });
  return tracker;
}

const playerOf = (tracker, id) => tracker.snapshot().players.find((p) => p.id === id);

// ---- what the roster cannot know -------------------------------------------

test('mic, camera and screenshare stay empty because nothing can fill them', () => {
  // Pinned deliberately. These three were read out of the desktop client's log,
  // which only ever emitted the *unpause* — so they could be turned off and never
  // on — and `SpaceUser` carries no media columns at all. The log parser that
  // supplied them is gone. If a future capture proves Gather exposes them
  // somewhere, this test is the thing to delete, on purpose rather than by
  // accident.
  const them = playerOf(trackerAt({ x: 10, y: 10 }), THEM);

  assert.equal(them.micOn, null);
  assert.equal(them.cameraOn, null);
  assert.equal(them.screensharing, false);
});

test('voice activity is state, and never news', () => {
  // `speaking` is the most frequent patch on a live socket — 13 of 46 deltas in
  // a three-minute sample. It belongs in the snapshot and nowhere near the feed.
  const tracker = trackerAt({ speaking: false });
  const out = tracker.applyRoster({
    selfId: ME,
    rows: [row(ME), row(THEM, { speaking: true })],
  });

  assert.equal(playerOf(tracker, THEM).speaking, true);
  assert.equal(out.stateChanged, true, 'the snapshot has to be republished');
  assert.deepEqual(out.emit, [], 'but nothing goes in the feed');
});

// ---- empty desks -----------------------------------------------------------

test('an offline avatar parked next to you is not standing next to you', () => {
  // Same tile as me, but logged off — this is what an empty desk looks like.
  const tracker = trackerAt({ x: 10, y: 10, connected: false });

  const them = playerOf(tracker, THEM);
  assert.equal(them.isNear, false, 'a disconnected row cannot be standing anywhere');
  assert.equal(them.inSpace, false);
});

test('a connected neighbour on the same tile is still near', () => {
  const tracker = trackerAt({ x: 10, y: 10, connected: true });
  assert.equal(playerOf(tracker, THEM).isNear, true, 'the fix must not silence real people');
});

test('going offline clears a proximity we had already reported', () => {
  const tracker = trackerAt({ x: 10, y: 10, connected: true });
  assert.equal(playerOf(tracker, THEM).isNear, true);

  const out = tracker.applyRoster({
    selfId: ME,
    rows: [row(ME), row(THEM, { x: 10, y: 10, connected: false })],
  });

  assert.equal(playerOf(tracker, THEM).isNear, false);
  const left = out.emit.filter((e) => e.type === 'proximity.left');
  assert.equal(left.length, 1, 'the app has to be told they are gone');
});

test('an unknown connected state is still judged — unknown is not absent', () => {
  const tracker = trackerAt({ x: 10, y: 10, connected: null });
  assert.equal(playerOf(tracker, THEM).isNear, true);
});

// ---- player.moved ----------------------------------------------------------

test('a first sighting is not a move', () => {
  const tracker = new PresenceTracker();
  const out = tracker.applyRoster({ selfId: ME, rows: [row(ME), row(THEM, { x: 10, y: 10 })] });

  assert.equal(
    out.emit.filter((e) => e.type === 'player.moved').length,
    0,
    'the initial state dump would otherwise move all 80 rows in from nowhere',
  );
});

test('a neighbour changing tiles emits player.moved', () => {
  const tracker = trackerAt({ x: 10, y: 10 });

  const out = tracker.applyRoster({
    selfId: ME,
    rows: [row(ME), row(THEM, { x: 11, y: 10 })],
  });

  const moves = out.emit.filter((e) => e.type === 'player.moved');
  assert.equal(moves.length, 1);
  assert.equal(moves[0].playerId, THEM);
  assert.equal(moves[0].x, 11);
  assert.equal(moves[0].source, 'gather');
  assert.equal(moves[0].distance, 1);
});

test('someone across the map moving stays quiet', () => {
  const tracker = trackerAt({ x: 60, y: 60 });

  const out = tracker.applyRoster({
    selfId: ME,
    rows: [row(ME), row(THEM, { x: 61, y: 60 })],
  });

  assert.equal(
    out.emit.filter((e) => e.type === 'player.moved').length,
    0,
    'only the people the app is watching are worth a move event',
  );
});

test('an offline row shuffling position emits nothing', () => {
  const tracker = trackerAt({ x: 10, y: 10, connected: false });

  const out = tracker.applyRoster({
    selfId: ME,
    rows: [row(ME), row(THEM, { x: 11, y: 10, connected: false })],
  });

  assert.equal(out.emit.filter((e) => e.type === 'player.moved').length, 0);
});
