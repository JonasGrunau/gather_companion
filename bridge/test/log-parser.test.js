import assert from 'node:assert/strict';
import { test } from 'node:test';

import { GatherLogParser, parseInspect } from '../lib/log-parser.js';

/** Every line here is copied verbatim from a real ~/Library/Logs/GatherV2/main.log. */
const LINES = {
  joinedSpace:
    '[2026-07-31 12:09:15.548] [verbose] (webapp)                      [PlayerManagerV2] Player has joined 21fc9d25-91c9-4101-9fa0-5aa3a54f983e',
  leftSpace:
    '[2026-07-31 12:09:13.557] [verbose] (webapp)                      [PlayerManagerV2] Player has left 21fc9d25-91c9-4101-9fa0-5aa3a54f983e',
  participantJoined:
    '[2026-07-31 12:18:47.199] [verbose] (webapp)                       GameMediaController.remoteParticipantJoinedHandler 1652d4a7-7874-4c66-b571-d55d00205705 [object Object] [object Object]',
  participantLeft:
    '[2026-07-31 12:30:29.740] [verbose] (webapp)                       GameMediaController.remoteParticipantLeftHandler 1652d4a7-7874-4c66-b571-d55d00205705',
  trackPaused:
    '[2026-07-31 12:07:07.376] [verbose] (webapp)                       GameMediaController.remoteParticipantTrackStateChangedHandler setStreamPausedState c599db80-52ca-4e05-85a4-f2d4b37eaa3e video false',
  connectionState:
    '[2026-07-31 12:08:44.693] [verbose] (webapp)                       GameMediaController.remoteParticipantConnectionStateChangedHandler b1821f00-0c40-47fc-905d-3c6637525ac0 Connected',
  volumeOut:
    '[2026-07-31 12:07:07.376] [verbose] (webapp)                      [Vol] set afabc16a-ef09-44d2-bd72-ef6874c62051 : 1 -> 0',
  audioUpdated:
    '[2026-07-31 10:07:04.864] [info]  (main)                        IPC Event: AUDIO_UPDATED { audio: false }',
  videoUpdated:
    '[2026-07-31 10:00:21.693] [info]  (main)                        IPC Event: VIDEO_UPDATED { video: true }',
  showNotification:
    "[2026-07-31 09:55:00.823] [info]  (main)                        IPC Event: SHOW_NOTIFICATION { type: 'event reminder' }",
  showingNotification:
    '[2026-07-31 09:55:00.824] [info]  (main)                        Showing notification 7d6962b0-9fb7-404a-8f9a-5bdc3b3388e2: event reminder',
  // Same namespace trap as the parser docs describe: this id is a *participant*
  // id, not a player id, so it must not be treated as proximity.
  sfuLeaving:
    '[2026-07-31 12:07:07.638] [verbose] (webapp)                      10:07:07:637 ENTER [GatherPeerManager][playerLeavingSFU] 66f9c700-fe81-45a4-8a95-62fd72a26913',
  followPathfinding:
    '[2026-07-31 13:22:25.425] [error] (webapp)                      [VW] [Pathfinding] Unable to find path in `setFollowTarget`: NoPathFound undefined undefined',
  noise:
    '[2026-07-31 13:51:39.261] [verbose] (webapp)                      11:51:39:261 [Krisp] Including stats in av-bandwidth-health [object Object]',
};

function parseOne(line) {
  const events = new GatherLogParser().feed(line);
  assert.equal(events.length, 1, `expected exactly one event from: ${line}`);
  return events[0];
}

test('space roster join and leave', () => {
  const joined = parseOne(LINES.joinedSpace);
  assert.equal(joined.type, 'player.joinedSpace');
  assert.equal(joined.playerId, '21fc9d25-91c9-4101-9fa0-5aa3a54f983e');
  assert.equal(joined.source, 'log');

  assert.equal(parseOne(LINES.leftSpace).type, 'player.leftSpace');
});

test('media participant join/leave becomes inferred proximity', () => {
  const near = parseOne(LINES.participantJoined);
  assert.equal(near.type, 'proximity.entered');
  assert.equal(near.playerId, '1652d4a7-7874-4c66-b571-d55d00205705');
  assert.equal(near.confidence, 'inferred', 'log-derived proximity is a proxy, not a measurement');
  assert.equal(near.distance, null);

  assert.equal(parseOne(LINES.participantLeft).type, 'proximity.left');
});

test('track state and connection state', () => {
  const track = parseOne(LINES.trackPaused);
  assert.equal(track.type, 'media.changed');
  assert.equal(track.track, 'video');
  assert.equal(track.paused, false);

  const conn = parseOne(LINES.connectionState);
  assert.equal(conn.type, 'media.connection');
  assert.equal(conn.state, 'Connected');
});

test('volume transition reports audio range', () => {
  const vol = parseOne(LINES.volumeOut);
  assert.equal(vol.type, 'audio.range');
  assert.equal(vol.inRange, false);
  assert.equal(vol.volume, 0);
});

test('own mic and camera come from the IPC trace', () => {
  const audio = parseOne(LINES.audioUpdated);
  assert.equal(audio.type, 'self.changed');
  assert.equal(audio.audioEnabled, false);
  assert.equal(audio.videoEnabled, null, 'unrelated fields stay null so the tracker can ignore them');

  assert.equal(parseOne(LINES.videoUpdated).videoEnabled, true);
});

test('notifications are picked up from both the IPC trace and the shell log', () => {
  const ipc = parseOne(LINES.showNotification);
  assert.equal(ipc.type, 'notification.shown');
  assert.equal(ipc.notificationType, 'event reminder');

  const shell = parseOne(LINES.showingNotification);
  assert.equal(shell.notificationType, 'event reminder');
});

test('SFU lines are ignored: they use the participant id namespace', () => {
  // Verified empirically: 0 of 13 playerConnectedSFU/playerLeavingSFU ids ever
  // appeared in the PlayerManagerV2 roster, so treating them as players would
  // invent people who do not exist.
  assert.deepEqual(new GatherLogParser().feed(LINES.sfuLeaving), []);
});

test('an outgoing follow attempt is not reported as being followed', () => {
  const event = parseOne(LINES.followPathfinding);
  assert.equal(event.type, 'follow.selfPathfinding');
  assert.notEqual(event.type, 'follow.started');
});

test('unrelated chatter produces nothing', () => {
  assert.deepEqual(new GatherLogParser().feed(LINES.noise), []);
  assert.deepEqual(new GatherLogParser().feed(''), []);
  assert.deepEqual(new GatherLogParser().feed('not a log line at all'), []);
});

test('multi-line util.inspect bodies are assembled', () => {
  const parser = new GatherLogParser();
  // Pretty-printed shared-state pushes span several lines; the interesting
  // fields only appear once the body has arrived.
  assert.deepEqual(
    parser.feed('[2026-07-31 09:52:29.730] [info]  (main)                        IPC Event: UPDATE_SHARED_STATE {'),
    [],
  );
  assert.deepEqual(parser.feed('  hwSystemMemory: 50.331648,'), []);
  assert.deepEqual(parser.feed('  audioEnabled: false,'), []);
  const out = parser.feed('}');
  assert.equal(out.length, 1);
  assert.equal(out[0].type, 'self.changed');
  assert.equal(out[0].audioEnabled, false);
});

test('memory-only shared state updates are dropped as noise', () => {
  const parser = new GatherLogParser();
  parser.feed('[2026-07-31 09:52:29.730] [info]  (main)                        IPC Event: UPDATE_SHARED_STATE {');
  parser.feed('  hwSystemMemory: 50.331648,');
  parser.feed('  gatherPrivateProcessMemory: 0,');
  assert.deepEqual(parser.feed('}'), []);
});

test('timestamps come from the client, not from now', () => {
  const event = parseOne(LINES.joinedSpace);
  const at = new Date(event.at);
  assert.equal(at.getFullYear(), 2026);
  assert.equal(at.getMonth(), 6); // July, zero-based
  assert.equal(at.getDate(), 31);
});

test('parseInspect reads quoted and bare values', () => {
  assert.deepEqual(parseInspect("{ type: 'event reminder' }"), { type: 'event reminder' });
  assert.deepEqual(parseInspect('{ audio: false }'), { audio: 'false' });
  assert.deepEqual(parseInspect('{ a: 1,\n  b: 2 }'), { a: '1', b: '2' });
});
