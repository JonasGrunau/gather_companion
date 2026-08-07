/**
 * Is anything event-shaped on the game socket?
 *
 * `docs/gather-api.md` concludes the socket is "a state channel, not an event
 * bus", and that waves, meeting invites and event reminders therefore have to be
 * scraped out of the desktop client's log. That conclusion rests on a single
 * three-minute delta sample in which **nobody waved** — and on a reader that
 * filters to four models before anyone could have looked. Two rows in the same
 * document argue the other way: `ActivityEvent {metadata, isGlobal}` is exactly
 * an event-bus shape, and `MeetingParticipant {inviteStatus, inviterId}` is what
 * a pending invite would look like as state.
 *
 * So this probe deliberately does the two things the old one could not:
 *
 *   1. Reports the **full** model census from the state dump, and prints every
 *      row of the models that could plausibly carry an interaction — decoded, not
 *      previewed.
 *   2. Prints **every delta patch, unfiltered** — model, op, path, value — so a
 *      wave arriving as any model at all shows up instead of being dropped.
 *
 * Read-only: it authenticates as the user and stops at `loadSpaceUser`, exactly
 * like `DirectCollector`. It never sends `enterSpace`, so no avatar appears and
 * `numTimesEnteredSpace` is untouched.
 *
 * ```sh
 * node tool/probe-events.mjs                 # census, then watch until Ctrl-C
 * node tool/probe-events.mjs --seconds 120   # stop on a timer
 * node tool/probe-events.mjs --space <uuid>
 * ```
 *
 * While it watches, go and do the things that are supposed to be invisible:
 * raise your hand, have someone wave at you, send a chat, invite yourself to a
 * meeting. Anything that lands here is something the bridge could read without
 * the desktop client.
 */

import { randomUUID } from 'node:crypto';

import { decode, encode } from '../bridge/lib/msgpack.js';
import { getIdToken, uidFromIdToken } from '../bridge/lib/gather-auth.js';
import { readGatherSpace } from '../bridge/lib/paths.js';

const GAME_SOCKET = 'wss://game-router.v2.gather.town/gather-game-v2';

/**
 * Models worth dumping in full from the state census.
 *
 * Chosen because each one could carry "somebody did a thing at me" rather than
 * "the world looks like this". `ActivityEvent` is the headline suspect.
 */
const SUSPECTS = new Set([
  'ActivityEvent',
  'MeetingParticipant',
  'Meeting',
  'ChatMessage',
  'ChatChannel',
  'ChatChannelMember',
  'SpaceUserStatus',
  'MeetingJoinInfo',
  // Not in the documented 46-model table, and event-shaped by its name alone:
  // somebody asking to join is exactly the kind of thing worth a lock screen.
  'MeetingJoinRequest',
]);

/**
 * Everything the space holds *about us*, across every model.
 *
 * The census answers "what models exist"; this answers "which rows are addressed
 * to me", which is the question that decides whether an interaction is readable
 * as state. A meeting invite, for instance, should be a `MeetingParticipant` row
 * carrying our own `spaceUserId` and somebody else's `inviterId`.
 */
const ABOUT_ME_MODELS = new Set([
  'MeetingParticipant',
  'MeetingJoinRequest',
  'ChatChannelMember',
  'SpaceUserStatus',
]);

const dim = (s) => `\x1b[2m${s}\x1b[0m`;
const bold = (s) => `\x1b[1m${s}\x1b[0m`;
const green = (s) => `\x1b[32m${s}\x1b[0m`;
const yellow = (s) => `\x1b[33m${s}\x1b[0m`;
const cyan = (s) => `\x1b[36m${s}\x1b[0m`;

const argv = process.argv.slice(2);
const flag = (name) => {
  const at = argv.indexOf(`--${name}`);
  return at === -1 ? null : argv[at + 1];
};

/** How long after the last full-state chunk we call the dump finished. */
const DUMP_SETTLE_MS = 2500;
const HEARTBEAT_INTERVAL_MS = 10_000;

async function main() {
  const token = await getIdToken({ log: (m) => console.log(dim(`  ${m}`)) });
  const authUserId = uidFromIdToken(token);
  const spaceId = flag('space') ?? readGatherSpace().spaceId;
  if (!spaceId) {
    console.error('no space to watch — pass --space <uuid>, or open a space in Gather once');
    process.exit(1);
  }
  const seconds = Number(flag('seconds') ?? 0);

  const url = `${GAME_SOCKET}?spaceId=${encodeURIComponent(spaceId)}&authUserId=${encodeURIComponent(authUserId ?? '')}`;
  console.log(`${bold('space')}     ${spaceId}`);
  console.log(`${bold('as')}        ${String(authUserId).slice(0, 12)}… ${dim('(observer — no enterSpace)')}`);
  console.log('');

  const ws = new WebSocket(url);
  ws.binaryType = 'arraybuffer';

  /** model -> row count, from the full state dump. */
  const census = new Map();
  /** model -> rows, for the suspects only. */
  const suspectRows = new Map();
  /** Our own SpaceUser id, so rows about us can be called out. */
  let selfId = null;

  let dumping = true;
  let settleTimer = null;
  let deltas = 0;
  const frameTypes = new Map();

  const finishDump = () => {
    dumping = false;
    report(census, suspectRows, selfId);
    console.log(bold('\n── watching deltas (every model, unfiltered) ─────────────────'));
    console.log(
      dim('now go raise your hand, get someone to wave, send a chat, invite yourself to a meeting…\n'),
    );
  };

  ws.addEventListener('open', () => {
    const handshake = [
      { type: 'Authenticate', credential: { type: 'JWT', jwt: token } },
      { type: 'ConnectToSpace', spaceId },
      { type: 'Subscribe' },
      {
        type: 'Action',
        txnId: randomUUID(),
        action: 'loadSpaceUser',
        args: ['SpaceUser', null, { connectionTarget: 'OfficeView', clientPlatform: 'Desktop' }],
      },
    ];
    for (const frame of handshake) ws.send(encode(frame));
    console.log(dim('handshake sent; waiting for the state dump…'));
    setInterval(() => {
      if (ws.readyState === 1) {
        ws.send(encode({ type: 'Heartbeat', timestamp: Date.now(), origin: 'Client' }));
      }
    }, HEARTBEAT_INTERVAL_MS).unref?.();
  });

  ws.addEventListener('message', (event) => {
    let frame;
    try {
      frame = decode(Buffer.from(event.data));
    } catch {
      return;
    }
    if (!frame || typeof frame !== 'object') return;

    const type = typeof frame.type === 'string' ? frame.type : '(untyped)';
    frameTypes.set(type, (frameTypes.get(type) ?? 0) + 1);
    if (type === 'Heartbeat') return;

    const full = Array.isArray(frame.fullStatePatches) ? frame.fullStatePatches : [];
    const delta = Array.isArray(frame.patches) ? frame.patches : [];

    for (const patch of full) {
      if (!patch || typeof patch.op !== 'string') continue;
      const model = patch.model;
      census.set(model, (census.get(model) ?? 0) + 1);
      if (patch.op === 'addmodel' && SUSPECTS.has(model)) {
        if (!suspectRows.has(model)) suspectRows.set(model, []);
        suspectRows.get(model).push(patch.data);
      }
      // Our own row, so delta lines can be marked as being about us.
      if (
        model === 'Connection' &&
        patch.op === 'addmodel' &&
        patch.data?.authUserId === authUserId &&
        typeof patch.data?.spaceUserId === 'string'
      ) {
        selfId = patch.data.spaceUserId;
      }
    }

    if (full.length > 0 && dumping) {
      if (settleTimer) clearTimeout(settleTimer);
      settleTimer = setTimeout(finishDump, DUMP_SETTLE_MS);
      settleTimer.unref?.();
    }

    for (const patch of delta) {
      if (!patch || typeof patch.op !== 'string') continue;
      deltas++;
      printDelta(patch, selfId);
    }

    // Anything that is neither a heartbeat nor a patch envelope. If a wave is a
    // bespoke frame type rather than a model patch, this is where it surfaces.
    if (full.length === 0 && delta.length === 0 && !dumping) {
      const keys = Object.keys(frame).filter((k) => k !== 'type');
      console.log(
        `${yellow('◆ frame')} ${bold(type)} ${dim(keys.join(', '))} ${dim(preview(frame, 400))}`,
      );
    }
  });

  ws.addEventListener('close', (event) => {
    console.log(`\nsocket closed: code=${event.code} reason=${JSON.stringify(event.reason)}`);
    console.log(`${deltas} delta patches; frames: ${[...frameTypes].map(([t, n]) => `${t}×${n}`).join(', ')}`);
    process.exit(0);
  });

  ws.addEventListener('error', () => console.log('socket error'));

  if (seconds > 0) {
    setTimeout(() => {
      console.log(dim(`\n--seconds ${seconds} elapsed`));
      ws.close();
    }, seconds * 1000).unref?.();
  }
}

/**
 * Field paths that are just the space breathing.
 *
 * Nothing is filtered out — a wave could hide in any of these — but a first run
 * showed 31 deltas of pure churn in five minutes, which is exactly the haystack
 * a real signal gets lost in. So the churn stays dim and everything else is
 * shouted about.
 */
const AMBIENT = new Set([
  '/connected',
  '/updatedAt',
  '/lastOnlineAt',
  '/userSetAvailability',
  '/syncing',
  '/lastSyncedAt',
  '/speaking',
  '/position',
  '/position/x',
  '/position/y',
  '/direction',
  '/clusterId',
]);

/** One delta patch, in full. The whole point is that nothing is filtered. */
function printDelta(patch, selfId) {
  const model = String(patch.model ?? '?');
  const about = selfId && JSON.stringify(patch).includes(selfId) ? green(' ←you') : '';

  // A replace on a path nobody has explained yet, or any new/removed row on a
  // model that is not the calendar churning: that is what we came for.
  const novel =
    patch.op === 'replace'
      ? !AMBIENT.has(String(patch.path))
      : model !== 'BaseCombinedCalendarEvent';
  if (novel) {
    console.log(
      `${yellow('★ NOVEL')} ${bold(model)}${about} ${patch.op} ${patch.path ?? ''} ` +
        `${preview(patch.op === 'addmodel' ? patch.data : (patch.data ?? patch.id), 600)}`,
    );
    return;
  }
  if (patch.op === 'addmodel') {
    console.log(`${cyan('+')} ${bold(model)}${about} ${preview(patch.data, 500)}`);
    return;
  }
  if (patch.op === 'deletemodel') {
    console.log(`${cyan('-')} ${bold(model)}${about} ${dim(String(patch.id))}`);
    return;
  }
  console.log(
    `${cyan('~')} ${bold(model)}${about} ${dim(String(patch.id).slice(0, 8))} ` +
      `${patch.path} = ${preview(patch.data, 300)}`,
  );
}

function report(census, suspectRows, selfId) {
  const rows = [...census.entries()].sort((a, b) => b[1] - a[1]);
  console.log(bold(`\n── state census: ${rows.length} models ───────────────────────`));
  console.log(dim(rows.map(([m, n]) => `${m}:${n}`).join('  ')));
  if (selfId) console.log(`\nour SpaceUser: ${bold(selfId)}`);

  console.log(bold('\n── suspect rows, decoded in full ────────────────────────────'));
  let found = false;
  for (const model of SUSPECTS) {
    const list = suspectRows.get(model);
    if (!list || list.length === 0) continue;
    found = true;
    console.log(`\n${bold(model)} ${dim(`(${list.length} row${list.length === 1 ? '' : 's'})`)}`);
    // ActivityEvent is the headline: print every row whole. The chattier models
    // get a sample, because 108 chat messages is not the question being asked.
    const show = model === 'ActivityEvent' ? list : list.slice(0, 4);
    for (const row of show) {
      const mine = selfId && JSON.stringify(row).includes(selfId) ? green(' ←you') : '';
      console.log(`  ${mine}${preview(row, 1200)}`);
    }
    if (show.length < list.length) console.log(dim(`  … ${list.length - show.length} more`));
  }
  if (!found) console.log(dim('  none of the suspect models had rows in this space'));

  if (!selfId) return;
  console.log(bold('\n── rows addressed to us ─────────────────────────────────────'));
  let mine = 0;
  for (const model of ABOUT_ME_MODELS) {
    for (const row of suspectRows.get(model) ?? []) {
      if (row?.spaceUserId !== selfId) continue;
      mine++;
      console.log(`  ${bold(model)} ${preview(row, 800)}`);
    }
  }
  if (mine === 0) console.log(dim('  nothing in these models names us'));
}

/** JSON, with Dates and msgpack symbols made readable. */
function preview(value, limit) {
  const text = JSON.stringify(
    value,
    (_key, v) => {
      if (v instanceof Date) return `<Date ${v.toISOString()}>`;
      if (typeof v === 'bigint') return `<bigint ${v}>`;
      if (typeof v === 'symbol') return '<undefined>';
      if (v instanceof Uint8Array) return `<${v.byteLength}B>`;
      return v;
    },
  );
  if (text == null) return String(value);
  return text.length > limit ? `${text.slice(0, limit)}…` : text;
}

main().catch((error) => {
  console.error(`probe failed: ${error.message}`);
  process.exit(1);
});
