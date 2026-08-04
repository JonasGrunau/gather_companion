import assert from 'node:assert/strict';
import { test } from 'node:test';

import { GameProtocolReader } from '../lib/game-protocol.js';
import { PresenceTracker } from '../lib/presence.js';

/**
 * Every frame shape here was captured from a live authenticated session, then
 * rewritten with synthetic ids and names. The ops (`addmodel`, `deletemodel`,
 * `replace`), the envelope keys (`fullStatePatches`, `patches`) and the
 * `Connection` identity row are the real thing, not a guess.
 */

const ME = '11111111-1111-1111-1111-111111111111';
const THEM = '22222222-2222-2222-2222-222222222222';
const ELSEWHERE = '33333333-3333-3333-3333-333333333333';
// Shaped like a Firebase uid (28 chars, base62) without being anyone's.
const MY_UID = 'TESTuid000000000000000000000';
const FLOOR = 'ffffffff-ffff-ffff-ffff-ffffffffffff';
const SPACE = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

const spaceUser = (id, name, x, y, extra = {}) => ({
  op: 'addmodel',
  model: 'SpaceUser',
  data: {
    id,
    name,
    coreRole: 'Member',
    position: { $type: 'Position', x, y },
    spaceId: SPACE,
    direction: { $type: 'Direction', value: 'Right' },
    floorId: FLOOR,
    speed: { $type: 'Speed', modifier: 1 },
    userAccountId: `acct-${id}`,
    shouldBeInClusterWithFollowTarget: false,
    connected: true,
    isIdle: false,
    isBot: false,
    ...extra,
  },
});

/** The initial dump, as `FullStateChunk`. */
function fullState() {
  return {
    type: 'FullStateChunk',
    sequenceNumber: 1,
    fullStatePatches: [
      {
        op: 'addmodel',
        model: 'Connection',
        data: {
          id: 'conn-1',
          spaceId: SPACE,
          authUserId: MY_UID,
          spaceUserId: ME,
          entered: false,
          target: 'Default',
        },
      },
      {
        op: 'addmodel',
        model: 'UserAccount',
        data: { id: `acct-${ME}`, firebaseAuthId: MY_UID, email: 'me@example.com' },
      },
      spaceUser(ME, 'Me', 10, 10),
      spaceUser(THEM, 'Alex', 40, 40),
      // A recording bot: present in every real space, and never a person standing
      // next to you.
      spaceUser('bot-1', 'Recording', 48, 21, { isBot: true, type: 'RecordingClient' }),
      // Noise from the same dump, to prove irrelevant models are skipped.
      { op: 'addmodel', model: 'CatalogItem', data: { id: 'cat-1', name: 'Plant' } },
    ],
  };
}

const delta = (...patches) => ({ type: 'DeltaState', sequenceNumber: 2, patches });

function readerWithRoster() {
  const reader = new GameProtocolReader();
  reader.noteSocketUrl(
    `wss://game-router.v2.gather.town/gather-game-v2?spaceId=${SPACE}&authUserId=${MY_UID}`,
  );
  reader.ingest(fullState());
  return reader;
}

test('the Connection row identifies which space user is me', () => {
  const reader = readerWithRoster();
  assert.equal(reader.selfId, ME);
  assert.equal(reader.spaceId, SPACE);
});

test('identity also resolves via UserAccount when no Connection row arrives', () => {
  const reader = new GameProtocolReader();
  reader.authUserId = MY_UID;
  reader.ingest({
    type: 'FullStateChunk',
    fullStatePatches: [
      {
        op: 'addmodel',
        model: 'UserAccount',
        data: { id: 'acct-me', firebaseAuthId: MY_UID },
      },
      { ...spaceUser(ME, 'Me', 5, 5), data: { ...spaceUser(ME, 'Me', 5, 5).data, userAccountId: 'acct-me' } },
    ],
  });
  assert.equal(reader.selfId, ME);
});

test('heartbeats are ignored', () => {
  const reader = new GameProtocolReader();
  assert.equal(reader.ingest({ type: 'Heartbeat', timestamp: 1, origin: 'Server' }), false);
});

test('names, positions and floors come through the full state dump', () => {
  const { rows } = readerWithRoster().roster();
  const alex = rows.find((r) => r.id === THEM);
  assert.equal(alex.name, 'Alex');
  assert.equal(alex.x, 40);
  assert.equal(alex.y, 40);
  assert.equal(alex.floorId, FLOOR);
});

test('bots and recording clients are left out of the roster', () => {
  const { rows } = readerWithRoster().roster();
  assert.equal(rows.find((r) => r.id === 'bot-1'), undefined);
  assert.deepEqual(rows.map((r) => r.id).sort(), [ME, THEM].sort());
});

test('a followTargetId patch pointing at me means I am being followed', () => {
  const reader = readerWithRoster();
  const changed = reader.ingest(
    delta({ op: 'replace', model: 'SpaceUser', id: THEM, path: '/followTargetId', data: ME }),
  );
  assert.equal(changed, true);
  assert.equal(reader.roster().rows.find((r) => r.id === THEM).followTargetId, ME);
});

test('the tracker turns that patch into a "following you" event', () => {
  const reader = readerWithRoster();
  const tracker = new PresenceTracker();

  const initial = tracker.applyRoster(reader.roster());
  assert.equal(
    initial.emit.filter((e) => e.type === 'follow.started').length,
    0,
    'nobody should be reported as following me before anyone does',
  );

  reader.ingest(
    delta({ op: 'replace', model: 'SpaceUser', id: THEM, path: '/followTargetId', data: ME }),
  );

  const out = tracker.applyRoster(reader.roster());
  const follow = out.emit.find((e) => e.type === 'follow.started');
  assert.ok(follow, 'a follow.started event must be emitted');
  assert.equal(follow.followerId, THEM);
  assert.equal(follow.targetIsSelf, true);
  assert.equal(follow.confidence, 'observed', 'read from the field, not guessed from movement');
  assert.equal(follow.source, 'cdp');

  assert.deepEqual(
    tracker.snapshot().players.filter((p) => p.isFollowingMe).map((p) => p.id),
    [THEM],
  );
});

test('somebody following a third party is not reported as following me', () => {
  const reader = readerWithRoster();
  const tracker = new PresenceTracker();
  tracker.applyRoster(reader.roster());

  reader.ingest(
    delta({ op: 'replace', model: 'SpaceUser', id: THEM, path: '/followTargetId', data: ELSEWHERE }),
  );
  const out = tracker.applyRoster(reader.roster());
  assert.equal(out.emit.filter((e) => e.type === 'follow.started').length, 0);
});

test('unfollowing clears it exactly once', () => {
  const reader = readerWithRoster();
  const tracker = new PresenceTracker();
  tracker.applyRoster(reader.roster());

  reader.ingest(delta({ op: 'replace', model: 'SpaceUser', id: THEM, path: '/followTargetId', data: ME }));
  tracker.applyRoster(reader.roster());

  reader.ingest(delta({ op: 'replace', model: 'SpaceUser', id: THEM, path: '/followTargetId', data: null }));
  const out = tracker.applyRoster(reader.roster());

  const stopped = out.emit.filter((e) => e.type === 'follow.stopped');
  assert.equal(stopped.length, 1);
  assert.equal(stopped[0].followerId, THEM);

  assert.equal(
    tracker.applyRoster(reader.roster()).emit.filter((e) => e.type === 'follow.stopped').length,
    0,
  );
});

test('in-place position patches (/position/x) are applied, not dropped', () => {
  // The client mutates position component-wise, so this — not `/position` — is
  // the ordinary shape for someone walking. Reading only the last path segment
  // would drop it silently.
  const reader = readerWithRoster();
  reader.ingest(
    delta(
      { op: 'replace', model: 'SpaceUser', id: THEM, path: '/position/x', data: 11 },
      { op: 'replace', model: 'SpaceUser', id: THEM, path: '/position/y', data: 10 },
    ),
  );
  const row = reader.roster().rows.find((r) => r.id === THEM);
  assert.equal(row.x, 11);
  assert.equal(row.y, 10);
});

test('a whole-position replace (teleport) carries an ext-0 value object', () => {
  const reader = readerWithRoster();
  reader.ingest(
    delta({
      op: 'replace',
      model: 'SpaceUser',
      id: THEM,
      path: '/position',
      data: { $type: 'Position', x: 12, y: 9 },
    }),
  );
  const row = reader.roster().rows.find((r) => r.id === THEM);
  assert.equal(row.x, 12);
  assert.equal(row.y, 9);
});

test('walking up to me is reported as being next to me, and walking off again is not', () => {
  const reader = readerWithRoster();
  const tracker = new PresenceTracker();
  tracker.applyRoster(reader.roster());

  reader.ingest(
    delta(
      { op: 'replace', model: 'SpaceUser', id: THEM, path: '/position/x', data: 11 },
      { op: 'replace', model: 'SpaceUser', id: THEM, path: '/position/y', data: 10 },
    ),
  );
  const arrived = tracker.applyRoster(reader.roster());
  const entered = arrived.emit.find((e) => e.type === 'proximity.entered');
  assert.ok(entered, 'coming within a few tiles counts as standing next to me');
  assert.equal(entered.playerId, THEM);
  assert.ok(entered.distance <= 3);

  assert.equal(
    tracker.applyRoster(reader.roster()).emit.filter((e) => e.type === 'proximity.entered').length,
    0,
    'staying put must not re-announce',
  );

  reader.ingest(delta({ op: 'replace', model: 'SpaceUser', id: THEM, path: '/position/x', data: 30 }));
  const left = tracker.applyRoster(reader.roster()).emit.find((e) => e.type === 'proximity.left');
  assert.ok(left);
  assert.equal(left.playerId, THEM);
});

test('loitering at the boundary does not flap between arrived and left', () => {
  const reader = readerWithRoster();
  const tracker = new PresenceTracker();
  tracker.applyRoster(reader.roster());

  // Walk them along my own row, so the x offset *is* the distance.
  const moveTo = (x) => {
    reader.ingest(
      delta(
        { op: 'replace', model: 'SpaceUser', id: THEM, path: '/position/x', data: x },
        { op: 'replace', model: 'SpaceUser', id: THEM, path: '/position/y', data: 10 },
      ),
    );
    return tracker.applyRoster(reader.roster()).emit.filter((e) => e.type.startsWith('proximity.'));
  };

  assert.equal(moveTo(13).length, 1);
  assert.deepEqual(moveTo(14), [], 'inside the hysteresis band: still near');
  assert.deepEqual(moveTo(13), []);
  const left = moveTo(16);
  assert.equal(left.length, 1);
  assert.equal(left[0].type, 'proximity.left');
});

test('someone on another floor standing on my tile is not next to me', () => {
  const reader = readerWithRoster();
  const tracker = new PresenceTracker();
  tracker.applyRoster(reader.roster());

  reader.ingest(
    delta(
      { op: 'replace', model: 'SpaceUser', id: THEM, path: '/floorId', data: ELSEWHERE },
      { op: 'replace', model: 'SpaceUser', id: THEM, path: '/position/x', data: 10 },
      { op: 'replace', model: 'SpaceUser', id: THEM, path: '/position/y', data: 10 },
    ),
  );

  assert.equal(
    tracker.applyRoster(reader.roster()).emit.filter((e) => e.type === 'proximity.entered').length,
    0,
    'same coordinates on a different floor is not adjacency',
  );
});

test('sharing a cluster counts as standing together even at a distance', () => {
  const reader = readerWithRoster();
  const tracker = new PresenceTracker();
  tracker.applyRoster(reader.roster());

  reader.ingest(
    delta(
      { op: 'replace', model: 'SpaceUser', id: ME, path: '/clusterId', data: 'cluster-1' },
      { op: 'replace', model: 'SpaceUser', id: THEM, path: '/clusterId', data: 'cluster-1' },
    ),
  );

  const entered = tracker.applyRoster(reader.roster()).emit.find((e) => e.type === 'proximity.entered');
  assert.ok(entered);
  assert.equal(entered.confidence, 'observed');
});

test('deletemodel marks somebody as gone', () => {
  const reader = readerWithRoster();
  reader.ingest(delta({ op: 'deletemodel', model: 'SpaceUser', id: THEM }));
  assert.equal(reader.roster().rows.find((r) => r.id === THEM).connected, false);
});

test('patches for models we do not care about are skipped', () => {
  const reader = readerWithRoster();
  const before = JSON.stringify(reader.roster());
  reader.ingest(
    delta(
      { op: 'addmodel', model: 'MapArea', data: { id: 'area-1', relativeX: 3 } },
      { op: 'addmodel', model: 'BaseCombinedCalendarEvent', data: { id: 'ev-1' } },
      { op: 'replace', model: 'Space', id: SPACE, path: '/name', data: 'renamed' },
    ),
  );
  assert.equal(JSON.stringify(reader.roster()), before);
});

test('a patch into an untracked sub-field is ignored rather than guessed at', () => {
  const reader = readerWithRoster();
  const before = JSON.stringify(reader.roster());
  reader.ingest(delta({ op: 'replace', model: 'SpaceUser', id: THEM, path: '/speed/modifier', data: 2 }));
  assert.equal(JSON.stringify(reader.roster()), before);
});

test('stats expose what was seen, so an unknown envelope is visible', () => {
  const reader = readerWithRoster();
  reader.ingest({ type: 'SomethingNew', payload: { nothing: 'useful' } });
  const stats = reader.stats();
  assert.equal(stats.selfId, ME);
  assert.ok(stats.patches > 0);
  assert.equal(stats.unknownFrames, 1);
  assert.ok(stats.frameTypes.some((t) => t.startsWith('SomethingNew')));
});
