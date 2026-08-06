import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';

import { DirectCollector } from '../lib/direct.js';
import { decode, encode } from '../lib/msgpack.js';
import { encodeFrame } from '../lib/ws.js';

/**
 * A fake Gather game server.
 *
 * Test-only, like the encoder in `msgpack.test.js` used to be. `WsConnection`
 * only surfaces *text* frames — it exists to serve JSON to phones — and the game
 * protocol is binary, so the framing here is hand-rolled rather than reused.
 *
 * It speaks just enough of the real protocol to be worth testing against: the
 * handshake is recorded verbatim so assertions can check what the collector sent,
 * and state is only dumped for a connection that actually authenticated.
 */
function fakeGameServer({ requireAuth = true } = {}) {
  const connections = [];
  const server = createServer();

  server.on('upgrade', (req, socket) => {
    const key = req.headers['sec-websocket-key'];
    const accept = createHash('sha1')
      .update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
      .digest('base64');
    socket.write(
      'HTTP/1.1 101 Switching Protocols\r\n' +
        'Upgrade: websocket\r\n' +
        'Connection: Upgrade\r\n' +
        `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
    );

    const conn = { url: req.url, received: [], authenticated: false, socket };
    connections.push(conn);

    const send = (frame) => socket.write(encodeFrame(2, encode(frame)));
    // The real server heartbeats before the first state chunk, which is what
    // makes a premature "handshake rejected" verdict so tempting.
    send({ type: 'Heartbeat', timestamp: 1, origin: 'Server' });

    let buf = Buffer.alloc(0);
    socket.on('data', (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      for (;;) {
        const frame = readClientFrame(buf);
        if (!frame) break;
        buf = frame.rest;
        if (frame.opcode >= 0x8) continue; // control frames: ignore
        let decoded;
        try {
          decoded = decode(frame.payload);
        } catch {
          continue;
        }
        conn.received.push(decoded);

        if (decoded?.type === 'Authenticate') {
          conn.authenticated = decoded?.credential?.type === 'JWT' && !!decoded?.credential?.jwt;
        }
        if (decoded?.action === 'loadSpaceUser') {
          if (requireAuth && !conn.authenticated) continue; // stay silent, as Gather does
          send({ type: 'SpaceStatus', warmInGatewayServer: true });
          send({
            type: 'FullStateChunk',
            sequenceNumber: 1,
            fullStatePatches: [
              {
                op: 'addmodel',
                model: 'Connection',
                data: {
                  id: 'conn-1',
                  spaceId: 'space-1',
                  authUserId: 'uid-1',
                  spaceUserId: 'me-1',
                  entered: false,
                  target: 'OfficeView',
                },
              },
              {
                op: 'addmodel',
                model: 'SpaceUser',
                data: {
                  id: 'me-1',
                  name: 'Me',
                  position: { $type: 'Position', x: 10, y: 10 },
                  floorId: 'floor-1',
                  connected: true,
                  isBot: false,
                },
              },
              {
                op: 'addmodel',
                model: 'SpaceUser',
                data: {
                  id: 'them-1',
                  name: 'Neighbour',
                  position: { $type: 'Position', x: 11, y: 10 },
                  floorId: 'floor-1',
                  connected: true,
                  isBot: false,
                },
              },
            ],
          });
        }
      }
    });
    socket.on('error', () => {});
  });

  return {
    connections,
    listen: () =>
      new Promise((resolve) => {
        server.listen(0, '127.0.0.1', () => resolve(`ws://127.0.0.1:${server.address().port}`));
      }),
    close: () => {
      for (const c of connections) {
        try {
          c.socket.destroy();
        } catch {
          /* gone */
        }
      }
      return new Promise((resolve) => server.close(resolve));
    },
  };
}

/** Minimal masked-frame reader; returns null until a whole frame is buffered. */
function readClientFrame(buf) {
  if (buf.length < 2) return null;
  const opcode = buf[0] & 0x0f;
  let length = buf[1] & 0x7f;
  let offset = 2;
  if (length === 126) {
    if (buf.length < 4) return null;
    length = buf.readUInt16BE(2);
    offset = 4;
  } else if (length === 127) {
    if (buf.length < 10) return null;
    length = Number(buf.readBigUInt64BE(2));
    offset = 10;
  }
  if (buf.length < offset + 4 + length) return null;
  const mask = buf.subarray(offset, offset + 4);
  offset += 4;
  const payload = Buffer.from(buf.subarray(offset, offset + length));
  for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
  return { opcode, payload, rest: buf.subarray(offset + length) };
}

/**
 * A collector wired to the fake server, with auth injected.
 *
 * Nothing here reaches the network or reads the developer's adopted session:
 * `getToken` is the seam, and `spaceId` is passed explicitly so no API lookup
 * happens either.
 */
/**
 * A syntactically valid JWT carrying a chosen uid. The collector reads the uid
 * straight out of the token, so this also keeps the test from falling back to
 * whatever session the developer happens to have adopted.
 */
function fakeJwt(uid = 'uid-1') {
  const claims = Buffer.from(JSON.stringify({ user_id: uid, exp: 4e9 })).toString('base64url');
  return `eyJhbGciOiJub25lIn0.${claims}.sig`;
}

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
