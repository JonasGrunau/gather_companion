import assert from 'node:assert/strict';
import { appendFileSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, test } from 'node:test';

import { BridgeServer } from '../lib/server.js';
import { SAFE_TILES } from '../lib/party.js';
import { PushNotifier, PushRegistry } from '../lib/push.js';
import { defaultPatches, fakeGameServer, fakeJwt } from './fake-gather.js';

const TOKEN = 'test-token';
const ME = 'me-1';
const NEIGHBOUR = 'them-1';

/**
 * Real notification lines, verbatim from `~/Library/Logs/GatherV2/main.log`, with
 * the uuid replaced. These three types are everything Gather's client raises.
 */
const line = {
  wave: () =>
    "[2026-08-07 10:01:39.265] [info]  (main)                        IPC Event: SHOW_NOTIFICATION { type: 'wave' }",
  waveShown: () =>
    '[2026-08-07 10:01:39.266] [info]  (main)                        Showing notification 62c41002-9661-4429-b66e-ae369f83e916: wave',
  invite: () =>
    "[2026-08-07 10:01:42.466] [info]  (main)                        IPC Event: SHOW_NOTIFICATION { type: 'meeting invite' }",
  suppressed: () =>
    '[2026-08-07 10:02:20.131] [info]  (main)                        Notification suppressed: App window is focused',
  noise: () =>
    '[2026-08-07 10:01:40.814] [info]  (main)                        AppView: blur',
};

let server;
let gather;
let logPath;
let port;

/**
 * Every push the server tried to send. The sender is a fake and the registry is
 * in memory, so this suite can never reach Google or read the developer's real
 * device list — which, on a machine where push is set up, would mean firing real
 * notifications at a real phone during `npm test`.
 */
const pushes = [];
let pushConfig = {};

before(async () => {
  const dir = mkdtempSync(join(tmpdir(), 'gather-bridge-test-'));
  logPath = join(dir, 'main.log');
  writeFileSync(logPath, 'pre-existing history that must not be replayed\n');

  gather = fakeGameServer();
  const socketUrl = await gather.listen();

  const registry = new PushRegistry({
    read: () => pushConfig,
    write: (next) => (pushConfig = next),
  });

  server = new BridgeServer({
    token: TOKEN,
    port: 0, // ask the OS for a free port
    push: new PushNotifier({
      sender: { send: async (note) => (pushes.push(note), { ok: true }) },
      registry,
    }),
    // Both seams point at the local fake. Tests must never leave the machine: a
    // suite whose result depends on whether the developer has run `adopt` is
    // broken, however green it looks.
    socketUrl,
    getToken: async () => fakeJwt(),
    spaceId: 'space-1',
    logSource: logPath,
    log: () => {},
  });
  await server.start();
  port = server._http.address().port;
});

after(async () => {
  await server?.stop();
  await gather?.close();
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
const state = async () =>
  (await fetch(`http://127.0.0.1:${port}/state?token=${TOKEN}`)).json();
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

/** Waits until the state dump has been consumed, so tests start from a roster. */
async function ready() {
  for (let i = 0; i < 60; i++) {
    const snapshot = await state();
    if (snapshot.players?.length) return snapshot;
    await wait(100);
  }
  throw new Error('the collector never produced a roster');
}

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

test('the state dump becomes a roster with names, positions and the space name', async () => {
  const snapshot = await ready();
  const neighbour = snapshot.players.find((p) => p.id === NEIGHBOUR);

  assert.equal(neighbour.name, 'Neighbour', 'names come straight off SpaceUser');
  assert.equal(neighbour.x, 11);
  assert.equal(neighbour.isNear, true, 'one tile away is standing next to you');
  assert.equal(snapshot.self.spaceName, 'Test Space', 'read from the Space model');
  assert.ok(
    !snapshot.players.some((p) => p.id === ME),
    'my own row is self, not a player standing next to me',
  );
});

test('walking away is delivered live as proximity.left', async () => {
  await ready();
  const pending = collect({
    done: (f) => eventsOf(f).some((e) => e.type === 'proximity.left'),
  });
  await wait(100);
  gather.latest.delta([
    { op: 'replace', model: 'SpaceUser', id: NEIGHBOUR, path: '/position/x', data: 40 },
  ]);

  const left = eventsOf(await pending).find((e) => e.type === 'proximity.left');
  assert.equal(left.playerId, NEIGHBOUR);
  assert.equal((await state()).players.find((p) => p.id === NEIGHBOUR).isNear, false);
});

test('a component-wise walk back is delivered as proximity.entered', async () => {
  // `/position/x` rather than `/position`: position mutates in place, so reading
  // only the last path segment would silently drop every walking patch.
  const pending = collect({
    done: (f) => eventsOf(f).some((e) => e.type === 'proximity.entered'),
  });
  await wait(100);
  gather.latest.delta([
    { op: 'replace', model: 'SpaceUser', id: NEIGHBOUR, path: '/position/x', data: 11 },
  ]);

  const arrived = eventsOf(await pending).find((e) => e.type === 'proximity.entered');
  assert.equal(arrived.playerId, NEIGHBOUR);
  assert.equal(arrived.source, 'gather');
});

test('someone pointing followTargetId at me is reported as following me', async () => {
  const pending = collect({
    done: (f) => eventsOf(f).some((e) => e.type === 'follow.started'),
  });
  await wait(100);
  gather.latest.delta([
    { op: 'replace', model: 'SpaceUser', id: NEIGHBOUR, path: '/followTargetId', data: ME },
  ]);

  const followed = eventsOf(await pending).find((e) => e.type === 'follow.started');
  assert.equal(followed.followerId, NEIGHBOUR);
  assert.equal(followed.targetIsSelf, true);
  assert.equal(followed.confidence, 'observed', 'the field is read, never guessed');
});

test('voice activity reaches the snapshot but is never an event', async () => {
  // `speaking` is the most frequent patch on a live socket. As a feed line it
  // would be unreadable; as state it is exactly what the app wants.
  gather.latest.delta([
    { op: 'replace', model: 'SpaceUser', id: NEIGHBOUR, path: '/speaking', data: true },
  ]);
  for (let i = 0; i < 40; i++) {
    if ((await state()).players.find((p) => p.id === NEIGHBOUR)?.speaking) break;
    await wait(50);
  }
  assert.equal((await state()).players.find((p) => p.id === NEIGHBOUR).speaking, true);

  const events = (await (await fetch(`http://127.0.0.1:${port}/events?token=${TOKEN}`)).json())
    .events;
  assert.ok(
    !events.some((e) => e.event.type?.includes('speak')),
    'voice activity must not reach the feed',
  );
});

test('a wave in the desktop log is delivered as a notification', async () => {
  // The one thing still scraped, because it exists in no Gather model — and the
  // single event most worth waking a phone for.
  const pending = collect({
    done: (f) => eventsOf(f).some((e) => e.type === 'notification.shown'),
  });
  await wait(250);
  appendFileSync(logPath, `${line.noise()}\n${line.wave()}\n${line.waveShown()}\n`);

  const shown = eventsOf(await pending).filter((e) => e.type === 'notification.shown');
  assert.equal(shown.length, 1, 'the IPC line and the "Showing" line are one notification');
  assert.equal(shown[0].notificationType, 'wave');
});

test('a notification Gather suppressed still reaches the phone', async () => {
  // Gather drops its own when its window has focus, so no "Showing notification"
  // line follows. The phone is a different device and should still be told.
  const pending = collect({
    done: (f) =>
      eventsOf(f).some(
        (e) => e.type === 'notification.shown' && e.notificationType === 'meeting invite',
      ),
  });
  await wait(250);
  appendFileSync(logPath, `${line.invite()}\n${line.suppressed()}\n`);
  await pending;
});

test('a reconnecting client can replay what it missed', async () => {
  const before = await state();
  await wait(250);
  appendFileSync(logPath, `${line.wave()}\n`);

  await collect({ done: (f) => eventsOf(f).some((e) => e.type === 'notification.shown') });

  const replayed = await collect({
    since: before.seq,
    done: (f) => eventsOf(f).some((e) => e.type === 'notification.shown'),
  });
  const seqs = replayed.filter((f) => f.kind === 'event').map((f) => f.seq);
  assert.ok(
    seqs.every((s) => s > before.seq),
    'replay must not resend events the client already had',
  );
});

test('the raw channel shows what the filtered stream suppresses', async () => {
  // Someone shuffling about next to you is state, not news, so `player.moved`
  // is published but the tracker keeps plenty else to itself. A raw subscriber
  // should still see the firehose, because "what can this thing actually see"
  // has to be answerable.
  const raw = [];
  const filtered = [];

  const open = (query, sink) =>
    new Promise((resolve) => {
      const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?token=${TOKEN}${query}`);
      ws.addEventListener('message', (event) => {
        const frame = JSON.parse(String(event.data));
        if (frame.event) sink.push({ kind: frame.kind, type: frame.event.type });
      });
      ws.addEventListener('open', () => resolve(ws));
    });

  const rawWs = await open('&raw=1', raw);
  const filteredWs = await open('', filtered);
  await wait(250);

  appendFileSync(logPath, `${line.wave()}\n`);
  await wait(900);

  rawWs.close();
  filteredWs.close();

  assert.ok(
    raw.some((e) => e.type === 'notification.shown' && e.kind === 'raw'),
    'the firehose must include it, marked raw so it is distinguishable',
  );
});

test('the collectors endpoint names what is actually connected', async () => {
  const body = await (await fetch(`http://127.0.0.1:${port}/collectors?token=${TOKEN}`)).json();
  assert.equal(body.health.gather, true, 'the Gather socket is the presence source');
  assert.equal(
    body.health.cdp,
    true,
    'mirrored onto the old name so app builds predating this still show rich data',
  );
  assert.equal(body.health.logTail, true, 'the notification tail is separate and optional');
  assert.equal(body.stats.entered, false, 'we observe the space, we never enter it');
  assert.equal(body.stats.users, defaultPatches().filter((p) => p.model === 'SpaceUser').length);
});

// ---- party mode -------------------------------------------------------------

test('party mode teleports on the wire, and only to a tile nobody is near', async () => {
  await ready();
  // Park the neighbour at the far end. This is what makes anywhere safe: with
  // them one tile away, every tile the bridge knows about is inside the
  // clearance and party mode is right to sit still.
  gather.latest.delta([
    { op: 'replace', model: 'SpaceUser', id: NEIGHBOUR, path: '/position/x', data: 90 },
  ]);
  await wait(400);

  const on = await (
    await fetch(`http://127.0.0.1:${port}/party?on=1&token=${TOKEN}`, { method: 'POST' })
  ).json();
  assert.equal(on.active, true);
  assert.equal(on.ok, true);

  await wait(400);

  const teleports = gather.latest.received.filter((f) => f.action === 'teleport');
  assert.ok(teleports.length > 0, 'the Action must actually reach Gather');

  const [model, id, payload] = teleports[0].args;
  assert.equal(model, 'SpaceUser');
  assert.equal(id, ME, 'we move our own avatar and nobody else');
  assert.equal(typeof payload.x, 'number', 'flat x/y — {position:{x,y}} is rejected');
  assert.ok(payload.direction, 'required even when teleporting');

  // The promise the feature rests on: never within the clearance of someone who
  // is actually here.
  for (const frame of teleports) {
    const { x, y } = frame.args[2];
    assert.ok(Math.hypot(x - 90, y - 10) >= SAFE_TILES, `hopped to ${x},${y} — too close`);
  }

  const snapshot = await state();
  assert.equal(snapshot.party.active, true, 'the phone learns about it from the snapshot');
  assert.ok(snapshot.party.hops > 0);

  const off = await (
    await fetch(`http://127.0.0.1:${port}/party?on=0&token=${TOKEN}`, { method: 'POST' })
  ).json();
  assert.equal(off.active, false);

  const settled = gather.latest.received.filter((f) => f.action === 'teleport').length;
  await wait(300);
  assert.equal(
    gather.latest.received.filter((f) => f.action === 'teleport').length,
    settled,
    'switching it off stops the hopping',
  );
});

// ---- push -------------------------------------------------------------------

test('a phone can register for pushes, and then gets woken by a wave', async () => {
  // The point of push: this has to work when the app is not running, so it
  // cannot depend on the WebSocket that carries everything else.
  const token = 'f'.repeat(64);
  const res = await fetch(`http://127.0.0.1:${port}/push/register?token=${TOKEN}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ token, platform: 'ios' }),
  });
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { ok: true, devices: 1, sending: true });

  pushes.length = 0;
  await wait(250);
  appendFileSync(logPath, `${line.wave()}\n`);
  for (let i = 0; i < 40 && pushes.length === 0; i++) await wait(50);

  assert.equal(pushes.length, 1, 'a wave must reach a phone that is not listening');
  assert.equal(pushes[0].token, token);
  assert.equal(pushes[0].title, 'Someone waved at you');
  assert.equal(pushes[0].collapseId, 'gather-wave');
});

test('registering without a plausible token is refused', async () => {
  const res = await fetch(`http://127.0.0.1:${port}/push/register?token=${TOKEN}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ token: 'short' }),
  });
  assert.equal(res.status, 400);
});

test('push registration needs the pairing token like everything else', async () => {
  const res = await fetch(`http://127.0.0.1:${port}/push/register?token=wrong`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ token: 'g'.repeat(64) }),
  });
  assert.equal(res.status, 401);
});

test('a busy room does not push, because proximity is opt-in', async () => {
  // Moving people around generates proximity events constantly; none of them
  // should reach a lock screen unless the reason is explicitly enabled.
  pushes.length = 0;
  gather.latest.delta([
    { op: 'replace', model: 'SpaceUser', id: NEIGHBOUR, path: '/position/x', data: 60 },
  ]);
  await wait(400);
  gather.latest.delta([
    { op: 'replace', model: 'SpaceUser', id: NEIGHBOUR, path: '/position/x', data: 11 },
  ]);
  await wait(400);

  assert.deepEqual(pushes, []);
});
