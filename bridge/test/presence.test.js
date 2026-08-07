import assert from 'node:assert/strict';
import { test } from 'node:test';

import { PresenceTracker } from '../lib/presence.js';

/**
 * What the roster can and cannot know, and what is worth republishing a snapshot
 * for. Proximity used to live here too; it is gone, and the tests that pinned its
 * thresholds went with it.
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
  floorId: FLOOR,
  connected: true,
  ...extra,
});

/** A tracker that has already seen me and `them`. */
function trackerWith(themExtra) {
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
  const them = playerOf(trackerWith({}), THEM);

  assert.equal(them.micOn, null);
  assert.equal(them.cameraOn, null);
  assert.equal(them.screensharing, false);
});

test('the snapshot carries no notion of who is near whom', () => {
  // The whole point of the removal: a player row is identity and following, and
  // says nothing about where anybody is standing.
  const them = playerOf(trackerWith({}), THEM);

  for (const gone of ['isNear', 'nearSince', 'distance', 'x', 'y', 'inAudioRange']) {
    assert.ok(!(gone in them), `${gone} must not be on the wire`);
  }
});

// ---- voice activity --------------------------------------------------------

test('voice activity is state, and never news', () => {
  // `speaking` is the most frequent patch on a live socket — 13 of 46 deltas in
  // a three-minute sample. It belongs in the snapshot and nowhere near the feed.
  const tracker = trackerWith({ speaking: false, followTargetId: ME });
  const out = tracker.applyRoster({
    selfId: ME,
    rows: [row(ME), row(THEM, { speaking: true, followTargetId: ME })],
  });

  assert.equal(playerOf(tracker, THEM).speaking, true);
  assert.equal(out.stateChanged, true, 'the snapshot has to be republished');
  assert.deepEqual(out.emit, [], 'but nothing goes in the feed');
});

test('a stranger talking does not republish the roster', () => {
  // The flooding fix. The app draws the talking indicator on followers and nobody
  // else, so anyone invisible starting to talk must not cost every phone a full
  // roster — that was 0.86 snapshots/second on a 79-row space.
  const tracker = trackerWith({ speaking: false });
  const out = tracker.applyRoster({
    selfId: ME,
    rows: [row(ME), row(THEM, { speaking: true })],
  });

  assert.equal(playerOf(tracker, THEM).speaking, true, 'the value is still recorded');
  assert.equal(out.stateChanged, false, 'but nobody needs telling about it');
});

// ---- being followed --------------------------------------------------------

test('someone pointing followTargetId at me is following me', () => {
  const tracker = trackerWith({});

  const out = tracker.applyRoster({
    selfId: ME,
    rows: [row(ME), row(THEM, { followTargetId: ME })],
  });

  const started = out.emit.filter((e) => e.type === 'follow.started');
  assert.equal(started.length, 1);
  assert.equal(started[0].followerId, THEM);
  assert.equal(started[0].targetIsSelf, true);
  assert.equal(started[0].confidence, 'observed', 'the field is read, never guessed');
  assert.equal(playerOf(tracker, THEM).isFollowingMe, true);
});

test('somebody following a third party is not following me', () => {
  const tracker = trackerWith({});

  const out = tracker.applyRoster({
    selfId: ME,
    rows: [row(ME), row(THEM, { followTargetId: 'somebody-else' })],
  });

  assert.deepEqual(out.emit, []);
  assert.equal(playerOf(tracker, THEM).isFollowingMe, false);
});

test('a follower dropping out of the roster stops following me', () => {
  const tracker = trackerWith({ followTargetId: ME });
  assert.equal(playerOf(tracker, THEM).isFollowingMe, true);

  const out = tracker.applyRoster({ selfId: ME, rows: [row(ME)] });

  const stopped = out.emit.filter((e) => e.type === 'follow.stopped');
  assert.equal(stopped.length, 1, 'the app must not keep showing a ghost follower');
  assert.equal(stopped[0].followerId, THEM);
  assert.equal(playerOf(tracker, THEM).isFollowingMe, false);
});

test('an empty roster means unknown, not everybody left', () => {
  const tracker = trackerWith({ followTargetId: ME });

  const out = tracker.applyRoster({ selfId: ME, rows: [] });

  assert.deepEqual(out.emit, [], 'a dropped connection is not a room emptying');
  assert.equal(playerOf(tracker, THEM).isFollowingMe, true);
});

// ---- self ------------------------------------------------------------------

test('my own connected state drives inOffice, not my avatar sitting at a desk', () => {
  const tracker = trackerWith({});
  assert.equal(tracker.self.inOffice, true);

  tracker.applyRoster({ selfId: ME, rows: [row(ME, { connected: false }), row(THEM)] });
  assert.equal(tracker.self.inOffice, false, 'a parked avatar is not you being here');
});
