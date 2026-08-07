import assert from 'node:assert/strict';
import { test } from 'node:test';

import { DesktopNotificationReader, parseInspect } from '../lib/desktop-notifications.js';

/**
 * Every line here is verbatim from a real `~/Library/Logs/GatherV2/main.log`,
 * captured 2026-08-07, whitespace and all. That is the whole point of these
 * fixtures: they prove the reader handles what Gather actually writes, not what
 * we imagine it writes. Do not tidy them up.
 *
 * This is the bridge's last scraper. It survives because a wave, a meeting invite
 * and an event reminder are decisions Gather's *client* makes and hands to the
 * OS — they are in no model, no REST route and no delta patch — and they are
 * exactly the events worth waking a phone for.
 */
const WAVE =
  "[2026-08-07 10:01:39.265] [info]  (main)                        IPC Event: SHOW_NOTIFICATION { type: 'wave' }";
const WAVE_SHOWN =
  '[2026-08-07 10:01:39.266] [info]  (main)                        Showing notification 62c41002-9661-4429-b66e-ae369f83e916: wave';
const INVITE =
  "[2026-08-07 10:01:42.466] [info]  (main)                        IPC Event: SHOW_NOTIFICATION { type: 'meeting invite' }";
const REMINDER =
  "[2026-08-07 10:00:21.637] [info]  (main)                        IPC Event: SHOW_NOTIFICATION { type: 'event reminder' }";
const SUPPRESSED =
  '[2026-08-07 10:02:20.131] [info]  (main)                        Notification suppressed: App window is focused';
const BADGE =
  '[2026-08-07 10:01:39.761] [info]  (main)                        IPC Event: SET_APP_BADGE_DATA { number: 0, pin: false }';
const RENDERER_NOISE =
  '[2026-08-07 10:01:40.826] [verbose] (webapp)                      08:01:40:826 ENTER [AudioManager][setPauseOnMute] false';

const feed = (reader, ...lines) => lines.flatMap((l) => reader.feed(l));

test('a wave becomes one notification, not two', () => {
  // Gather logs the IPC message and then the notification it raised from it.
  // Reading both would double every alert on the phone.
  const events = feed(new DesktopNotificationReader(), WAVE, WAVE_SHOWN);

  assert.equal(events.length, 1);
  assert.equal(events[0].type, 'notification.shown');
  assert.equal(events[0].notificationType, 'wave');
  assert.equal(events[0].at, new Date(2026, 7, 7, 10, 1, 39, 265).toISOString());
});

test('a notification Gather suppressed is still reported', () => {
  // This is the case that decides which line to key off. Gather drops its own
  // notification when its window has focus, so no `Showing notification` line
  // follows — but the phone is a different device and should still be told.
  const events = feed(new DesktopNotificationReader(), REMINDER, SUPPRESSED);

  assert.equal(events.length, 1, 'the IPC line fires whether or not Gather showed it');
  assert.equal(events[0].notificationType, 'event reminder');
});

test('a type containing a space is read whole', () => {
  const [event] = feed(new DesktopNotificationReader(), INVITE);
  assert.equal(event.notificationType, 'meeting invite');
});

test('other IPC traffic and renderer chatter produce nothing', () => {
  // The renderer's console is by far the larger stream and has nothing in it for
  // us; `(main)` scope is checked before anything else.
  const events = feed(new DesktopNotificationReader(), BADGE, RENDERER_NOISE, SUPPRESSED);
  assert.deepEqual(events, []);
});

test('a body split across lines is held until the closing brace', () => {
  // node's util.inspect wraps long objects. Emitting on the header line would
  // lose the type.
  const reader = new DesktopNotificationReader();
  const opened = reader.feed(
    '[2026-08-07 10:01:39.265] [info]  (main)                        IPC Event: SHOW_NOTIFICATION {',
  );
  assert.deepEqual(opened, [], 'nothing until the object closes');

  reader.feed("  type: 'wave',");
  const events = reader.feed('}');

  assert.equal(events.length, 1);
  assert.equal(events[0].notificationType, 'wave');
});

test('a notification with a title and body carries both', () => {
  // Every sample so far has carried only `type`, but the IPC contract has all
  // three and Gather's own title beats anything we would invent.
  const [event] = feed(
    new DesktopNotificationReader(),
    "[2026-08-07 10:01:39.265] [info]  (main)                        IPC Event: SHOW_NOTIFICATION { type: 'wave', title: 'Ada waved', body: 'Come over?' }",
  );

  assert.equal(event.title, 'Ada waved');
  assert.equal(event.body, 'Come over?');
});

test('an unrecognised notification type is passed through rather than dropped', () => {
  // Gather thought it was worth interrupting somebody for. A new type should
  // surface, not vanish because we had not seen it before.
  const [event] = feed(
    new DesktopNotificationReader(),
    "[2026-08-07 10:01:39.265] [info]  (main)                        IPC Event: SHOW_NOTIFICATION { type: 'something new' }",
  );
  assert.equal(event.notificationType, 'something new');
});

test('an unparseable body still yields an event, typed unknown', () => {
  const [event] = feed(
    new DesktopNotificationReader(),
    '[2026-08-07 10:01:39.265] [info]  (main)                        IPC Event: SHOW_NOTIFICATION',
  );
  assert.equal(event.notificationType, 'unknown');
});

test('parseInspect reads quoted and bare values', () => {
  assert.deepEqual(parseInspect("{ type: 'wave', pin: false }"), { type: 'wave', pin: 'false' });
  assert.deepEqual(parseInspect(''), {});
});
