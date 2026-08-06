import assert from 'node:assert/strict';
import { test } from 'node:test';

import { GatherLogParser } from '../lib/log-parser.js';
import { PresenceTracker } from '../lib/presence.js';

/**
 * Regressions for three ways the tracker used to describe the world wrongly:
 * people reported as screen sharing who were not, empty desks reported as people
 * standing next to you, and `player.moved` never being emitted at all.
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

// ---- screen sharing --------------------------------------------------------

/**
 * Copied verbatim from a real main.log. Gather emits this when the client
 * *subscribes* to a remote track, and never emits the matching `true`, so it
 * cannot be read as "they started sharing".
 */
const SCREEN_UNPAUSED =
  '[2026-08-06 12:11:31.131] [verbose] (webapp)                       GameMediaController.remoteParticipantTrackStateChangedHandler setStreamPausedState 1652d4a7-7874-4c66-b571-d55d00205705 screen false';

test('a track unpause does not claim someone is sharing their screen', () => {
  const tracker = new PresenceTracker();
  const parser = new GatherLogParser();

  const events = parser.feed(SCREEN_UNPAUSED);
  assert.equal(events.length, 1, 'the line still parses into a media event');
  assert.equal(events[0].track, 'screen');
  assert.equal(events[0].paused, false);

  for (const e of events) tracker.apply(e);

  const them = playerOf(tracker, '1652d4a7-7874-4c66-b571-d55d00205705');
  assert.equal(them.screensharing, false, 'an unpaused subscription is not a screen share');
});

test('a pause is trusted, and turns the track off', () => {
  const tracker = new PresenceTracker();
  // A camera, because `screensharing` already defaults to false and so has
  // nowhere to fall — mute and camera-off are the transitions a pause can carry.
  const paused = SCREEN_UNPAUSED.replace('screen false', 'video true');

  const [event] = new GatherLogParser().feed(paused);
  const out = tracker.apply(event);

  assert.equal(playerOf(tracker, event.playerId).cameraOn, false);
  assert.equal(out.stateChanged, true, 'a pause is the one direction we can believe');
});

test('no log line can assert that somebody else is screen sharing', () => {
  // Worth pinning: the desktop client only ever logs the unpause, `SpaceUser`
  // carries no media columns at all, and so the bridge has no honest way to say
  // this is true. If a future capture proves otherwise, this test is the thing
  // to delete — deliberately, rather than by accident.
  const tracker = new PresenceTracker();
  const parser = new GatherLogParser();

  for (const state of ['true', 'false']) {
    for (const event of parser.feed(SCREEN_UNPAUSED.replace('screen false', `screen ${state}`))) {
      tracker.apply(event);
    }
  }

  const them = playerOf(tracker, '1652d4a7-7874-4c66-b571-d55d00205705');
  assert.equal(them.screensharing, false);
});

test('an unrecognised track name never lands on screensharing', () => {
  const tracker = new PresenceTracker();
  const out = tracker.apply({
    type: 'media.changed',
    at: new Date().toISOString(),
    source: 'log',
    playerId: THEM,
    track: 'datachannel',
    paused: true,
  });

  assert.equal(out.stateChanged, false);
  assert.equal(playerOf(tracker, THEM).screensharing, false);
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
  assert.equal(moves[0].source, 'cdp');
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
