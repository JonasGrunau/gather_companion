/**
 * A fake Gather game server, shared by `direct.test.js` and `bridge.test.js`.
 *
 * Not a `*.test.js` file, so `npm test` does not try to run it.
 *
 * Test-only, like the encoder in `msgpack.test.js`. `WsConnection` only surfaces
 * *text* frames — it exists to serve JSON to phones — and the game protocol is
 * binary, so the framing here is hand-rolled rather than reused.
 *
 * It speaks just enough of the real protocol to be worth testing against: the
 * handshake is recorded verbatim so assertions can check what the collector sent,
 * and state is only dumped for a connection that actually authenticated. Ids and
 * names are synthetic; the op names, envelope keys and field spellings are real.
 */

import { createHash } from 'node:crypto';
import { createServer } from 'node:http';

import { decode, encode } from '../lib/msgpack.js';
import { encodeFrame } from '../lib/ws.js';

/** The default dump: me, and one person standing one tile away. */
export function defaultPatches() {
  return [
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
    { op: 'addmodel', model: 'Space', data: { id: 'space-1', name: 'Test Space' } },
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
  ];
}

export function fakeGameServer({ requireAuth = true, patches = defaultPatches } = {}) {
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

    const send = (frame) => socket.write(encodeFrame(2, encode(frame)));
    const conn = { url: req.url, received: [], authenticated: false, socket, send };
    connections.push(conn);

    /** Push a delta after the dump, the way the real server does. */
    conn.delta = (list) => send({ type: 'DeltaState', sequenceNumber: 2, patches: list });

    /**
     * Push interaction events onto Gather's event bus.
     *
     * A real wave arrives in a `DeltaState` whose `patches` array is **empty** —
     * which is precisely why the bus went unread for so long, and so exactly what
     * a test needs to reproduce.
     */
    conn.bus = (events) =>
      send({ type: 'DeltaState', sequenceNumber: 3, patches: [], actionReturns: [], events });

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
          send({ type: 'FullStateChunk', sequenceNumber: 1, fullStatePatches: patches() });
          conn.dumped = true;
        }
      }
    });
    socket.on('error', () => {});
  });

  return {
    connections,
    /** The most recent connection, which is the one a test just triggered. */
    get latest() {
      return connections[connections.length - 1] ?? null;
    },
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

/** A `MeetingParticipant` row: an invite when `inviterId` is set. */
export function participant({
  id = 'part-1',
  spaceUserId = 'me-1',
  inviterId = null,
  meetingId = 'meeting-1',
} = {}) {
  return {
    op: 'addmodel',
    model: 'MeetingParticipant',
    data: {
      id,
      spaceUserId,
      meetingId,
      ...(inviterId ? { inviterId } : {}),
      inviteStatus: inviterId ? 'InvitedRequired' : 'NotInvited',
      createdAt: '2026-08-07T08:01:42.405Z',
    },
  };
}

/** A `MeetingJoinRequest`: somebody knocking, unanswered unless `respondedAt`. */
export function joinRequest({
  id = 'join-1',
  spaceUserId = 'them-1',
  meetingId = 'meeting-1',
  respondedAt = null,
} = {}) {
  return {
    op: 'addmodel',
    model: 'MeetingJoinRequest',
    data: {
      id,
      spaceUserId,
      meetingId,
      ...(respondedAt ? { respondedAt } : {}),
      createdAt: '2026-08-07T09:45:21.834Z',
    },
  };
}

/**
 * One `WaveEvent`, shaped exactly as captured from a live space on 2026-08-07.
 *
 * The two halves live in different places on purpose, because they do in the real
 * envelope: who waved is `payload.senderId`, and who they waved *at* is
 * `options.targetUserIds`.
 */
export function waveEvent({
  senderId = 'them-1',
  targetId = 'me-1',
  sentTime = '2026-08-07T14:22:20.563Z',
} = {}) {
  return {
    payload: { eventName: 'WaveEvent', senderId, sentTime },
    options: { targetUserIds: [targetId] },
  };
}

/**
 * A syntactically valid JWT carrying a chosen uid. Collectors read the uid
 * straight out of the token, so this also keeps tests from falling back to
 * whatever session the developer happens to have adopted.
 */
export function fakeJwt(uid = 'uid-1') {
  const claims = Buffer.from(JSON.stringify({ user_id: uid, exp: 4e9 })).toString('base64url');
  return `eyJhbGciOiJub25lIn0.${claims}.sig`;
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
