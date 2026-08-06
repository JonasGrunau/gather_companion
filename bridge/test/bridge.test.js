import assert from 'node:assert/strict';
import { appendFileSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, test } from 'node:test';

import { BridgeServer } from '../lib/server.js';

const TOKEN = 'test-token';
const PLAYER = '1652d4a7-7874-4c66-b571-d55d00205705';
const OTHER = '8f242bda-b348-4eb0-bb0f-68e3699c116f';

/** Real log lines, with the timestamp templated so we can order them. */
const line = {
  near: (id) =>
    `[2026-07-31 12:18:47.199] [verbose] (webapp)                       GameMediaController.remoteParticipantJoinedHandler ${id} [object Object] [object Object]`,
  away: (id) =>
    `[2026-07-31 12:30:29.740] [verbose] (webapp)                       GameMediaController.remoteParticipantLeftHandler ${id}`,
  joined: (id) =>
    `[2026-07-31 12:09:15.548] [verbose] (webapp)                      [PlayerManagerV2] Player has joined ${id}`,
  screenOn: (id) =>
    `[2026-07-31 12:07:07.376] [verbose] (webapp)                       GameMediaController.remoteParticipantTrackStateChangedHandler setStreamPausedState ${id} screen false`,
  micOff: (id) =>
    `[2026-07-31 12:07:07.376] [verbose] (webapp)                       GameMediaController.remoteParticipantTrackStateChangedHandler setStreamPausedState ${id} audio true`,
};

let server;
let logPath;
let port;

before(async () => {
  const dir = mkdtempSync(join(tmpdir(), 'gather-bridge-test-'));
  logPath = join(dir, 'main.log');
  writeFileSync(logPath, 'pre-existing history that must not be replayed\n');

  server = new BridgeServer({
    token: TOKEN,
    port: 0, // ask the OS for a free port
    cdpPort: 1, // nothing listens here; the CDP collector stays down on purpose
    logSource: logPath,
    log: () => {},
  });
  await server.start();
  port = server._http.address().port;
});

after(async () => {
  await server?.stop();
});

/** Opens a client and collects frames until `done` is satisfied or we time out. */
function collect({ done, timeoutMs = 6000, since = 0 }) {
  return new Promise((resolve, reject) => {
    const url = `ws://127.0.0.1:${port}/ws?token=${TOKEN}${since ? `&since=${since}` : ''}`;
    const ws = new WebSocket(url);
    const frames = [];
    const timer = setTimeout(() => {
      ws.close();
      reject(new Error(`timed out; got ${JSON.stringify(frames.map((f) => f.event?.type ?? f.kind))}`));
    }, timeoutMs);

    ws.addEventListener('message', (event) => {
      frames.push(JSON.parse(String(event.data)));
      if (done(frames)) {
        clearTimeout(timer);
        ws.close();
        resolve(frames);
      }
    });
    ws.addEventListener('error', (err) => {
      clearTimeout(timer);
      reject(new Error(`websocket error: ${err?.message ?? 'unknown'}`));
    });
  });
}

const eventsOf = (frames) => frames.filter((f) => f.kind === 'event').map((f) => f.event);

/** `OTHER`'s row inside a snapshot frame, when it is there yet. */
const playerIn = (frame) => frame.snapshot?.players?.find((p) => p.id === OTHER);

test('unauthenticated clients are rejected', async () => {
  const res = await fetch(`http://127.0.0.1:${port}/state`);
  assert.equal(res.status, 401);

  const rejected = await new Promise((resolve) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?token=wrong`);
    ws.addEventListener('error', () => resolve(true));
    ws.addEventListener('close', () => resolve(true));
    ws.addEventListener('open', () => resolve(false));
  });
  assert.equal(rejected, true);
});

test('health needs no token but says nothing sensitive', async () => {
  const body = await (await fetch(`http://127.0.0.1:${port}/health`)).json();
  assert.equal(body.name, 'gather-app-bridge');
  assert.equal(body.token, undefined);
});

test('a connecting client is given a snapshot first', async () => {
  const frames = await collect({ done: (f) => f.length >= 1 });
  assert.equal(frames[0].kind, 'snapshot');
  assert.equal(frames[0].snapshot.type, 'presence.snapshot');
  assert.ok(Array.isArray(frames[0].snapshot.players));
});

test('someone arriving next to you is delivered live', async () => {
  const pending = collect({
    done: (f) => eventsOf(f).some((e) => e.type === 'proximity.entered'),
  });
  // Give the tailer a moment to attach before writing.
  await new Promise((r) => setTimeout(r, 250));
  appendFileSync(logPath, `${line.near(PLAYER)}\n`);

  const events = eventsOf(await pending);
  const arrival = events.find((e) => e.type === 'proximity.entered');
  assert.equal(arrival.playerId, PLAYER);
  assert.equal(arrival.confidence, 'inferred');
});

test('repeated arrivals for the same person are not delivered twice', async () => {
  await new Promise((r) => setTimeout(r, 250));
  // PLAYER is already near from the previous test; two more arrivals are noise.
  appendFileSync(logPath, `${line.near(PLAYER)}\n${line.near(PLAYER)}\n${line.near(OTHER)}\n`);

  const frames = await collect({
    done: (f) => eventsOf(f).some((e) => e.type === 'proximity.entered' && e.playerId === OTHER),
  });
  const arrivals = eventsOf(frames).filter((e) => e.type === 'proximity.entered');
  assert.deepEqual(
    arrivals.map((a) => a.playerId),
    [OTHER],
    'only the state change should be published',
  );
});

test('the snapshot tracks who is currently next to you', async () => {
  const state = await (await fetch(`http://127.0.0.1:${port}/state?token=${TOKEN}`)).json();
  const near = state.players.filter((p) => p.isNear).map((p) => p.id).sort();
  assert.deepEqual(near, [PLAYER, OTHER].sort());

  const withTimestamp = state.players.find((p) => p.id === PLAYER);
  assert.ok(withTimestamp.nearSince, 'we should know since when they have been there');
});

test('leaving clears proximity', async () => {
  const pending = collect({
    done: (f) => eventsOf(f).some((e) => e.type === 'proximity.left' && e.playerId === PLAYER),
  });
  await new Promise((r) => setTimeout(r, 250));
  appendFileSync(logPath, `${line.away(PLAYER)}\n`);
  await pending;

  const state = await (await fetch(`http://127.0.0.1:${port}/state?token=${TOKEN}`)).json();
  assert.equal(state.players.find((p) => p.id === PLAYER).isNear, false);
});

test('subscribing to a neighbour\'s tracks is not a screen share', async () => {
  const pending = collect({
    done: (f) =>
      f.some((x) => x.kind === 'snapshot' && playerIn(x)?.micOn === false),
  });
  await new Promise((r) => setTimeout(r, 250));
  appendFileSync(logPath, `${line.micOff(OTHER)}\n${line.screenOn(OTHER)}\n`);

  const media = eventsOf(await pending).filter((e) => e.type === 'media.changed');
  assert.deepEqual(
    media.map((m) => m.track),
    [],
    'a mute is state and not news, and an unpaused track is neither',
  );

  const state = await (await fetch(`http://127.0.0.1:${port}/state?token=${TOKEN}`)).json();
  const player = state.players.find((p) => p.id === OTHER);
  assert.equal(player.micOn, false, 'the mute still has to be recorded in state');
  // Gather unpauses audio, video and screen together the moment it subscribes to
  // someone who came near, and never logs the matching pause. Across every such
  // line in two real logs the video and screen track sets were the same 17
  // people, so `screen false` says "we subscribed", not "they are sharing".
  assert.equal(player.screensharing, false);
});

test('a reconnecting client can replay what it missed', async () => {
  const before = await (await fetch(`http://127.0.0.1:${port}/state?token=${TOKEN}`)).json();
  await new Promise((r) => setTimeout(r, 250));
  appendFileSync(logPath, `${line.joined('11111111-2222-3333-4444-555555555555')}\n`);

  // Wait for it to land in history.
  await collect({ done: (f) => eventsOf(f).some((e) => e.type === 'player.joinedSpace') });

  const replayed = await collect({
    since: before.seq,
    done: (f) => eventsOf(f).some((e) => e.type === 'player.joinedSpace'),
  });
  const seqs = replayed.filter((f) => f.kind === 'event').map((f) => f.seq);
  assert.ok(
    seqs.every((s) => s > before.seq),
    'replay must not resend events the client already had',
  );
});

test('the raw channel shows what the filtered stream suppresses', async () => {
  // Muting is recorded as state but deliberately not published — mics flicker
  // constantly. A raw subscriber should still see it, because "what can this
  // thing actually see" has to be answerable.
  const raw = [];
  const filtered = [];

  const open = (query, sink) =>
    new Promise((resolve) => {
      const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?token=${TOKEN}${query}`);
      ws.addEventListener('message', (event) => {
        const frame = JSON.parse(String(event.data));
        if (frame.event) sink.push({ kind: frame.kind, type: frame.event.type, track: frame.event.track });
      });
      ws.addEventListener('open', () => resolve(ws));
    });

  const rawWs = await open('&raw=1', raw);
  const filteredWs = await open('', filtered);
  await new Promise((r) => setTimeout(r, 250));

  // A mute followed by a screen share: only the second is newsworthy.
  appendFileSync(logPath, `${line.micOff(PLAYER)}\n`);
  await new Promise((r) => setTimeout(r, 900));

  rawWs.close();
  filteredWs.close();

  const rawAudio = raw.filter((e) => e.type === 'media.changed' && e.track === 'audio');
  const filteredAudio = filtered.filter((e) => e.type === 'media.changed' && e.track === 'audio');

  assert.equal(rawAudio.length, 1, 'the firehose must include the mute');
  assert.equal(rawAudio[0].kind, 'raw', 'and mark it as raw so it is distinguishable');
  assert.equal(filteredAudio.length, 0, 'the normal stream must not');
});

test('the CDP collector reports itself as down rather than pretending', async () => {
  const body = await (await fetch(`http://127.0.0.1:${port}/collectors?token=${TOKEN}`)).json();
  assert.equal(body.health.cdp, false);
  assert.equal(body.health.logTail, true);
  assert.match(body.cdpDetail ?? '', /unreachable|not found|closed/i);
});
