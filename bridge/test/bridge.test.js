import assert from 'node:assert/strict';
import { appendFileSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, test } from 'node:test';

import { BridgeServer } from '../lib/server.js';
import { PushNotifier, PushRegistry } from '../lib/push.js';
import { defaultPatches, fakeGameServer, fakeJwt, waveEvent } from './fake-gather.js';

const TOKEN = 'test-token';
const ME = 'me-1';
const NEIGHBOUR = 'them-1';

/**
 * Real notification lines, verbatim from `~/Library/Logs/GatherV2/main.log`, with
 * the uuid replaced. These three types are everything Gather's client raises.
 *
 * `wave` is kept only to prove it is now *ignored* here: waves come off the game
 * socket's event bus instead (see `waveEvent`), which names the sender and does not
 * need the desktop app running at all.
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
    // Never the real reader: its default would put the developer's live Gather
    // refresh token into this suite's assertions.
    gatherSession: () => ({ refreshToken: 'refresh-for-the-phone', uid: 'uid-1' }),
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
/** Everything in the server's replay buffer, for asserting that nothing was added. */
const eventsSoFar = async () =>
  (await (await fetch(`http://127.0.0.1:${port}/events?token=${TOKEN}`)).json()).events;
/** One token-gated GET, decoded. */
const getJson = async (path) =>
  (await fetch(`http://127.0.0.1:${port}${path}?token=${TOKEN}`)).json();
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

test('the state dump becomes a roster with names and the space name', async () => {
  const snapshot = await ready();
  const neighbour = snapshot.players.find((p) => p.id === NEIGHBOUR);

  assert.equal(neighbour.name, 'Neighbour', 'names come straight off SpaceUser');
  assert.equal(neighbour.isFollowingMe, false, 'nobody is following yet');
  assert.equal(snapshot.self.spaceName, 'Test Space', 'read from the Space model');
  assert.ok(
    !snapshot.players.some((p) => p.id === ME),
    'my own row is self, not one of the people around me',
  );
});

test('walking about the space is not news', async () => {
  // Positions are still decoded and still sent in the roster — the app’s party mode
  // needs them — but they are not news, so they reach no feed.
  // This is the whole removal in one assertion.
  await ready();
  const before = (await eventsSoFar()).length;
  gather.latest.delta([
    { op: 'replace', model: 'SpaceUser', id: NEIGHBOUR, path: '/position/x', data: 40 },
  ]);
  await wait(400);
  gather.latest.delta([
    { op: 'replace', model: 'SpaceUser', id: NEIGHBOUR, path: '/position/x', data: 11 },
  ]);
  await wait(400);

  assert.equal((await eventsSoFar()).length, before, 'walking produces no events at all');
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

test('a wave on the game socket becomes a notification that names the sender', async () => {
  // The event bus, which nobody read for weeks: a `DeltaState` whose `patches`
  // array is empty and whose `events` array holds the wave. It arrives with a
  // `senderId`, which the log-scraped version never had.
  const pending = collect({
    done: (f) => eventsOf(f).some((e) => e.type === 'notification.shown'),
  });
  await wait(250);
  gather.latest.bus([waveEvent({ senderId: NEIGHBOUR, targetId: ME })]);

  const shown = eventsOf(await pending).filter((e) => e.type === 'notification.shown');
  assert.equal(shown.length, 1);
  assert.equal(shown[0].notificationType, 'wave');
  assert.equal(shown[0].senderId, NEIGHBOUR, 'the phone can say who waved');
  assert.equal(shown[0].source, 'gather', 'no longer scraped');
  assert.equal(shown[0].at, '2026-08-07T14:22:20.563Z', "the sender's own clock, not ours");
});

test('a wave aimed at somebody else is not reported', async () => {
  // `options.targetUserIds` is the server's own routing. Reporting every wave in
  // the space would be worse than reporting none — the same stance `presence.js`
  // takes on being followed when it does not know which row is ours.
  const before = await state();
  gather.latest.bus([waveEvent({ senderId: NEIGHBOUR, targetId: 'someone-else' })]);
  await wait(400);

  const after = await state();
  assert.equal(after.seq, before.seq, 'nothing was published');
});

test('a wave in the desktop log is ignored, because the socket already reported it', async () => {
  // Both sources would otherwise fire for one wave, and the log is always second.
  const before = await state();
  appendFileSync(logPath, `${line.noise()}\n${line.wave()}\n${line.waveShown()}\n`);
  await wait(600);

  const after = await state();
  assert.equal(after.seq, before.seq, 'the log path must stay silent about waves');
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
  appendFileSync(logPath, `${line.invite()}\n`);

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
  // The tracker keeps most of what it sees to itself — roster churn, voice
  // activity, everyone walking around. A raw subscriber should still see the
  // firehose, because "what can this thing actually see" has to be answerable.
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

  appendFileSync(logPath, `${line.invite()}\n`);
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
  // A sender the roster does not know, because `them-1` has already waved in this
  // suite and is inside its cooldown. An unknown sender also exercises the
  // fallback wording, which is what a wave looked like before it had a sender.
  gather.latest.bus([waveEvent({ senderId: 'stranger-1', targetId: ME })]);
  for (let i = 0; i < 40 && pushes.length === 0; i++) await wait(50);

  assert.equal(pushes.length, 1, 'a wave must reach a phone that is not listening');
  assert.equal(pushes[0].token, token);
  assert.equal(pushes[0].title, 'Someone waved at you');
  assert.equal(
    pushes[0].collapseId,
    'gather-wave-stranger-1',
    'collapsed per sender, so two people waving do not overwrite each other',
  );
});

test('the same person waving repeatedly is reported once', async () => {
  // Measured on a live space: one person produced 41 `WaveEvent`s in eight seconds.
  // A wave is a decision; the wave *button* is not.
  const before = await state();
  for (let i = 0; i < 5; i++) gather.latest.bus([waveEvent({ senderId: NEIGHBOUR, targetId: ME })]);
  await wait(600);

  const after = await state();
  assert.equal(after.seq, before.seq, 'already inside the cooldown from the earlier wave');
});

test('registering without a plausible token is refused', async () => {
  const res = await fetch(`http://127.0.0.1:${port}/push/register?token=${TOKEN}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ token: 'short' }),
  });
  assert.equal(res.status, 400);
});

test('claiming a code hands over both credentials', async () => {
  // The phone needs two things and they are not interchangeable: the bridge token,
  // which lets it register for pushes on this LAN, and the *Gather* refresh token,
  // which lets it read presence itself without this computer being involved at all.
  const offer = await getJson('/pair/offer');
  assert.match(offer.code, /^[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{8}$/);

  const claimed = await (
    await fetch(`http://127.0.0.1:${port}/pair/claim?code=${offer.code}`)
  ).json();

  assert.equal(claimed.ok, true);
  assert.equal(claimed.token, TOKEN, 'the bridge token, for push registration');
  assert.equal(claimed.gather.refreshToken, 'refresh-for-the-phone');
  assert.equal(claimed.gather.uid, 'uid-1');
  assert.equal(claimed.gather.spaceId, 'space-1', 'so the first connection needs no REST call');
  assert.equal(typeof claimed.name, 'string');
});

test('a claimed code is burnt, so a shoulder-surfer gets one chance and loses it', async () => {
  const offer = await getJson('/pair/offer');
  const first = await fetch(`http://127.0.0.1:${port}/pair/claim?code=${offer.code}`);
  assert.equal(first.status, 200);

  const second = await fetch(`http://127.0.0.1:${port}/pair/claim?code=${offer.code}`);
  assert.equal(second.status, 409, 'single use, and now there is no live code at all');
});

test('a bridge with no Gather session says so rather than pairing a phone that cannot connect', async () => {
  // `adopt` not yet run. Everything else about pairing works, and the fix is one
  // command on the Mac — so this has to be reported, not silently succeeded.
  const bare = new BridgeServer({
    token: 'other-token',
    port: 0,
    push: new PushNotifier({ sender: null, registry: new PushRegistry({ read: () => ({}), write: () => {} }) }),
    socketUrl: 'ws://127.0.0.1:1',
    getToken: async () => fakeJwt(),
    gatherSession: () => null,
    logSource: logPath,
    log: () => {},
  });
  await bare.start();
  const barePort = bare._http.address().port;
  try {
    const offer = await (
      await fetch(`http://127.0.0.1:${barePort}/pair/offer?token=other-token`)
    ).json();
    const claimed = await (
      await fetch(`http://127.0.0.1:${barePort}/pair/claim?code=${offer.code}`)
    ).json();

    assert.equal(claimed.ok, true, 'pairing itself succeeded');
    assert.equal(claimed.gather, null, 'and the phone is told there is no session');
  } finally {
    await bare.stop();
  }
});

test('push registration needs the pairing token like everything else', async () => {
  const res = await fetch(`http://127.0.0.1:${port}/push/register?token=wrong`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ token: 'g'.repeat(64) }),
  });
  assert.equal(res.status, 401);
});

test('a busy room does not push, because walking about is not a reason', async () => {
  // People move constantly. Nothing about that is a deliberate act, so nothing
  // about it may reach a lock screen.
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
