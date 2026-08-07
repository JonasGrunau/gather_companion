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
 * ## The two signals
 *
 *  - **Someone is following me** — `SpaceUser.followTargetId` pointing at my own
 *    row. It is an optional column, so it is *absent* rather than null when
 *    nobody is following, and shows up as a `replace` on `/followTargetId`. The
 *    official client derives followers the same way, filtering `usersInOffice` by
 *    `followTargetId === this.id`.
 *  - **Someone is standing next to me** — `position` (integer tiles) compared
 *    with mine, requiring the same `floorId`. `clusterId` is likewise optional and
 *    only present while a cluster exists.
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
const MODELS = new Set(['SpaceUser', 'Connection', 'UserAccount', 'Space']);

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
  'clusterId',
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

    /** The space's display name, from the single `Space` row in the dump. */
    this.spaceName = null;

    this._frameTypes = new Map();
    this._unknownFrames = 0;
    this._patchCount = 0;
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

    const patches = collectPatches(frame);
    if (patches.length === 0) {
      // Frames that legitimately carry no model state (Authenticate, Subscribe,
      // SpaceStatus, …). Counted so a genuinely unrecognised envelope is visible
      // in stats() rather than silently ignored.
      this._unknownFrames++;
      return false;
    }

    let changed = false;
    for (const patch of patches) {
      if (this._applyPatch(patch)) changed = true;
    }
    if (changed || this.selfId == null) this._identifySelf();
    return changed;
  }

  _applyPatch(patch) {
    const model = patch.model;
    if (!MODELS.has(model)) return false;
    this._patchCount++;

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

    // Both of these are optional columns: absent means "not set", so only touch
    // them when the key is actually present.
    if ('clusterId' in data) set('clusterId', nullableString(data.clusterId));
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
      // Recording clients and bots are not people standing next to you.
      if (row.isBot === true || row.kind === 'RecordingClient') continue;
      rows.push({
        id: row.id,
        name: row.name ?? null,
        x: row.x ?? null,
        y: row.y ?? null,
        clusterId: row.clusterId ?? null,
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
 * Pulls the patch arrays out of a frame.
 *
 * `FullStateChunk` uses `fullStatePatches`, `DeltaState` uses `patches`. Both are
 * read explicitly; anything else is left alone rather than guessed at, so a new
 * envelope shows up as an unrecognised frame in `stats()`.
 */
function collectPatches(frame) {
  const out = [];
  for (const key of ['fullStatePatches', 'patches']) {
    const list = frame[key];
    if (!Array.isArray(list)) continue;
    for (const patch of list) {
      if (patch && typeof patch === 'object' && typeof patch.op === 'string') out.push(patch);
    }
  }
  return out;
}

function nullableString(value) {
  return typeof value === 'string' && value ? value : null;
}

function asBool(value) {
  return typeof value === 'boolean' ? value : null;
}
