import { chmodSync, mkdirSync, readFileSync, statSync, truncateSync, writeFileSync } from 'node:fs';
import { homedir, networkInterfaces } from 'node:os';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';

export const LABEL = 'com.jonasgrunau.gather-app-bridge';

/** Everything the daemon owns: its installed copy and its log. */
export const stateDir = join(homedir(), '.gather-app-bridge');
export const installDir = join(stateDir, 'bridge');
export const logFile = join(stateDir, 'bridge.log');
export const plistFile = join(homedir(), 'Library', 'LaunchAgents', `${LABEL}.plist`);

/**
 * Holds the pairing token and port. Kept outside `stateDir` on purpose:
 * `uninstall` deletes the whole install directory, and a phone that is already
 * paired must not have to be paired again after a reinstall.
 */
export const configFile = join(homedir(), '.gather-app-bridge.json');

/**
 * The Firebase service account that lets the bridge send push notifications.
 *
 * Kept out of the repo and out of `stateDir` for the same reason as the config:
 * it is a credential, it survives `uninstall`, and it is the user's to place.
 * `gather-app-bridge push setup <file>` copies one here at 0600.
 */
export const fcmKeyFile = join(homedir(), '.gather-app-bridge-fcm.json');

/**
 * Where the Gather V2 desktop client writes its log.
 *
 * Read for exactly one thing now — Gather's own notifications, see
 * `desktop-notifications.js`. Presence comes from the game socket and does not
 * need this file, or the desktop client, at all. electron-log caps it at 2 MB and
 * rolls it to `main.old.log`, which the tailer has to survive.
 */
export const gatherLogFile = join(homedir(), 'Library', 'Logs', 'GatherV2', 'main.log');

/** The client's own runtime config — tells us which space it last opened. */
export const gatherConfigFile = join(
  homedir(),
  'Library',
  'Application Support',
  'GatherV2',
  'config.json',
);

/**
 * Where the client's renderer persists its Firebase session.
 *
 * `gather-auth.js` reads a refresh token out of here once, to adopt the signed-in
 * session instead of running its own login. Read-only, and only ever read while
 * the direct collector is being set up.
 */
export const gatherIdbDir = join(
  homedir(),
  'Library',
  'Application Support',
  'GatherV2',
  'IndexedDB',
  'https_app.v2.gather.town_0.indexeddb.leveldb',
);

export function readConfig() {
  try {
    const j = JSON.parse(readFileSync(configFile, 'utf8'));
    return j && typeof j === 'object' ? j : {};
  } catch {
    return {};
  }
}

export function writeConfig(config) {
  writeFileSync(configFile, `${JSON.stringify(config, null, 2)}\n`);
  chmodSync(configFile, 0o600); // pairing secret — owner only
}

/** Returns the stored token, minting and persisting one on first run. */
export function ensureToken(override) {
  const config = readConfig();
  const token = override ?? config.token ?? randomBytes(24).toString('hex');
  if (token !== config.token) writeConfig({ ...config, token });
  return token;
}

export function ensureStateDir() {
  mkdirSync(stateDir, { recursive: true });
}

/**
 * Keeps the log from growing without bound over months of uptime. launchd
 * appends to a path it opened at spawn time, so truncating in place — rather
 * than renaming — is what keeps the running daemon writing to the same file.
 */
export function rotateLogIfLarge(maxBytes = 5 << 20) {
  try {
    if (statSync(logFile).size > maxBytes) truncateSync(logFile, 0);
  } catch {
    /* no log yet */
  }
}

/** Reads the space the desktop client last opened, for a nicer first paint. */
export function readGatherSpace() {
  try {
    const j = JSON.parse(readFileSync(gatherConfigFile, 'utf8'));
    const url = String(j.lastVisitedUrl ?? '');
    const id = /\/app\/([0-9a-f-]{36})/i.exec(url)?.[1] ?? null;
    return { spaceId: id, lastVisitedUrl: url || null };
  } catch {
    return { spaceId: null, lastVisitedUrl: null };
  }
}

/** Every non-loopback IPv4 address, most-likely-primary first. */
export function lanAddresses() {
  const out = [];
  for (const [name, addrs] of Object.entries(networkInterfaces())) {
    for (const a of addrs ?? []) {
      if (a.family !== 'IPv4' || a.internal) continue;
      if (a.address.startsWith('169.254.')) continue; // link-local, never routable
      out.push({ name, address: a.address });
    }
  }
  // en0 is Wi-Fi on every Mac; utun/bridge interfaces are almost never the one.
  out.sort((a, b) => rank(a.name) - rank(b.name));
  return out.map((x) => x.address);
}

function rank(name) {
  if (name === 'en0') return 0;
  if (name.startsWith('en')) return 1;
  if (name.startsWith('bridge') || name.startsWith('utun') || name.startsWith('llw')) return 3;
  return 2;
}
