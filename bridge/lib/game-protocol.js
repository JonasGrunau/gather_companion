/**
 * Interprets Gather V2's game-server protocol.
 *
 * One binary WebSocket to
 * `wss://game-router.v2.gather.town/gather-game-v2?spaceId=<uuid>&authUserId=<firebaseUid>`
 * carrying msgpack frames. `DirectCollector` opens it and authenticates as the
 * user, then stops at `loadSpaceUser` — it never sends `enterSpace`, so it reads
 * the whole space without showing up as a presence in it.
 *
 * ## Verified wire format
 *
 * Captured from a live authenticated session (handshake in order:
 * `Authenticate` → `ConnectToSpace` → `Subscribe` → `SpaceStatus` →
 * `FullStateChunk` ×N, then `DeltaState` and `Action`, with `Heartbeat` ~1/s).
 *
 * State arrives as patches against model rows, in two envelopes:
 *   - `FullStateChunk.fullStatePatches[]` — the initial dump, sent once per
 *     connection, ~1500 patches per chunk across ~45 models.
 *   - `DeltaState.patches[]` — everything after that.
 *
 * Three patch ops exist, and they are *not* JSON-Patch:
 *   - `{op:'addmodel',    model, data}`            whole row; the id is inside `data`
 *   - `{op:'deletemodel', model, id}`              row removed
 *   - `{op:'replace',     model, id, path, data}`  one field, e.g. `/position/x`
 *
 * ## The signal
 *
 * **Someone is following me** — `SpaceUser.followTargetId` pointing at my own
 * row. It is an optional column, so it is *absent* rather than null when nobody
 * is following, and shows up as a `replace` on `/followTargetId`. The official
 * client derives followers the same way, filtering `usersInOffice` by
 * `followTargetId === this.id`.
 *
 * `position` and `floorId` are still tracked, but no longer to judge who is near
 * whom — party mode reads them to learn which tiles a body fits on, and which
 * floor it is standing on.
 *
 * ## The event bus, which was here all along
 *
 * `DeltaState` carries a **third** array beside `patches`: `events[]`. It is a
 * genuine event bus — news rather than state — and it looks like this:
 *
 *   {type:'DeltaState', patches:[], actionReturns:[], sequenceNumber:17059,
 *    events:[{payload:{eventName:'WaveEvent',
 *                      senderId:'<their SpaceUser id>',
 *                      sentTime:'2026-08-07T14:22:20.563Z'},
 *             options:{targetUserIds:['<my SpaceUser id>']}}]}
 *
 * Measured 2026-08-07: 41 `WaveEvent`s, every one carrying `targetUserIds` naming
 * us, and 45 `ChatBroadcastNewMessage`es, all on an **observer** connection — so
 * `enterSpace` is not required to hear them.
 *
 * This corrects a long-standing and expensive mistake. The patch reader looked only
 * at `fullStatePatches` and `patches`, so a frame carrying nothing but `events[]`
 * fell straight through to `_unknownFrames++`. Every wave had been arriving on
 * this socket from the beginning and being tallied as an unrecognised envelope —
 * while `desktop-notifications.js` was built to scrape the same waves back out of
 * the desktop client's log file, where they arrive later and without a sender.
 *
 * The lesson worth keeping: `unknownFrames` in `stats()` is not noise. It was
 * pointing at this for weeks.
 *
 * ## Identity
 *
 * Which row is *me* is answered by the `Connection` model, which carries both
 * halves: `{authUserId: <firebase uid>, spaceUserId: <my SpaceUser id>}`. The
 * firebase uid comes from our own ID token. `UserAccount` (`{id, firebaseAuthId}`)
 * plus `SpaceUser.userAccountId` gives a second, slower route in case no
 * Connection row is seen.
 */

/** Only these models matter; a full state dump is mostly calendars and catalogs. */
const MODELS = new Set([
  'SpaceUser',
  'Connection',
  'UserAccount',
  'Space',
  // Meetings, for the two things somebody can do *at* you that Gather records as
  // state rather than sending over the event bus. See `MeetingWatch`.
  'MeetingParticipant',
  'MeetingJoinRequest',
]);

/**
 * SpaceUser fields worth tracking, for field-level `replace` patches.
 *
 * `speaking` earns its place: measured over three minutes on a 111-person space
 * it was the most frequent delta of any kind (13 of 46 patches). It is live voice
 * activity — who is actually talking — and it is the nearest thing Gather's state
 * has to the mic/camera booleans that only ever existed in the client's log.
 */
const TRACKED_FIELDS = new Set([
  'followTargetId',
  'position',
  'floorId',
  'name',
  'connected',
  'isIdle',
  'speaking',
  'userAccountId',
]);

export class GameProtocolReader {
  constructor({ log = () => {} } = {}) {
    this.log = log;

    /** @type {Map<string, object>} SpaceUser id -> row we have assembled. */
    this.users = new Map();
    /** My own SpaceUser id, once identified. */
    this.selfId = null;
    /** Firebase uid, supplied by the CDP collector from IndexedDB. */
    this.authUserId = null;
    this.spaceId = null;

    /** UserAccount id belonging to me, the slower route to `selfId`. */
    this._myUserAccountId = null;

    /** Meetings, for the two things somebody can do at you that are state, not bus. */
    this.meetings = new MeetingWatch();

    /** The space's display name, from the single `Space` row in the dump. */
    this.spaceName = null;

    /**
     * Interaction events read off `DeltaState.events[]`, waiting to be drained.
     *
     * Queued rather than emitted, so `ingest`'s "did the roster change" boolean
     * keeps its meaning — a wave changes no state at all. `DirectCollector` takes
     * them after every frame and publishes them immediately: they are news, and
     * the roster's 250ms coalescing window is the wrong place for news.
     */
    this.pending = [];

    this._frameTypes = new Map();
    this._unknownFrames = 0;
    this._patchCount = 0;
    this._busEvents = 0;
  }

  /** Hands over the queued interaction events and forgets them. */
  takePending() {
    if (this.pending.length === 0) return [];
    const out = this.pending;
    this.pending = [];
    return out;
  }

  /** Learns identity hints from the WebSocket URL the client opened. */
  noteSocketUrl(url) {
    try {
      const parsed = new URL(url);
      this.authUserId = parsed.searchParams.get('authUserId') ?? this.authUserId;
      this.spaceId = parsed.searchParams.get('spaceId') ?? this.spaceId;
    } catch {
      /* not a URL we can read */
    }
  }

  stats() {
    return {
      users: this.users.size,
      selfId: this.selfId,
      spaceId: this.spaceId,
      patches: this._patchCount,
      busEvents: this._busEvents,
      unknownFrames: this._unknownFrames,
      frameTypes: [...this._frameTypes.entries()]
        .sort((a, b) => b[1] - a[1])
        .slice(0, 12)
        .map(([type, n]) => `${type}:${n}`),
    };
  }

  /**
   * Feed one decoded frame. Returns true when the roster changed in a way worth
   * republishing.
   */
  ingest(frame) {
    if (frame == null || typeof frame !== 'object') return false;

    const type = typeof frame.type === 'string' ? frame.type : '(untyped)';
    this._frameTypes.set(type, (this._frameTypes.get(type) ?? 0) + 1);

    // Heartbeats are the bulk of the traffic and carry nothing.
    if (type === 'Heartbeat') return false;

    // Before the patches, because a wave arrives in a frame whose `patches` array
    // is empty — which is exactly how it went unnoticed for so long.
    const bus = collectBusEvents(frame);
    for (const event of bus) {
      this.pending.push(event);
      this._busEvents++;
    }

    // The dump and the deltas are read separately, because for anything
    // event-shaped the difference is the whole signal. `MeetingParticipant` rows
    // arrive in both: 56 of them in the measured space, four naming us. Treating a
    // dump row as news would announce every meeting the user has ever been invited
    // to, on every reconnect.
    const dump = patchesIn(frame.fullStatePatches);
    const deltas = patchesIn(frame.patches);
    if (dump.length === 0 && deltas.length === 0) {
      // Frames that legitimately carry no model state (Authenticate, Subscribe,
      // SpaceStatus, …). Counted so a genuinely unrecognised envelope is visible
      // in stats() rather than silently ignored — but a frame we *did* understand
      // as an interaction is not unrecognised.
      if (bus.length === 0) this._unknownFrames++;
      return false;
    }

    let changed = false;
    for (const patch of dump) {
      if (this._applyPatch(patch, false)) changed = true;
    }
    for (const patch of deltas) {
      if (this._applyPatch(patch, true)) changed = true;
    }
    if (changed || this.selfId == null) this._identifySelf();

    // Identity can arrive after the rows that depend on it — `Connection` is one
    // patch among ~1500 — so anything we could not judge at the time is reconsidered
    // once we know who we are.
    if (this.selfId) this.meetings.resolvePending(this.selfId, this.pending);
    return changed;
  }

  _applyPatch(patch, isNews) {
    const model = patch.model;
    if (!MODELS.has(model)) return false;
    this._patchCount++;

    if (model === 'MeetingParticipant' || model === 'MeetingJoinRequest') {
      this.meetings.apply(model, patch, isNews, this.selfId, this.pending);
      // Never "the roster changed": meetings are not people standing in a room, and
      // republishing a 79-row snapshot because a calendar row moved is exactly the
      // traffic the coalescing window exists to prevent.
      return false;
    }

    switch (patch.op) {
      case 'addmodel':
        return this._addModel(model, patch.data);
      case 'deletemodel':
        return this._deleteModel(model, patch.id);
      case 'replace':
        return this._replaceField(model, patch);
      default:
        return false;
    }
  }

  _addModel(model, data) {
    if (data == null || typeof data !== 'object' || typeof data.id !== 'string') return false;

    if (model === 'SpaceUser') return this._merge(this._row(data.id), data);

    if (model === 'Connection') {
      // The direct answer to "which SpaceUser am I".
      if (
        this.authUserId &&
        data.authUserId === this.authUserId &&
        typeof data.spaceUserId === 'string'
      ) {
        if (this.selfId !== data.spaceUserId) {
          this.selfId = data.spaceUserId;
          this.log(`game protocol: own space user ${data.spaceUserId} (via Connection)`);
          return true;
        }
      }
      return false;
    }

    if (model === 'UserAccount') {
      if (this.authUserId && data.firebaseAuthId === this.authUserId) {
        this._myUserAccountId = data.id;
        return true;
      }
      return false;
    }

    if (model === 'Space') {
      // Exactly one row, and it is the space we asked for. Its name used to come
      // out of the desktop client's IPC log; it is cheaper and more reliable here.
      if (typeof data.name === 'string' && data.name !== this.spaceName) {
        this.spaceName = data.name;
        return true;
      }
      return false;
    }

    return false;
  }

  _deleteModel(model, id) {
    if (model !== 'SpaceUser' || typeof id !== 'string') return false;
    const row = this.users.get(id);
    if (!row) return false;
    row.connected = false;
    row.gone = true;
    return true;
  }

  _replaceField(model, patch) {
    if (model !== 'SpaceUser') return false;

    const segments = String(patch.path ?? '')
      .split('/')
      .filter(Boolean);
    const id = typeof patch.id === 'string' ? patch.id : null;
    if (!id || segments.length === 0) return false;

    // Paths are addressed to the row, so the field is the first segment. Position
    // mutates component-wise, giving `/position/x` — reading only the last
    // segment would silently drop every walking patch.
    const field = segments[0];
    if (!TRACKED_FIELDS.has(field)) return false;

    const row = this._row(id);
    const sub = segments.slice(1);

    if (sub.length === 0) return this._merge(row, { [field]: patch.data });

    if (field === 'position' && (sub[0] === 'x' || sub[0] === 'y')) {
      if (typeof patch.data !== 'number') return false;
      return this._merge(row, { [`position__${sub[0]}`]: patch.data });
    }

    return false;
  }

  _row(id) {
    let row = this.users.get(id);
    if (!row) {
      row = { id, name: null, x: null, y: null, floorId: null };
      this.users.set(id, row);
    }
    return row;
  }

  _merge(row, data) {
    if (data == null || typeof data !== 'object') return false;
    let changed = false;

    const set = (key, value) => {
      if (value === undefined || row[key] === value) return;
      row[key] = value;
      changed = true;
    };

    if ('name' in data) set('name', typeof data.name === 'string' ? data.name : null);
    if ('userAccountId' in data) set('userAccountId', nullableString(data.userAccountId));
    if ('floorId' in data) set('floorId', nullableString(data.floorId));
    if ('connected' in data) set('connected', asBool(data.connected));
    if ('isIdle' in data) set('isIdle', asBool(data.isIdle));
    if ('speaking' in data) set('speaking', asBool(data.speaking));
    if ('isBot' in data) set('isBot', asBool(data.isBot));
    if ('type' in data) set('kind', nullableString(data.type));

    // An optional column: absent means "not set", so only touch it when the key
    // is actually present. `presence.js` tells absent from null to decide whether
    // following is answerable at all.
    if ('followTargetId' in data) set('followTargetId', nullableString(data.followTargetId));

    // Position arrives as a value object: { $type: 'Position', x, y }.
    const position = data.position;
    if (position && typeof position === 'object') {
      if (typeof position.x === 'number') set('x', position.x);
      if (typeof position.y === 'number') set('y', position.y);
    }
    if (typeof data.position__x === 'number') set('x', data.position__x);
    if (typeof data.position__y === 'number') set('y', data.position__y);

    return changed;
  }

  /** Fallback route to identity when no Connection row named us. */
  _identifySelf() {
    if (this.selfId || !this._myUserAccountId) return;
    for (const row of this.users.values()) {
      if (row.userAccountId && row.userAccountId === this._myUserAccountId) {
        this.selfId = row.id;
        this.log(`game protocol: own space user ${row.id} (via UserAccount)`);
        return;
      }
    }
  }

  /** The roster in the shape `PresenceTracker.applyRoster` consumes. */
  roster() {
    const rows = [];
    for (const row of this.users.values()) {
      // Recording clients and bots are not people who can follow you.
      if (row.isBot === true || row.kind === 'RecordingClient') continue;
      rows.push({
        id: row.id,
        name: row.name ?? null,
        // Kept for party mode's walkable-tile pool, not for judging adjacency.
        x: row.x ?? null,
        y: row.y ?? null,
        floorId: row.floorId ?? null,
        connected: row.gone ? false : (row.connected ?? null),
        speaking: row.speaking ?? null,
        ...('followTargetId' in row ? { followTargetId: row.followTargetId ?? null } : {}),
      });
    }
    return { selfId: this.selfId, rows, spaceName: this.spaceName };
  }
}

/**
 * One patch array out of a frame.
 *
 * `FullStateChunk` uses `fullStatePatches`, `DeltaState` uses `patches`. They are
 * read separately rather than merged, because for anything event-shaped the
 * difference between "this is how the world already was" and "this just happened"
 * is the entire signal.
 */
function patchesIn(list) {
  if (!Array.isArray(list)) return [];
  return list.filter((p) => p && typeof p === 'object' && typeof p.op === 'string');
}

/**
 * Watches the meeting models for the two things somebody can do *at* you that
 * Gather records as state rather than sending over the event bus.
 *
 *  - **An invite.** `MeetingParticipant{spaceUserId: <you>, inviterId: <them>}`.
 *  - **A knock.** `MeetingJoinRequest{spaceUserId: <them>, meetingId}` with no
 *    `respondedAt` — somebody asking to be let in and waiting on an answer. On the
 *    observed sample the gap between request and answer was two seconds, so this is
 *    the one signal here that is worthless late.
 *
 * Both are surfaced as bus events so they travel the same path as a wave.
 */
export class MeetingWatch {
  constructor() {
    /** Meetings we are a participant of, so somebody else's knock is not ours. */
    this.mine = new Set();
    /** Row ids already seen, so a re-sent row is not a second invitation. */
    this.known = new Set();
    /** Rows that arrived before we knew which SpaceUser we are. */
    this.undecided = [];
  }

  apply(model, patch, isNews, selfId, out) {
    // Updates and deletions carry nothing we report: a response being recorded on
    // an invite is the *answer*, not a new question.
    if (patch.op !== 'addmodel') return;
    const data = patch.data;
    if (!data || typeof data !== 'object' || typeof data.id !== 'string') return;

    const firstSighting = !this.known.has(data.id);
    this.known.add(data.id);

    // Learn which meetings are ours wherever the row came from: the dump is exactly
    // how we know which meetings we were already in.
    if (model === 'MeetingParticipant' && selfId && data.spaceUserId === selfId) {
      if (typeof data.meetingId === 'string') this.mine.add(data.meetingId);
    }

    if (!isNews || !firstSighting) return;
    if (!selfId) {
      this.undecided.push({ model, data });
      return;
    }
    const event = this._judge(model, data, selfId);
    if (event) out.push(event);
  }

  /** Re-reads what arrived before we knew who we were. */
  resolvePending(selfId, out) {
    if (this.undecided.length === 0) return;
    const pending = this.undecided;
    this.undecided = [];
    for (const { model, data } of pending) {
      if (data.spaceUserId === selfId && typeof data.meetingId === 'string') {
        this.mine.add(data.meetingId);
      }
      const event = this._judge(model, data, selfId);
      if (event) out.push(event);
    }
  }

  _judge(model, data, selfId) {
    if (model === 'MeetingParticipant') {
      // Ours, and somebody put us there — a row we created by walking into a room
      // has no `inviterId`, and is not an invitation.
      if (data.spaceUserId !== selfId) return null;
      if (typeof data.inviterId !== 'string' || !data.inviterId) return null;
      return {
        name: 'MeetingInvite',
        senderId: data.inviterId,
        sentTime: asIsoString(data.createdAt),
        targetUserIds: [selfId],
        payload: data,
      };
    }

    const asker = data.spaceUserId;
    if (typeof asker !== 'string' || asker === selfId) return null;
    // Asked positively, because "absent" here is msgpack `undefined` rather than
    // null — a `!= null` test would read every unanswered knock as already answered.
    if (asIsoString(data.respondedAt)) return null;
    if (typeof data.meetingId !== 'string' || !this.mine.has(data.meetingId)) return null;
    return {
      name: 'MeetingJoinRequest',
      senderId: asker,
      sentTime: asIsoString(data.createdAt),
      targetUserIds: [selfId],
      payload: data,
    };
  }
}

/**
 * Pulls interaction events out of `DeltaState.events[]`.
 *
 * Normalised rather than passed through raw, because the two things a caller
 * always needs — who did it, and was it aimed at me — sit in different halves of
 * the envelope: `payload.senderId` and `options.targetUserIds`. The untouched
 * payload rides along under `payload` so a new `eventName` needs no change here
 * to be readable.
 *
 * `sentTime` is normalised to an ISO string. Gather sends it as a plain string
 * today, but `createdAt`-style fields on this protocol are msgpack ext-1 Dates,
 * and a caller that has to test which one it got would get it wrong eventually.
 */
function collectBusEvents(frame) {
  const list = frame.events;
  if (!Array.isArray(list)) return [];

  const out = [];
  for (const entry of list) {
    const payload = entry?.payload;
    if (!payload || typeof payload !== 'object') continue;
    if (typeof payload.eventName !== 'string') continue;

    const targets = entry.options?.targetUserIds;
    out.push({
      name: payload.eventName,
      senderId: nullableString(payload.senderId),
      sentTime: asIsoString(payload.sentTime),
      targetUserIds: Array.isArray(targets) ? targets.filter((id) => typeof id === 'string') : [],
      payload,
    });
  }
  return out;
}

function asIsoString(value) {
  if (value instanceof Date) return value.toISOString();
  if (typeof value === 'string' && value) return value;
  if (typeof value === 'number') return new Date(value).toISOString();
  return null;
}

function nullableString(value) {
  return typeof value === 'string' && value ? value : null;
}

function asBool(value) {
  return typeof value === 'boolean' ? value : null;
}
