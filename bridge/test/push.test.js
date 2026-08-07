import assert from 'node:assert/strict';
import { test } from 'node:test';
import { generateKeyPairSync, createVerify } from 'node:crypto';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { FcmSender, buildAssertion, readServiceAccount } from '../lib/fcm.js';
import { PROXIMITY_COOLDOWN_MS, PushNotifier, PushRegistry, describe } from '../lib/push.js';

/**
 * A throwaway RSA key, generated per run. Never a real service account — the
 * point of these fixtures is the signing and payload shape, and a genuine key
 * would be a live credential sitting in the repository.
 */
const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const ACCOUNT = {
  type: 'service_account',
  project_id: 'gather-companion',
  client_email: 'pusher@gather-companion.iam.gserviceaccount.com',
  private_key: privateKey.export({ type: 'pkcs8', format: 'pem' }),
};

function accountFile(body = ACCOUNT) {
  const dir = mkdtempSync(join(tmpdir(), 'gather-push-'));
  const file = join(dir, 'service-account.json');
  writeFileSync(file, typeof body === 'string' ? body : JSON.stringify(body));
  return file;
}

/** An in-memory config, so no test can touch ~/.gather-app-bridge.json. */
function memoryRegistry(initial = {}) {
  let config = initial;
  return new PushRegistry({ read: () => config, write: (next) => (config = next) });
}

const TOKEN = 'd'.repeat(64);
const OTHER = 'e'.repeat(64);

// ---- the credential ---------------------------------------------------------

test('the wrong file from the Firebase console is rejected by name', () => {
  // The likeliest mistake is grabbing GoogleService-Info.plist or a web config.
  // Failing later on a missing property would send someone hunting in the wrong
  // place entirely, so the error has to say which file is wanted.
  const file = accountFile({ apiKey: 'x', projectId: 'gather-companion' });
  assert.throws(() => readServiceAccount(file), /client_email.*Service accounts/s);

  assert.throws(() => readServiceAccount(accountFile('not json')), /not valid JSON/);
  assert.throws(() => readServiceAccount('/nope/missing.json'), /no FCM service account/);
});

test('the assertion is a real RS256 JWT Google would accept', () => {
  const jwt = buildAssertion(readServiceAccount(accountFile()), 1_700_000_000_000);
  const [header, claims, signature] = jwt.split('.');

  assert.deepEqual(JSON.parse(Buffer.from(header, 'base64url').toString()), {
    alg: 'RS256',
    typ: 'JWT',
  });
  const payload = JSON.parse(Buffer.from(claims, 'base64url').toString());
  assert.equal(payload.iss, ACCOUNT.client_email);
  assert.equal(payload.scope, 'https://www.googleapis.com/auth/firebase.messaging');
  assert.equal(payload.aud, 'https://oauth2.googleapis.com/token');
  assert.equal(payload.exp - payload.iat, 3600);

  const verifier = createVerify('RSA-SHA256');
  verifier.update(`${header}.${claims}`);
  assert.ok(
    verifier.verify(publicKey, Buffer.from(signature, 'base64url')),
    'the signature must verify against the account key, or Google returns invalid_grant',
  );
});

// ---- sending ----------------------------------------------------------------

/** Records every request instead of making one. Nothing here reaches Google. */
function fakeFetch(responder) {
  const calls = [];
  const impl = async (url, init) => {
    calls.push({ url: String(url), init, body: safeJson(init?.body) });
    return responder(String(url), calls.length);
  };
  impl.calls = calls;
  return impl;
}

const safeJson = (body) => {
  try {
    return JSON.parse(String(body));
  } catch {
    return null;
  }
};

const okToken = () =>
  new Response(JSON.stringify({ access_token: 'access-1', expires_in: 3600 }), { status: 200 });

test('a send carries a notification block, which is what a killed app needs', async () => {
  // Without `notification` FCM sends a data-only message, which iOS will not
  // display for a suspended app — the exact case this feature exists for.
  const fetchImpl = fakeFetch((url) =>
    url.includes('oauth2') ? okToken() : new Response('{}', { status: 200 }),
  );
  const sender = new FcmSender({ keyFile: accountFile(), fetchImpl });

  const result = await sender.send({
    token: TOKEN,
    title: 'Someone waved at you',
    body: 'Come over?',
    data: { type: 'notification.shown' },
    collapseId: 'gather-wave',
  });

  assert.equal(result.ok, true);
  const send = fetchImpl.calls.at(-1);
  assert.match(send.url, /projects\/gather-companion\/messages:send$/);
  assert.equal(send.init.headers.authorization, 'Bearer access-1');

  const message = send.body.message;
  assert.equal(message.token, TOKEN);
  assert.deepEqual(message.notification, { title: 'Someone waved at you', body: 'Come over?' });
  assert.equal(message.apns.headers['apns-collapse-id'], 'gather-wave');
  assert.equal(message.apns.headers['apns-priority'], '10');
  assert.equal(message.apns.payload.aps.sound, 'default');
});

test('data values are stringified, because FCM rejects anything else', async () => {
  const fetchImpl = fakeFetch((url) =>
    url.includes('oauth2') ? okToken() : new Response('{}', { status: 200 }),
  );
  const sender = new FcmSender({ keyFile: accountFile(), fetchImpl });
  await sender.send({ token: TOKEN, title: 't', body: 'b', data: { n: 3, flag: true } });

  assert.deepEqual(fetchImpl.calls.at(-1).body.message.data, { n: '3', flag: 'true' });
});

test('the access token is fetched once and reused', async () => {
  const fetchImpl = fakeFetch((url) =>
    url.includes('oauth2') ? okToken() : new Response('{}', { status: 200 }),
  );
  const sender = new FcmSender({ keyFile: accountFile(), fetchImpl });

  await sender.send({ token: TOKEN, title: 't', body: 'b' });
  await sender.send({ token: OTHER, title: 't', body: 'b' });

  const exchanges = fetchImpl.calls.filter((c) => c.url.includes('oauth2'));
  assert.equal(exchanges.length, 1, 'a token exchange per notification would be absurd');
});

test('an unregistered device is reported as droppable', async () => {
  const fetchImpl = fakeFetch((url) =>
    url.includes('oauth2')
      ? okToken()
      : new Response(JSON.stringify({ error: { status: 'UNREGISTERED', message: 'gone' } }), {
          status: 404,
        }),
  );
  const sender = new FcmSender({ keyFile: accountFile(), fetchImpl });
  const result = await sender.send({ token: TOKEN, title: 't', body: 'b' });

  assert.equal(result.ok, false);
  assert.equal(result.drop, true, 'a dead token must be forgotten, not retried forever');
});

test('a transient failure is not mistaken for a dead device', async () => {
  const fetchImpl = fakeFetch((url) =>
    url.includes('oauth2')
      ? okToken()
      : new Response(JSON.stringify({ error: { status: 'UNAVAILABLE' } }), { status: 503 }),
  );
  const sender = new FcmSender({ keyFile: accountFile(), fetchImpl });
  const result = await sender.send({ token: TOKEN, title: 't', body: 'b' });

  assert.equal(result.ok, false);
  assert.equal(result.drop, false, 'FCM being down must not unregister every phone');
});

// ---- policy -----------------------------------------------------------------

const nameFor = (id) => (id === 'p1' ? 'Ada' : id);

test('the four chosen reasons produce a sentence, and nothing else does', () => {
  const wave = describe({ type: 'notification.shown', notificationType: 'wave' }, nameFor);
  assert.equal(wave.kind, 'wave');
  assert.equal(wave.title, 'Someone waved at you');

  const follow = describe(
    { type: 'follow.started', targetIsSelf: true, followerId: 'p1' },
    nameFor,
  );
  assert.equal(follow.kind, 'follow');
  assert.equal(follow.body, 'Ada started following you');

  assert.equal(
    describe({ type: 'notification.shown', notificationType: 'meeting invite' }).kind,
    'meeting invite',
  );
  assert.equal(
    describe({ type: 'notification.shown', notificationType: 'event reminder' }).kind,
    'event reminder',
  );

  // Me following somebody else is not news to me.
  assert.equal(describe({ type: 'follow.started', targetIsSelf: false, targetId: 'p1' }), null);
  assert.equal(describe({ type: 'proximity.left', playerId: 'p1' }), null);
  assert.equal(describe({ type: 'player.moved', playerId: 'p1' }), null);
  assert.equal(describe({ type: 'bridge.status', collector: 'gather' }), null);
});

test('an unknown Gather notification type is not pushed', () => {
  // It has no wording, and inventing one for a lock screen is worse than
  // silence. It still reaches the feed over the socket.
  assert.equal(describe({ type: 'notification.shown', notificationType: 'something new' }), null);
});

test("Gather's own title and body win when it sends them", () => {
  const note = describe({
    type: 'notification.shown',
    notificationType: 'wave',
    title: 'Ada waved',
    body: 'Come to the kitchen',
  });
  assert.equal(note.title, 'Ada waved');
  assert.equal(note.body, 'Come to the kitchen');
});

test('proximity is off by default and on when asked for', async () => {
  const sent = [];
  const sender = { send: async (n) => (sent.push(n), { ok: true }) };
  const event = { type: 'proximity.entered', playerId: 'p1' };

  const off = new PushNotifier({
    sender,
    registry: memoryRegistry({ push: { devices: [{ token: TOKEN, platform: 'ios' }] } }),
  });
  assert.equal(await off.consider(event, nameFor), null);
  assert.equal(sent.length, 0, 'the noisiest reason must stay opt-in');

  const on = new PushNotifier({
    sender,
    registry: memoryRegistry({
      push: { devices: [{ token: TOKEN, platform: 'ios' }], kinds: { proximity: true } },
    }),
  });
  assert.ok(await on.consider(event, nameFor));
  assert.equal(sent[0].body, 'Ada is standing next to you');
});

test('the same person cannot buzz you twice inside the cooldown', async () => {
  const sent = [];
  let clock = 1_000_000;
  const notifier = new PushNotifier({
    sender: { send: async (n) => (sent.push(n), { ok: true }) },
    registry: memoryRegistry({
      push: { devices: [{ token: TOKEN, platform: 'ios' }], kinds: { proximity: true } },
    }),
    now: () => clock,
  });
  const event = { type: 'proximity.entered', playerId: 'p1' };

  await notifier.consider(event, nameFor);
  clock += PROXIMITY_COOLDOWN_MS - 1000;
  await notifier.consider(event, nameFor);
  assert.equal(sent.length, 1, 'pacing near a desk must not buzz repeatedly');

  clock += 2000;
  await notifier.consider(event, nameFor);
  assert.equal(sent.length, 2, 'but it must not be silenced forever either');

  // A different person is a different notification, cooldown or not.
  await notifier.consider({ type: 'proximity.entered', playerId: 'p2' }, nameFor);
  assert.equal(sent.length, 3);
});

test('every registered phone is sent to, and dead ones are dropped', async () => {
  const registry = memoryRegistry({
    push: { devices: [{ token: TOKEN, platform: 'ios' }, { token: OTHER, platform: 'ios' }] },
  });
  const notifier = new PushNotifier({
    sender: {
      send: async ({ token }) => (token === OTHER ? { ok: false, drop: true } : { ok: true }),
    },
    registry,
  });

  await notifier.consider({ type: 'notification.shown', notificationType: 'wave' });

  assert.deepEqual(
    registry.list().map((d) => d.token),
    [TOKEN],
    'the phone FCM says is gone must not be tried again',
  );
});

test('a push failure never breaks the event pipeline', async () => {
  // The phone with a live socket is already getting this event; a Google outage
  // must not take the socket down with it.
  const notifier = new PushNotifier({
    sender: {
      send: async () => {
        throw new Error('network down');
      },
    },
    registry: memoryRegistry({ push: { devices: [{ token: TOKEN, platform: 'ios' }] } }),
  });

  await assert.doesNotReject(
    notifier.consider({ type: 'notification.shown', notificationType: 'wave' }),
  );
});

test('nothing is sent when push is not set up, or nobody registered', async () => {
  const none = new PushNotifier({ sender: null, registry: memoryRegistry() });
  assert.equal(none.enabled, false);
  assert.equal(await none.consider({ type: 'notification.shown', notificationType: 'wave' }), null);

  const sent = [];
  const noDevices = new PushNotifier({
    sender: { send: async (n) => (sent.push(n), { ok: true }) },
    registry: memoryRegistry(),
  });
  assert.equal(
    await noDevices.consider({ type: 'notification.shown', notificationType: 'wave' }),
    null,
  );
  assert.equal(sent.length, 0);
});

// ---- the registry -----------------------------------------------------------

test('registering the same phone twice replaces rather than duplicates', () => {
  const registry = memoryRegistry();
  registry.register({ token: TOKEN, platform: 'ios' });
  registry.register({ token: TOKEN, platform: 'ios' });
  assert.equal(registry.list().length, 1, 'the app re-registers on every connect');

  registry.register({ token: OTHER, platform: 'ios' });
  assert.equal(registry.list().length, 2, 'a second phone is a second device');
});

test('a token too short to be real is refused', () => {
  assert.throws(() => memoryRegistry().register({ token: 'nope' }), /push token/);
  assert.throws(() => memoryRegistry().register({ token: null }), /push token/);
});

test('config overrides the default reasons without losing the rest', () => {
  const registry = memoryRegistry({ push: { kinds: { proximity: true, wave: false } } });
  const kinds = registry.kinds();
  assert.equal(kinds.proximity, true);
  assert.equal(kinds.wave, false);
  assert.equal(kinds.follow, true, 'unmentioned reasons keep their default');
});
