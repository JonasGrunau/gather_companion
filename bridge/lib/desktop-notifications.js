/**
 * Gather's own desktop notifications, read out of the client's log.
 *
 * This is the last thing the bridge scrapes, and it is deliberate. Everything
 * else — who is in the space, where they are standing, who is following you, who
 * is talking — now comes from Gather's game socket, which is authoritative and
 * needs no desktop client at all. These do not, because they cannot: a wave, a
 * meeting invite and an event reminder are decisions Gather's *client* makes and
 * hands to the OS. They appear in no model, no REST route and no delta patch.
 *
 * Three minutes of live deltas on a 111-person space returned 46 patches across
 * four models — `SpaceUser`, `SpaceUserStatus`, `ExternalCalendarConnection`,
 * `SpaceUserCluster` — and nothing resembling an event. The game socket is a
 * state channel, not a notification bus.
 *
 * ## What it reads
 *
 * `~/Library/Logs/GatherV2/main.log`, `(main)` scope only — the Electron main
 * process, which logs every IPC message the web app sends the native shell.
 * `setupWebContentsLogger` installs this unconditionally, with no feature-flag
 * gate, so it works on a stock install.
 *
 *     IPC Event: SHOW_NOTIFICATION { type: 'wave' }
 *     Showing notification 62c41002-…: wave
 *     Notification suppressed: App window is focused
 *
 * Observed types so far: `wave`, `meeting invite`, `event reminder`.
 *
 * ## The suppressed case matters most
 *
 * Gather drops its own notification when its window has focus. We do not: the
 * phone is a different device, and "you are looking at Gather on your Mac" is no
 * reason to withhold a wave from a screen in your pocket. So the `IPC Event:
 * SHOW_NOTIFICATION` line is the trigger, not the `Showing notification` line
 * that follows it — the latter is absent exactly when the client suppressed it.
 *
 * The two lines are emitted as a pair for the same notification, so keying off
 * the IPC line also avoids reporting each one twice.
 */

import { notificationShown } from './events.js';

/** `[2026-08-07 10:01:39.265] [info]  (main)   <message>` */
const ENTRY =
  /^\[(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d{3})\]\s+\[(\w+)\]\s+\((\w+)\)\s+(.*)$/;

/** `IPC Event: SHOW_NOTIFICATION { type: 'wave' }` — possibly across lines. */
const SHOW_NOTIFICATION = /^IPC Event:\s+SHOW_NOTIFICATION\s*:?\s*(.*)$/;

/** `key: value` pairs inside node's `util.inspect` output. */
const INSPECT_PAIR = /([A-Za-z_][A-Za-z0-9_]*)\s*:\s*('([^']*)'|[^,\n}]+)/g;

export class DesktopNotificationReader {
  constructor() {
    /** Header of an entry whose `util.inspect` body is still arriving. */
    this._openEntry = null;
    this._openBody = '';
  }

  /**
   * Feed one raw line; returns every event it produced.
   *
   * Single-line entries are emitted immediately so a wave reaches the phone with
   * no added latency; only entries with a multi-line `{ ... }` body are held
   * until the closing brace arrives.
   *
   * @param {string} rawLine
   * @returns {object[]}
   */
  feed(rawLine) {
    const line = rawLine.replace(/\s+$/, '');
    if (!line) return [];

    const header = ENTRY.exec(line);
    if (!header) {
      // Continuation of a pretty-printed body.
      if (this._openEntry) {
        this._openBody += `${line}\n`;
        if (line.trimStart().startsWith('}')) return this._closeOpenEntry();
      }
      return [];
    }

    // A new entry starts: whatever was open is finished (or malformed).
    const flushed = this._openEntry ? this._closeOpenEntry() : [];

    // Only the main process raises notifications; the renderer's own console
    // output is a much larger stream with nothing in it for us.
    if (header[9] !== 'main') return flushed;

    const at = new Date(
      Number(header[1]),
      Number(header[2]) - 1,
      Number(header[3]),
      Number(header[4]),
      Number(header[5]),
      Number(header[6]),
      Number(header[7]),
    );
    const message = header[10].trim();
    const match = SHOW_NOTIFICATION.exec(message);
    if (!match) return flushed;

    // Hold it open if the `{ … }` body is still to come; emit now if it is whole.
    if (message.includes('{') && !message.includes('}')) {
      this._openEntry = { at };
      this._openBody = message;
      return flushed;
    }
    return [...flushed, event(at, match[1])];
  }

  _closeOpenEntry() {
    const entry = this._openEntry;
    const body = this._openBody;
    this._openEntry = null;
    this._openBody = '';
    if (!entry) return [];
    // Flattened first: the pattern is anchored with `$`, and a body that wrapped
    // across lines would never match it otherwise.
    const match = SHOW_NOTIFICATION.exec(body.replace(/\s*\n\s*/g, ' ').trim());
    return match ? [event(entry.at, match[1])] : [];
  }
}

function event(at, args) {
  const fields = parseInspect(args);
  return notificationShown({
    at,
    notificationType: fields.type ?? 'unknown',
    title: fields.title ?? null,
    body: fields.body ?? null,
  });
}

/**
 * Lenient reader for node `util.inspect` output such as `{ type: 'wave' }` or a
 * multi-line `{\n  type: 'meeting invite'\n}`.
 */
export function parseInspect(text) {
  const out = {};
  INSPECT_PAIR.lastIndex = 0;
  let m;
  while ((m = INSPECT_PAIR.exec(text)) !== null) {
    out[m[1]] = (m[3] ?? m[2]).trim();
  }
  return out;
}
