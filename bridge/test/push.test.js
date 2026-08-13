import assert from 'node:assert/strict';
import { test } from 'node:test';
import { generateKeyPairSync, createVerify } from 'node:crypto';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { FcmSender, buildAssertion, readServiceAccount } from '../lib/fcm.js';
import { PushNotifier, PushRegistry, STALE_AFTER_DAYS, describe } from '../lib/push.js';

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
  // Somebody giving up on following you is not worth a lock screen.
  assert.equal(describe({ type: 'follow.stopped', targetIsSelf: true, followerId: 'p1' }), null);
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

test('a reason can be switched off per install', async () => {
  const sent = [];
  const sender = { send: async (n) => (sent.push(n), { ok: true }) };
  const event = { type: 'follow.started', targetIsSelf: true, followerId: 'p1' };

  const off = new PushNotifier({
    sender,
    registry: memoryRegistry({
      push: { devices: [{ token: TOKEN, platform: 'ios' }], kinds: { follow: false } },
    }),
  });
  assert.equal(await off.consider(event, nameFor), null);
  assert.equal(sent.length, 0, 'config has to be able to say no');

  const on = new PushNotifier({
    sender,
    registry: memoryRegistry({ push: { devices: [{ token: TOKEN, platform: 'ios' }] } }),
  });
  assert.ok(await on.consider(event, nameFor));
  assert.equal(sent[0].body, 'Ada started following you');
});

test('the same person following you twice buzzes twice', async () => {
  // There is no rate limiting left. Every remaining reason is a deliberate act by
  // a person, so the cooldown that proximity needed would only ever swallow
  // something somebody meant to do.
  const sent = [];
  const notifier = new PushNotifier({
    sender: { send: async (n) => (sent.push(n), { ok: true }) },
    registry: memoryRegistry({ push: { devices: [{ token: TOKEN, platform: 'ios' }] } }),
  });
  const event = { type: 'follow.started', targetIsSelf: true, followerId: 'p1' };

  await notifier.consider(event, nameFor);
  await notifier.consider(event, nameFor);
  assert.equal(sent.length, 2);
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
  const registry = memoryRegistry({ push: { kinds: { follow: false, wave: false } } });
  const kinds = registry.kinds();
  assert.equal(kinds.follow, false);
  assert.equal(kinds.wave, false);
  assert.equal(kinds['meeting invite'], true, 'unmentioned reasons keep their default');
});

test('a reinstalled app replaces its own entry rather than leaving a dead one', () => {
  // The bug this exists for: a reinstall mints a new FCM token, so keying on the
  // token left the previous install's token in the list. FCM answers 200 for it,
  // the notification goes nowhere, and nothing anywhere reports a problem.
  const registry = memoryRegistry();
  registry.register({ token: TOKEN, platform: 'ios', installId: 'phone-1' });
  registry.register({ token: OTHER, platform: 'ios', installId: 'phone-1' });

  assert.deepEqual(
    registry.list().map((d) => d.token),
    [OTHER],
    'the token from before the reinstall must not survive',
  );

  registry.register({ token: TOKEN, platform: 'ios', installId: 'phone-2' });
  assert.equal(registry.list().length, 2, 'a different install is a different phone');
});

test('an install id is not required, so an older app build still registers', () => {
  const registry = memoryRegistry();
  registry.register({ token: TOKEN, platform: 'ios' });
  registry.register({ token: TOKEN, platform: 'ios' });
  assert.equal(registry.list().length, 1);
  assert.equal(registry.list()[0].installId, undefined);
});

test('re-registering unchanged stays quiet in the log', () => {
  // The app re-registers on every resume. One line per resume is how the single
  // registration that mattered got buried under thirty that did not.
  const lines = [];
  let config = {};
  const registry = new PushRegistry({
    log: (line) => lines.push(line),
    read: () => config,
    write: (next) => (config = next),
  });

  registry.register({ token: TOKEN, platform: 'ios', installId: 'phone-1' });
  assert.equal(lines.length, 1, 'the first one is worth saying');

  registry.register({ token: TOKEN, platform: 'ios', installId: 'phone-1' });
  assert.equal(lines.length, 1, 'nothing changed, so nothing to report');

  registry.register({ token: OTHER, platform: 'ios', installId: 'phone-1' });
  assert.equal(lines.length, 2);
  assert.match(lines[1], /rotated its token/);
});

test('a successful send is logged, and stamped on the device', async () => {
  // Without the log line there was no evidence a push had ever been attempted.
  const lines = [];
  const registry = memoryRegistry({ push: { devices: [{ token: TOKEN, platform: 'ios' }] } });
  const notifier = new PushNotifier({
    sender: { send: async () => ({ ok: true }) },
    registry,
    log: (line) => lines.push(line),
  });

  await notifier.consider({ type: 'notification.shown', notificationType: 'wave' });

  assert.ok(
    lines.some((l) => /^push: sent "Someone waved at you" to 1 device\(s\)$/.test(l)),
    `expected a send line, got ${JSON.stringify(lines)}`,
  );
  assert.ok(registry.list()[0].lastSentAt, 'the device carries when it was last reached');
});

test('a push with nobody registered says so rather than passing silently', async () => {
  const lines = [];
  const notifier = new PushNotifier({
    sender: { send: async () => ({ ok: true }) },
    registry: memoryRegistry(),
    log: (line) => lines.push(line),
  });

  await notifier.consider({ type: 'notification.shown', notificationType: 'wave' });
  assert.ok(lines.some((l) => /no device has registered/.test(l)));
});

test('a device nobody has reached in months is dropped, generously', () => {
  const now = Date.parse('2026-08-13T00:00:00Z');
  const day = 86_400_000;
  const registry = memoryRegistry({
    push: {
      devices: [
        { token: TOKEN, platform: 'ios', registeredAt: new Date(now - 90 * day).toISOString() },
        { token: OTHER, platform: 'ios', registeredAt: new Date(now - 10 * day).toISOString() },
      ],
    },
  });

  assert.equal(registry.prune({ now }), 1);
  assert.deepEqual(
    registry.list().map((d) => d.token),
    [OTHER],
  );
});

test('a phone away from the LAN but still being pushed to is kept', () => {
  // `registeredAt` only refreshes on the LAN, so someone remote for two months has
  // a live token that never re-registers. `lastSentAt` is what proves it is alive.
  const now = Date.parse('2026-08-13T00:00:00Z');
  const day = 86_400_000;
  const registry = memoryRegistry({
    push: {
      devices: [
        {
          token: TOKEN,
          platform: 'ios',
          registeredAt: new Date(now - 90 * day).toISOString(),
          lastSentAt: new Date(now - 2 * day).toISOString(),
        },
      ],
    },
  });

  assert.equal(registry.prune({ now }), 0);
});

test('a device with no dates at all predates the field and is kept', () => {
  const registry = memoryRegistry({ push: { devices: [{ token: TOKEN, platform: 'ios' }] } });
  assert.equal(registry.prune({ now: Date.parse('2026-08-13T00:00:00Z') }), 0);
});

test('the staleness window is configurable per install', () => {
  const registry = memoryRegistry({ push: { staleAfterDays: 7 } });
  assert.equal(registry.staleAfterDays(), 7);
  assert.equal(memoryRegistry().staleAfterDays(), STALE_AFTER_DAYS);
});
