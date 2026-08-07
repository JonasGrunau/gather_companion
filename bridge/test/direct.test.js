import assert from 'node:assert/strict';
import { after, test } from 'node:test';

import { DirectCollector } from '../lib/direct.js';
import { decode, encode } from '../lib/msgpack.js';
import { fakeGameServer, fakeJwt } from './fake-gather.js';

/**
 * A collector wired to the fake server, with auth injected.
 *
 * Nothing here reaches the network or reads the developer's adopted session:
 * `getToken` is the seam, and `spaceId` is passed explicitly so no API lookup
 * happens either.
 */
async function startCollector({ requireAuth = true, token = fakeJwt() } = {}) {
  const fake = fakeGameServer({ requireAuth });
  servers.push(fake);
  const socketUrl = await fake.listen();

  const collector = new DirectCollector({
    socketUrl,
    spaceId: 'space-1',
    getToken: async () => token,
    log: () => {},
  });
  collectors.push(collector);
  return { fake, collector };
}

/** Resolves on the first roster the collector publishes, or rejects on timeout. */
function firstRoster(collector, ms = 5000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('no roster within timeout')), ms);
    collector.once('roster', (roster) => {
      clearTimeout(timer);
      resolve(roster);
    });
  });
}

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

const servers = [];
const collectors = [];
after(async () => {
  for (const c of collectors) c.stop();
  for (const s of servers) await s.close();
});

test('connects as an observer and publishes a roster from the state dump', async () => {
  const { fake, collector } = await startCollector();
  const rosterPromise = firstRoster(collector);
  collector.start();

  const { selfId, rows } = await rosterPromise;

  assert.equal(selfId, 'me-1', 'self is resolved from the Connection row');
  assert.deepEqual(
    rows.map((r) => r.name).sort(),
    ['Me', 'Neighbour'],
    'both space users reach the roster with their names',
  );
  assert.equal(collector.hasState, true);
  assert.equal(collector.healthy, true);

  const sent = fake.connections[0].received.map((f) => f.type ?? f.action);
  assert.ok(sent.includes('Authenticate'));
  assert.ok(!sent.includes('enterSpace'), 'the collector must never enter the space');

  const connectUrl = fake.connections[0].url;
  assert.match(connectUrl, /spaceId=space-1/);
});

test('a steady connection stops announcing itself once it is up', async () => {
  // Regression: the health detail used to carry a frame counter, so it changed on
  // every 250ms flush and published a `bridge.status` event each time. Left alone
  // that fills the 500-event history the phone replays on reconnect with status
  // noise, evicting the events worth catching up on within minutes.
  const { collector } = await startCollector();
  const statuses = [];
  collector.on('status', (s) => statuses.push(s));

  const rosterPromise = firstRoster(collector);
  collector.start();
  await rosterPromise;
  await wait(400); // let the healthy status land
  const settled = statuses.length;
  await wait(1200); // several publish intervals

  assert.equal(statuses.length, settled, 'a connection that has not changed says nothing');
  assert.match(collector.detail, /space users/);
  assert.ok(!/frames/.test(collector.detail), 'the frame counter must stay out of the detail');
});

test('a rejected handshake is reported as connected-but-no-state, not as healthy', async () => {
  // The fake server mirrors Gather here: a connection that did not authenticate
  // gets silence, not an error. That silence is the failure mode most likely to
  // be misread as a network problem.
  const { collector } = await startCollector({ requireAuth: true, token: '' });
  collector.start();
  await wait(300);

  assert.equal(collector.hasState, false);
  assert.equal(collector.healthy, false, 'no state must never read as healthy');
});

test('reconnecting replaces the roster instead of accumulating ghosts', async () => {
  // The reason resync() is trivial here: every connection replays the full dump,
  // so a fresh reader per connection is both correct and necessary — carrying rows
  // over would keep people who have since left.
  const { fake, collector } = await startCollector();
  await firstRoster(collector, 5000).catch(() => {});
  collector.start();
  await firstRoster(collector, 5000);
  const firstReader = collector.reader;

  const again = firstRoster(collector, 5000);
  await collector.resync();
  const { rows } = await again;

  assert.notEqual(collector.reader, firstReader, 'a new connection gets a new reader');
  assert.equal(rows.length, 2, 'still exactly the two real users, not four');
  assert.ok(fake.connections.length >= 2, 'resync opened a second connection');
  assert.equal(collector.stats().connects >= 2, true);
});

test('the handshake carries the token in credential.jwt and never enters the space', () => {
  const collector = new DirectCollector({ log: () => {} });
  const frames = collector._handshake('tok-123', 'space-1');
  const types = frames.map((f) => f.type);

  assert.deepEqual(types, ['Authenticate', 'ConnectToSpace', 'Subscribe', 'Action']);

  const auth = frames[0];
  assert.deepEqual(
    auth.credential,
    { type: 'JWT', jwt: 'tok-123' },
    'a flat token field is ignored by Gather in silence — the wrapper is required',
  );
  assert.equal(auth.token, undefined, 'no flat token field should be sent');

  assert.deepEqual(frames[1], { type: 'ConnectToSpace', spaceId: 'space-1' });
  assert.deepEqual(frames[2], { type: 'Subscribe' }, 'Subscribe takes no arguments');

  const action = frames[3];
  assert.equal(action.action, 'loadSpaceUser');
  assert.equal(action.args[0], 'SpaceUser');
  assert.deepEqual(action.args[2], {
    connectionTarget: 'OfficeView',
    clientPlatform: 'Desktop',
  });
  assert.equal(typeof action.txnId, 'string');
});

test('no handshake frame ever calls enterSpace, whatever the options', () => {
  // `enterSpace` was measured harmless to the user's own session (2026-08-06), so
  // this is no longer a safety property — it is a hygiene one. Entering bumps
  // `numTimesEnteredSpace` on every reconnect and marks the user present. A
  // read-only collector must not do either, so the action stays unreachable.
  for (const opts of [{}, { spaceId: 'space-1' }, { spaceId: null }]) {
    const collector = new DirectCollector({ ...opts, log: () => {} });
    const actions = collector._handshake('tok', 'space-1').map((f) => f.action);
    assert.ok(!actions.includes('enterSpace'), 'observer mode must never enter the space');
  }
});

test('every handshake frame survives the real encoder', () => {
  const collector = new DirectCollector({ log: () => {} });
  // A realistically sized ID token: this is the frame that would break silently
  // if the encoder picked a string header too small for it.
  const token = `ey${'x'.repeat(1200)}`;
  for (const frame of collector._handshake(token, 'space-1')) {
    assert.deepEqual(decode(encode(frame)), frame);
  }
});

test('the collector reports unhealthy while it holds no state', () => {
  const collector = new DirectCollector({ log: () => {} });
  assert.equal(collector.healthy, false);
  assert.equal(collector.hasState, false, 'an empty roster must never read as healthy');
  assert.equal(collector.stats().entered, false, 'stats must state that we did not enter');
});
