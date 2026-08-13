/**
 * Decides which events are worth waking a locked phone for, and sends them.
 *
 * The app's own notifications only exist while it is running. This is the path
 * that survives the app being suspended or killed, so the bar is higher: every
 * push here is something a person would want to be interrupted by, and nothing
 * else. Getting that wrong is how an app ends up muted permanently.
 *
 * ## What is enabled, and why
 *
 *  - **wave** — rare, always deliberate, always means somebody wants you. The
 *    strongest case there is.
 *  - **meeting invite**, **event reminder** — scheduled, few, and time-bound.
 *  - **meeting join request** — somebody knocking on a meeting and waiting. The
 *    only one with a deadline: on the observed sample the gap between the request
 *    and the answer was two seconds, so it is worthless late.
 *  - **follow.started** — rare and unambiguous, and the reason this app exists.
 *
 * All of them are deliberate acts by a person. That is the bar, and it is why there
 * is no rate limiting here — with one exception, the wave *button*, which is
 * debounced in `server.js` because one person produced 41 waves in eight seconds.
 *
 * ## Foreground double-ups
 *
 * Not handled here, deliberately. When the app is in the foreground its
 * WebSocket is live and it raises its own local notification; the push arrives
 * too. iOS does not display a push while the app is frontmost unless the app
 * asks it to, and ours does not — so the duplicate is swallowed on the phone,
 * where the knowledge of "am I on screen right now" actually lives.
 */

import { readConfig, writeConfig } from './paths.js';

/** Which reasons push by default. Overridable per-install via config. */
export const PUSH_DEFAULTS = Object.freeze({
  wave: true,
  'meeting invite': true,
  'event reminder': true,
  follow: true,
});

/**
 * How long a device may go without re-registering before it is dropped.
 *
 * A last resort, and generous on purpose. `registeredAt` only refreshes when the
 * phone can reach this daemon over the LAN, so somebody working remotely for a
 * month has a perfectly live token that never re-registers — ageing them out
 * aggressively would break push for exactly the people who need it. The real
 * defence against a stale token is `installId` below, which replaces rather than
 * accumulates, and `UNREGISTERED` from FCM. Overridable via
 * `push.staleAfterDays`.
 */
export const STALE_AFTER_DAYS = 60;

/**
 * The phones that have asked to be told.
 *
 * Persisted in the same config file as the pairing token, because a bridge that
 * forgot every device on restart would silently stop pushing after a Node
 * upgrade — and the failure would look like "push does not work" rather than
 * "push needs re-pairing".
 */
export class PushRegistry {
  /**
   * `read` and `write` are the test seam. They default to the real config file,
   * and the suite must always replace them — a test that registered a device for
   * real would rewrite the developer's own `~/.gather-app-bridge.json`.
   */
  constructor({ log = () => {}, read = readConfig, write = writeConfig } = {}) {
    this.log = log;
    this._read = read;
    this._write = write;
  }

  list() {
    const devices = this._read().push?.devices;
    return Array.isArray(devices) ? devices.filter((d) => d && typeof d.token === 'string') : [];
  }

  /**
   * Adds or refreshes one device. Returns the resulting device count.
   *
   * Keyed on `installId` when the app sends one, falling back to the token. The
   * difference matters: a reinstalled app gets a *new* FCM token, so keying on the
   * token alone left the previous install's dead token in the list, absorbing every
   * push while FCM answered 200 and nothing arrived. Keying on the install replaces
   * it. The fallback keeps older app builds registering.
   */
  register({ token, platform = 'ios', installId = null }) {
    if (typeof token !== 'string' || token.length < 32) {
      throw new Error('that does not look like a push token');
    }
    const config = this._read();
    const previous = this.list();
    const id = typeof installId === 'string' && installId ? installId : null;
    const devices = previous.filter((d) =>
      id ? d.installId !== id && d.token !== token : d.token !== token,
    );
    const replaced = previous.find((d) => (id ? d.installId === id : d.token === token));
    devices.push({
      token,
      platform,
      ...(id ? { installId: id } : {}),
      registeredAt: new Date().toISOString(),
      // Carried across a re-registration so ageing sees the whole history, not just
      // the most recent handshake.
      ...(replaced?.lastSentAt ? { lastSentAt: replaced.lastSentAt } : {}),
    });
    this._write({ ...config, push: { ...config.push, devices } });

    // Quiet when nothing changed. The app re-registers on every resume, and a line
    // per resume buried the one registration that mattered under thirty that did
    // not.
    if (!replaced) this.log(`push: registered a ${platform} device (${devices.length} total)`);
    else if (replaced.token !== token) this.log(`push: a ${platform} device rotated its token`);
    return devices.length;
  }

  /** Records that a push actually went to this device. */
  sent(token) {
    const config = this._read();
    const devices = this.list().map((d) =>
      d.token === token ? { ...d, lastSentAt: new Date().toISOString() } : d,
    );
    this._write({ ...config, push: { ...config.push, devices } });
  }

  /**
   * Drops devices that have neither re-registered nor been pushed to in a long
   * while. Returns how many went.
   */
  prune({ staleAfterDays = this.staleAfterDays(), now = Date.now() } = {}) {
    const cutoff = now - staleAfterDays * 86_400_000;
    const devices = this.list();
    const kept = devices.filter((d) => {
      const seen = Date.parse(d.lastSentAt ?? d.registeredAt ?? '');
      // An entry with no readable date is kept: it predates this field, and
      // guessing it is stale would unregister a working phone.
      return Number.isNaN(seen) || seen >= cutoff;
    });
    if (kept.length === devices.length) return 0;
    const config = this._read();
    this._write({ ...config, push: { ...config.push, devices: kept } });
    const dropped = devices.length - kept.length;
    this.log(`push: dropped ${dropped} device(s) not seen in ${staleAfterDays} days`);
    return dropped;
  }

  staleAfterDays() {
    const configured = this._read().push?.staleAfterDays;
    return typeof configured === 'number' && configured > 0 ? configured : STALE_AFTER_DAYS;
  }

  /** Forgets a token FCM told us is dead. */
  forget(token) {
    const config = this._read();
    const devices = this.list().filter((d) => d.token !== token);
    this._write({ ...config, push: { ...config.push, devices } });
    this.log('push: dropped a device FCM reported as unregistered');
  }

  /** Which reasons are enabled, config overriding the defaults. */
  kinds() {
    return { ...PUSH_DEFAULTS, ...(this._read().push?.kinds ?? {}) };
  }
}

export class PushNotifier {
  /**
   * @param {{ sender: import('./fcm.js').FcmSender|null, registry?: PushRegistry,
   *           log?: Function, now?: () => number }} options
   */
  constructor({ sender, registry = null, log = () => {} }) {
    this.sender = sender;
    this.registry = registry ?? new PushRegistry({ log });
    this.log = log;
  }

  get enabled() {
    return this.sender != null;
  }

  /**
   * Turns one event into a push, or decides it is not worth one.
   *
   * Returns the notification that was sent (for tests and logging), or null.
   *
   * @param {object} event
   * @param {(id: string) => string} nameFor resolves a player id to a display name
   */
  async consider(event, nameFor = (id) => id) {
    if (!this.sender) return null;
    const note = describe(event, nameFor);
    if (!note) return null;
    if (!this.registry.kinds()[note.kind]) return null;

    this.registry.prune();
    const devices = this.registry.list();
    if (devices.length === 0) {
      // Worth saying. This is the shape of "push is set up and doing nothing",
      // which otherwise looks identical to no events happening.
      this.log(`push: nothing to send "${note.title}" to — no device has registered`);
      return null;
    }

    let sent = 0;
    for (const device of devices) {
      try {
        const result = await this.sender.send({
          token: device.token,
          title: note.title,
          body: note.body,
          data: { type: event.type, kind: note.kind },
          collapseId: note.collapseId,
        });
        if (result.ok) {
          sent++;
          this.registry.sent(device.token);
        } else if (result.drop) this.registry.forget(device.token);
        else this.log(`push failed: ${result.detail}`);
      } catch (error) {
        // Never let a push failure break the event pipeline — the phone that is
        // actually connected must keep receiving over the socket regardless.
        this.log(`push failed: ${error.message}`);
      }
    }

    // Logged on success as well as failure, and this is not noise. FCM answers 200
    // for a token whose app has been reinstalled, so "accepted" and "arrived" are
    // different claims — without this line there was no evidence a push was ever
    // attempted, and a fortnight of them went nowhere unnoticed.
    if (sent > 0) this.log(`push: sent "${note.title}" to ${sent} device(s)`);
    return note;
  }
}

/** The kinds that carry a sender, and how to word them with a name. */
function namedWording(type, who) {
  return {
    wave: `${who} waved at you`,
    'meeting invite': `${who} invited you to a meeting`,
    'meeting join request': `${who} is asking to join your meeting`,
  }[type];
}

/**
 * The sentence a person reads on their lock screen, or null for "not worth it".
 *
 * Separated from sending so the policy is testable without a network at all.
 */
export function describe(event, nameFor = (id) => id) {
  switch (event.type) {
    case 'follow.started': {
      if (!event.targetIsSelf) return null;
      const who = nameFor(event.followerId);
      return {
        kind: 'follow',
        title: 'Someone is following you',
        body: `${who} started following you`,
        collapseId: `follow-${event.followerId}`,
      };
    }

    case 'notification.shown': {
      const type = event.notificationType;
      // Gather has only ever sent a bare `type` in every sample seen, so these
      // are our sentences. An unrecognised type is deliberately not pushed: it
      // has no wording, and guessing wrong on a lock screen is worse than
      // silence. It still reaches the feed over the socket.
      const wording = {
        wave: ['Someone waved at you', 'Someone is trying to get your attention in Gather'],
        'meeting invite': ['Meeting invite', 'You have been invited to a meeting'],
        'meeting join request': ['Someone wants to join', 'Somebody is asking to join your meeting'],
        'event reminder': ['Event reminder', 'An event on your calendar is starting'],
      }[type];
      if (!wording) return null;

      // Anything off the game socket carries `senderId`, so it can say who. The
      // log-scraped kinds never could — the IPC line has only a type — which is why
      // the fallback wording is as vague as it is.
      const who = event.senderId ? nameFor(event.senderId) : null;
      return {
        kind: type,
        title: event.title ?? wording[0],
        body: event.body ?? (who ? namedWording(type, who) ?? wording[1] : wording[1]),
        // Collapsed per sender when we know them, so two different people waving
        // do not overwrite each other on the lock screen.
        collapseId: event.senderId ? `gather-${type}-${event.senderId}` : `gather-${type}`,
      };
    }

    default:
      return null;
  }
}
