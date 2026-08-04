/**
 * Turns the Gather V2 desktop client's log into normalised events.
 *
 * The client writes `~/Library/Logs/GatherV2/main.log`. Two things end up in
 * there, and both are useful:
 *
 *  - `(main)` scope — the Electron main process, including an instrumented
 *    trace of *every* IPC message the web app sends the native shell
 *    (`IPC Event: AUDIO_UPDATED { audio: false }`) and every native
 *    notification it raises.
 *  - `(webapp)` scope — the renderer's own console output, forwarded verbatim.
 *    `setupWebContentsLogger` hooks `webContents.on('console-message')`
 *    unconditionally, with no feature-flag gate, so this works on a stock
 *    install. This is where the game-level chatter lives.
 *
 * ## Two id namespaces
 *
 * This is the trap in this file. Verified empirically against ~2.5 MB of real
 * logs by intersecting the uuid sets per pattern:
 *
 *  - `[PlayerManagerV2] Player has joined/left`, `GameMediaController.*` and
 *    `[Vol] set` all use **player ids** — 12 of 13 media ids also showed up in
 *    the space roster.
 *  - `[GatherPeerManager][playerConnectedSFU|playerLeavingSFU]`,
 *    `participantUserAccountIdMap` and `[BitM]` use a **separate participant
 *    id** namespace — 0 of 13 overlap with the player ids, despite the method
 *    names containing the word "player".
 *
 * So proximity is tracked from the `GameMediaController.*` and `[Vol]` lines,
 * never from the `*SFU` ones.
 *
 * ## Why media events mean "standing next to me"
 *
 * Gather only establishes audio/video with players close enough to hear you. In
 * the sample session 29 distinct players joined the space but only 13 ever got a
 * media connection — those 13 are the ones who actually came near. That makes
 * remote-participant join/leave a faithful, if inferred, proximity signal. It is
 * coarser than real coordinates (which need the CDP collector) but it is exactly
 * the radius Gather itself calls "nearby".
 */

import {
  audioRange,
  mediaChanged,
  mediaConnection,
  notificationShown,
  playerSpace,
  proximity,
  raw,
  selfChanged,
  spaceChanged,
} from './events.js';

/** A uuid as Gather writes them. */
const UUID = '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})';

/** `[2026-07-31 12:07:07.638] [verbose] (webapp)   <message>` */
const ENTRY_HEADER =
  /^\[(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d{3})\]\s+\[(\w+)\]\s+\((\w+)\)\s+(.*)$/;

/** The renderer prefixes its own lines with a second, shorter clock. */
const INNER_CLOCK = /^\d{2}:\d{2}:\d{2}:\d{3}\s+/;

const PLAYER_JOINED_SPACE = new RegExp(`^\\[PlayerManagerV2\\] Player has joined ${UUID}`);
const PLAYER_LEFT_SPACE = new RegExp(`^\\[PlayerManagerV2\\] Player has left ${UUID}`);

const PARTICIPANT_JOINED = new RegExp(
  `^GameMediaController\\.remoteParticipantJoinedHandler ${UUID}`,
);
const PARTICIPANT_LEFT = new RegExp(`^GameMediaController\\.remoteParticipantLeftHandler ${UUID}`);
const TRACK_PAUSED_STATE = new RegExp(
  '^GameMediaController\\.remoteParticipantTrackStateChangedHandler ' +
    `setStreamPausedState ${UUID} (audio|video|screen) (true|false)`,
);
const CONNECTION_STATE = new RegExp(
  `^GameMediaController\\.remoteParticipantConnectionStateChangedHandler ${UUID} (.+)$`,
);

const VOLUME = new RegExp(`^\\[Vol\\] set ${UUID}\\s*:\\s*([\\d.]+)\\s*->\\s*([\\d.]+)`);

const SHOWING_NOTIFICATION = /^Showing notification [0-9a-f-]+:\s*(.*)$/;
const FOLLOW_TARGET_PATHFINDING = /setFollowTarget/;

/** `IPC Event: CHANNEL rest...` */
const IPC_EVENT = /^IPC Event:\s+([A-Z_]+)\s*:?\s*(.*)$/;

/** `key: value` pairs inside node's `util.inspect` output. */
const INSPECT_PAIR = /([A-Za-z_][A-Za-z0-9_]*)\s*:\s*('([^']*)'|[^,\n}]+)/g;

export class GatherLogParser {
  constructor() {
    /** Header of an entry whose `util.inspect` body is still arriving. */
    this._openEntry = null;
    this._openBody = '';
  }

  /**
   * Feed one raw line; returns every event it produced.
   *
   * Single-line entries are emitted immediately so there is no added latency;
   * only entries with a multi-line `{ ... }` body are held until the closing
   * brace arrives.
   *
   * @param {string} rawLine
   * @returns {object[]}
   */
  feed(rawLine) {
    const line = rawLine.replace(/\s+$/, '');
    if (!line) return [];

    const header = ENTRY_HEADER.exec(line);
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

    const at = new Date(
      Number(header[1]),
      Number(header[2]) - 1,
      Number(header[3]),
      Number(header[4]),
      Number(header[5]),
      Number(header[6]),
      Number(header[7]),
    );
    const entry = {
      at,
      level: header[8],
      scope: header[9],
      message: header[10].replace(INNER_CLOCK, '').trim(),
    };

    const events = [...flushed, ...this._parseEntry(entry)];

    // Hold the entry open if its body is still to come.
    if (entry.message.includes('{') && !entry.message.includes('}')) {
      this._openEntry = entry;
      this._openBody = `${entry.message}\n`;
    }

    return events;
  }

  /** Emit anything that needed the full multi-line body. */
  _closeOpenEntry() {
    const entry = this._openEntry;
    const body = this._openBody;
    this._openEntry = null;
    this._openBody = '';
    if (!entry) return [];

    const ipc = IPC_EVENT.exec(entry.message);
    if (!ipc) return [];
    return this._parseIpc(entry, ipc[1], body);
  }

  _parseEntry(entry) {
    if (entry.scope === 'webapp') return this._parseWebApp(entry);
    if (entry.scope === 'main') return this._parseMain(entry);
    return [];
  }

  _parseWebApp(e) {
    const m = e.message;

    const joinedSpace = PLAYER_JOINED_SPACE.exec(m);
    if (joinedSpace) return [playerSpace({ at: e.at, playerId: joinedSpace[1], joined: true })];

    const leftSpace = PLAYER_LEFT_SPACE.exec(m);
    if (leftSpace) return [playerSpace({ at: e.at, playerId: leftSpace[1], joined: false })];

    const near = PARTICIPANT_JOINED.exec(m);
    if (near) return [proximity({ at: e.at, playerId: near[1], near: true })];

    const away = PARTICIPANT_LEFT.exec(m);
    if (away) return [proximity({ at: e.at, playerId: away[1], near: false })];

    const track = TRACK_PAUSED_STATE.exec(m);
    if (track) {
      return [
        mediaChanged({
          at: e.at,
          playerId: track[1],
          track: track[2],
          paused: track[3] === 'true',
        }),
      ];
    }

    const conn = CONNECTION_STATE.exec(m);
    if (conn) {
      return [mediaConnection({ at: e.at, playerId: conn[1], state: conn[2].trim() })];
    }

    const vol = VOLUME.exec(m);
    if (vol) {
      const to = Number(vol[3]);
      return [
        audioRange({
          at: e.at,
          playerId: vol[1],
          inRange: to > 0,
          volume: Number.isFinite(to) ? to : null,
        }),
      ];
    }

    if (FOLLOW_TARGET_PATHFINDING.test(m)) {
      // Only ever logged by *our* client while it walks us toward someone we
      // chose to follow. It says nothing about being followed.
      return [raw({ at: e.at, type: 'follow.selfPathfinding', text: m })];
    }

    return [];
  }

  _parseMain(e) {
    const notification = SHOWING_NOTIFICATION.exec(e.message);
    if (notification) {
      return [notificationShown({ at: e.at, notificationType: notification[1].trim() })];
    }

    const ipc = IPC_EVENT.exec(e.message);
    if (ipc) return this._parseIpc(e, ipc[1], ipc[2]);

    return [];
  }

  _parseIpc(e, channel, args) {
    const f = parseInspect(args);
    const at = e.at;

    switch (channel) {
      case 'AUDIO_UPDATED':
        return [selfChanged({ at, audioEnabled: bool(f.audio) ?? bool(args.trim()) })];
      case 'VIDEO_UPDATED':
        return [selfChanged({ at, videoEnabled: bool(f.video) ?? bool(args.trim()) })];
      case 'START_SCREEN_SHARE':
      case 'SHOW_SCREEN_SHARE_MODAL':
        return [selfChanged({ at, screensharing: true })];
      case 'STOP_SCREEN_SHARE':
      case 'HIDE_SCREEN_SHARE_MODAL':
        return [selfChanged({ at, screensharing: false })];
      case 'IN_GAME_CANVAS':
        return [selfChanged({ at, inOffice: true })];
      case 'IN_USER_HOME':
      case 'LEAVE_SPACE':
        return [selfChanged({ at, inOffice: false })];
      case 'IN_OFFICE_UPDATED':
        return [selfChanged({ at, inOffice: bool(f.inOffice) ?? bool(args.trim()) })];
      case 'SHOW_NOTIFICATION':
        return [
          notificationShown({
            at,
            notificationType: f.type ?? 'unknown',
            title: f.title ?? null,
            body: f.body ?? null,
          }),
        ];
      case 'SET_APP_BADGE':
      case 'SET_APP_BADGE_DATA':
        return [raw({ at, type: 'app.badge', text: args.trim() || '0' })];
      case 'UPDATE_SHARED_STATE': {
        const out = [];
        // Most UPDATE_SHARED_STATE traffic is memory telemetry; drop that.
        const interesting =
          'audioEnabled' in f ||
          'videoEnabled' in f ||
          'inOffice' in f ||
          'isScreensharing' in f ||
          'userId' in f;
        if (interesting) {
          out.push(
            selfChanged({
              at,
              userId: f.userId ?? null,
              audioEnabled: bool(f.audioEnabled),
              videoEnabled: bool(f.videoEnabled),
              inOffice: bool(f.inOffice),
              screensharing: bool(f.isScreensharing),
            }),
          );
        }
        if ('spaceId' in f || 'spaceName' in f) {
          out.push(
            spaceChanged({ at, spaceId: f.spaceId ?? null, spaceName: f.spaceName ?? null }),
          );
        }
        return out;
      }
      default:
        return [];
    }
  }
}

/**
 * Lenient reader for node `util.inspect` output such as
 * `{ type: 'event reminder' }` or a multi-line `{\n  audioEnabled: true\n}`.
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

function bool(rawValue) {
  if (rawValue === 'true') return true;
  if (rawValue === 'false') return false;
  return null;
}
