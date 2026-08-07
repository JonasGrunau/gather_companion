#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { chmodSync, copyFileSync, createReadStream, existsSync, readFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { join } from 'node:path';

import { flagValue, parseCommand, parsePort } from '../lib/cli-args.js';
import { DesktopNotificationReader } from '../lib/desktop-notifications.js';
import { FcmSender, readServiceAccount } from '../lib/fcm.js';
import { adoptDesktopSession, gatherUid, hasGatherSession } from '../lib/gather-auth.js';
import * as launchd from '../lib/launchd.js';
import { pairPayload } from '../lib/pairing.js';
import { PushRegistry } from '../lib/push.js';
import { render as renderQr } from '../lib/qr.js';
import {
  ensureStateDir,
  ensureToken,
  fcmKeyFile,
  gatherLogFile,
  lanAddresses,
  logFile,
  readConfig,
  readGatherSpace,
  rotateLogIfLarge,
  writeConfig,
} from '../lib/paths.js';
import { BridgeServer, DEFAULT_PORT } from '../lib/server.js';

const argv = process.argv.slice(2);
const command = parseCommand(argv, launchd.supported ? 'install' : 'run');

/** Name of the binary npm links on install. */
const CLI = 'gather-app-bridge';
const INVOKE = `npx ${CLI}`;

const GATHER_BINARY = '/Applications/GatherV2.app/Contents/MacOS/GatherV2';

const dim = (s) => `\x1b[2m${s}\x1b[0m`;
const bold = (s) => `\x1b[1m${s}\x1b[0m`;
const green = (s) => `\x1b[32m${s}\x1b[0m`;
const red = (s) => `\x1b[31m${s}\x1b[0m`;
const yellow = (s) => `\x1b[33m${s}\x1b[0m`;

try {
  await main();
} catch (e) {
  console.error(red(`\n  ${e?.message ?? e}\n`));
  process.exit(1);
}

async function main() {
  // With no bare word in argv the default command is `install`, and `--version`
  // must not quietly reinstall the daemon.
  if (argv.includes('-h') || argv.includes('--help')) return usage();
  if (argv.includes('-v') || argv.includes('--version')) return console.log(version());

  switch (command) {
    case 'install':
      return cmdInstall();
    case 'run':
      return cmdRun();
    case 'start':
      return cmdSimple(launchd.start, 'started');
    case 'stop':
      return cmdSimple(launchd.stop, 'stopped');
    case 'restart':
      return cmdSimple(launchd.restart, 'restarted');
    case 'status':
      return cmdStatus();
    case 'logs':
      return cmdLogs();
    case 'uninstall':
      return cmdUninstall();
    case 'token':
      return cmdToken();
    case 'adopt':
      return cmdAdopt();
    case 'doctor':
      return cmdDoctor();
    case 'resync':
      return cmdResync();
    case 'watch':
      return cmdWatch();
    case 'pair':
      return cmdPair();
    case 'replay':
      return cmdReplay();
    case 'push':
      return cmdPush();
    case 'help':
      return usage();
    default:
      console.error(red(`  unknown command: ${command}`));
      usage();
      process.exit(1);
  }
}

// ---- commands ---------------------------------------------------------------

async function cmdInstall() {
  if (!launchd.supported) {
    throw new Error(
      `Background install needs macOS (launchd).\n  Run it in the foreground instead: ${INVOKE} run`,
    );
  }

  const port = resolvePort();
  const token = ensureToken(flagValue(argv, '--token'));
  writeConfig({ ...readConfig(), token, port });
  ensureStateDir();

  const { node } = launchd.install({ port });

  console.log('');
  console.log(`  ${bold('Gather bridge')} — installed and running`);
  console.log(`  ${'─'.repeat(56)}`);
  if (launchd.isVolatileNodePath(node)) {
    console.log(
      yellow(
        `  note     using ${node}\n` +
          '           that path is version-managed and will break on the next\n' +
          '           Node upgrade — `brew install node` gives a stable one,\n' +
          '           then re-run install.',
      ),
    );
    console.log('');
  }

  const up = await waitForBridge(port);
  printPairing({ port, token, up });
  console.log('  It starts at login and restarts if it dies.');
  console.log(dim(`  ${CLI} status | logs | doctor | restart | uninstall`));
  console.log('');
  if (!up) {
    console.log(red('  The daemon did not answer. Recent log:'));
    console.log(dim(tailLog(12)));
    console.log('');
    process.exitCode = 1;
  }
}

async function cmdRun() {
  const port = resolvePort();
  const token = ensureToken(flagValue(argv, '--token'));
  const spaceId = flagValue(argv, '--space') ?? null;
  const logSource = flagValue(argv, '--log-file') ?? gatherLogFile;
  ensureStateDir();
  rotateLogIfLarge();

  const log = (msg) => console.log(`${new Date().toISOString()} ${msg}`);

  // Everything the bridge can see now needs a Gather session. Fail loudly here
  // rather than starting a daemon that answers on its port and knows nothing.
  if (!hasGatherSession()) {
    throw new Error(
      `No Gather session.\n  Run ${INVOKE} adopt once — it reuses the session the\n` +
        '  GatherV2 desktop app is already signed in with.',
    );
  }

  const server = new BridgeServer({ token, port, spaceId, logSource, log });

  try {
    await server.start();
  } catch (e) {
    if (e.code === 'EADDRINUSE') {
      // Another bridge already serves this port — a success condition, not a
      // crash. Exiting 0 stops launchd from respawning us in a loop.
      if (await pingBridge(port)) {
        log(`another bridge is already listening on ${port}; exiting`);
        return;
      }
      throw new Error(`Port ${port} is taken by something else.\n  Try: ${INVOKE} install --port 7800`);
    }
    throw e;
  }

  log(`listening on 0.0.0.0:${port}`);

  const shutdown = async () => {
    log('shutting down');
    await server.stop();
    process.exit(0);
  };
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);

  // launchd keeps us alive; nothing else to do on the main path.
  await new Promise(() => {});
}

function cmdSimple(fn, past) {
  if (!launchd.supported) throw new Error('launchd is macOS-only');
  const ok = fn();
  console.log(ok ? green(`  bridge ${past}`) : red(`  could not ${past.replace(/ed$/, '')} bridge`));
  if (!ok) process.exitCode = 1;
}

async function cmdStatus() {
  const config = readConfig();
  // Honour --port: `status` is the first thing reached for when a bridge is
  // running on a non-default port, and silently probing the configured one
  // reports a healthy daemon as dead.
  const port = resolvePort();
  const state = launchd.supported ? launchd.status() : { installed: false, running: false, pid: null };
  const up = await pingBridge(port);

  console.log('');
  console.log(`  ${bold('Gather bridge')}`);
  console.log(`  ${'─'.repeat(56)}`);
  line('installed', state.installed ? green('yes') : red('no'));
  line('running', state.running ? green(`yes (pid ${state.pid})`) : red('no'));
  line('answering', up ? green(`yes on :${port}`) : red(`no on :${port}`));
  line(
    'gather session',
    hasGatherSession() ? green(`adopted (${String(gatherUid()).slice(0, 8)}…)`) : red('not adopted'),
  );

  if (up) {
    const collectors = await getJson(port, '/collectors', config.token);
    if (collectors) {
      line(
        'gather socket',
        collectors.health?.gather ? green('live') : dim(collectors.detail ?? 'not connected'),
      );
      // Only carries Gather's own notifications now, so its being down costs
      // waves and meeting invites and nothing else.
      line(
        'notifications',
        collectors.health?.logTail ? green('live') : yellow('desktop app not running'),
      );
    }
    const snapshot = await getJson(port, '/state', config.token);
    if (snapshot) {
      const followers = (snapshot.players ?? []).filter((p) => p.isFollowingMe);
      line('space', snapshot.self?.spaceName ?? snapshot.self?.spaceId ?? dim('unknown'));
      line('following you', followers.length ? followers.map(labelOf).join(', ') : dim('nobody'));
    }
  }
  console.log('');
}

function cmdLogs() {
  if (argv.includes('-f') || argv.includes('--follow')) {
    execFileSync('tail', ['-n', '40', '-f', logFile], { stdio: 'inherit' });
    return;
  }
  console.log(tailLog(60));
}

function cmdUninstall() {
  const wasInstalled = launchd.uninstall();
  console.log(wasInstalled ? green('  bridge uninstalled') : dim('  bridge was not installed'));
  console.log(dim('  pairing token kept in ~/.gather-app-bridge.json'));
}

function cmdToken() {
  const token = ensureToken(flagValue(argv, '--token'));
  const port = readConfig().port ?? DEFAULT_PORT;
  printPairing({ port, token, up: null });
}

/**
 * Copies the desktop client's Gather session into the bridge's own config.
 *
 * One read, then independence: refresh tokens are long-lived, so from here on the
 * bridge mints its own and needs neither the desktop client nor a debug port.
 * This is the one setup step there is — nothing else works without it.
 */
async function cmdAdopt() {
  console.log('');
  try {
    const { uid, file } = await adoptDesktopSession({ log: () => {} });
    console.log(`  ${green('Adopted your Gather session.')}`);
    console.log(`  ${dim(`account ${String(uid).slice(0, 8)}… · read from ${file}`)}`);
    console.log('');
    console.log('  The bridge connects to Gather directly, as an observer: it reads');
    console.log('  the whole space — names, positions, who is following you — without');
    console.log('  joining it, so nobody sees an extra avatar.');
    console.log('');
    console.log(`  Restart to pick it up:  ${bold(`${INVOKE} restart`)}`);
    console.log('');
  } catch (error) {
    console.log(`  ${red('Could not adopt a Gather session.')}`);
    console.log(`  ${error.message}`);
    console.log('');
    console.log('  Sign in to the GatherV2 desktop app, then run this again.');
    console.log('');
    process.exit(1);
  }
}

async function cmdDoctor() {
  const space = readGatherSpace();
  const adopted = hasGatherSession();

  console.log('');
  console.log(`  ${bold('Gather bridge — doctor')}`);
  console.log(`  ${'─'.repeat(56)}`);
  const running = isGatherRunning();
  line('GatherV2 app', existsSync(GATHER_BINARY) ? green('installed') : yellow('not found'));
  line('GatherV2 running', running ? green('yes') : yellow('no'));
  line('log file', existsSync(gatherLogFile) ? green('present') : yellow('not created yet'));
  line('last space', space.spaceId ?? dim('unknown'));
  line(
    'gather session',
    adopted ? green(`adopted (${String(gatherUid()).slice(0, 8)}…)`) : red('not adopted'),
  );
  console.log('');

  if (!adopted) {
    console.log(red('  The bridge cannot see anything yet.'));
    console.log('  It talks to Gather as you, so it needs your session.');
    console.log('');
    console.log(`    1. Sign in to the GatherV2 desktop app.`);
    console.log(`    2. Run ${bold(`${INVOKE} adopt`)}.`);
    console.log('');
    console.log(dim('  That reads the refresh token the desktop client already stored and'));
    console.log(dim('  keeps a copy in ~/.gather-app-bridge.json (mode 0600). After that'));
    console.log(dim('  the desktop app can be closed; the bridge mints its own tokens.'));
    console.log('');
    return;
  }

  console.log(green('  Connected to Gather directly.'));
  console.log('  Names, positions, cluster adjacency, real follow detection and live');
  console.log('  voice activity, with no devtools port and no need for the desktop');
  console.log('  app to be running.');
  console.log('');

  if (running) {
    console.log(green('  Gather\'s own notifications are being picked up too.'));
    console.log('  Waves, meeting invites and event reminders reach the phone even');
    console.log('  when your Mac suppressed them because the window had focus.');
  } else {
    console.log(yellow('  No waves or meeting invites while GatherV2 is closed.'));
    console.log('  Those three — wave, meeting invite, event reminder — are raised by');
    console.log('  the desktop client itself and appear in no part of Gather\'s game');
    console.log('  state, so they are the one thing that still needs it running.');
    console.log('');
    console.log(dim('  Everything else — who is following you — keeps working with the'));
    console.log(dim('  app closed.'));
  }
  console.log('');
  console.log(dim('  Not available at all: mic, camera and screenshare state. They were'));
  console.log(dim('  IPC state in the desktop client and are in no Gather model.'));
  console.log('');
}

/**
 * Forces a full state resync.
 *
 * Cheap now: the game server replays its whole state dump on every connection, so
 * this is a reconnect. It used to mean reloading the Gather renderer and waiting.
 */
async function cmdResync() {
  const port = resolvePort();
  const token = readConfig().token ?? flagValue(argv, '--token');
  const res = await getJson(port, '/resync', token);
  if (!res) {
    throw new Error(`No answer from the bridge on :${port}.\n  Is it running? ${INVOKE} status`);
  }
  console.log('');
  console.log(res.ok ? green(`  ${res.detail}`) : red(`  ${res.detail}`));
  console.log(dim('  then: ' + CLI + ' status'));
  console.log('');
  if (!res.ok) process.exitCode = 1;
}

/**
 * Shows a square for the phone to scan.
 *
 * The code, not the token, is what goes on screen: a 48-character token is
 * unreadable and untypable, so the phone trades a short code for it once. Both
 * ways in are offered — the QR for the camera, the code and address underneath
 * for a phone whose camera was refused, a terminal too small to draw the symbol,
 * or an ssh session that mangles half-block characters.
 */
async function cmdPair() {
  const port = resolvePort();
  const token = readConfig().token;
  if (!token || !(await pingBridge(port))) {
    throw new Error(`The bridge is not running on :${port}.\n  Start it first: ${INVOKE}`);
  }

  const offer = await getJson(port, '/pair/offer', token);
  if (!offer?.code) throw new Error('The bridge would not issue a pairing code.');

  const host = offer.addresses?.[0] ?? '127.0.0.1';
  const payload = pairPayload({ host, port: offer.port ?? port, code: offer.code });

  console.log('');
  console.log(`  ${bold('Pair your phone')}`);
  console.log(`  ${'─'.repeat(56)}`);
  console.log('');
  for (const row of renderQr(payload, { indent: '      ' })) console.log(row);
  console.log('');
  console.log(`      ${bold(offer.code)}`);
  console.log(dim(`      ${host}:${offer.port ?? port}`));
  console.log('');
  console.log(dim('  Scan it in the Gather app, or type the code and address in.'));
  console.log(dim('  Valid for 15 minutes, once.'));
  console.log('');

  // Wait for it, so the terminal confirms rather than leaving someone guessing
  // whether the scan landed.
  const before = offer.claims ?? 0;
  const deadline = Date.now() + 15 * 60_000;
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 1000));
    const status = await getJson(port, '/pair/status', token);
    if (status && (status.claims ?? 0) > before) {
      console.log(green('  Paired. The phone is connected.'));
      console.log('');
      return;
    }
    if (status && !status.pending) {
      console.log(yellow('  That code is no longer valid. Run pair again.'));
      console.log('');
      process.exitCode = 1;
      return;
    }
  }
  console.log(dim('  The code expired.'));
  console.log('');
}

/**
 * Attaches to the live event stream and prints it, the same feed the phone gets.
 *
 * Uses the same catch-up-by-sequence contract as the app: the first frame is a
 * snapshot (which also gives us the names to resolve ids against), and a
 * reconnect resumes from the last sequence number rather than losing whatever
 * happened while the socket was down.
 */
async function cmdWatch() {
  const port = resolvePort();
  const host = flagValue(argv, '--host') ?? '127.0.0.1';
  const token = flagValue(argv, '--token') ?? readConfig().token;
  if (!token) {
    throw new Error(`No pairing token found.\n  Show it with: ${INVOKE} token`);
  }

  const asJson = argv.includes('--json');
  // The firehose: every event the collectors produced, before the tracker decides
  // what a human needs to see. It is a superset of the normal stream, so it
  // replaces it rather than being printed alongside.
  const raw = argv.includes('--raw');
  const filters = (flagValue(argv, '--filter') ?? '')
    .split(',')
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
  const historyCount = Number(flagValue(argv, '--history') ?? 0);

  /** id -> display name, kept fresh from every snapshot. */
  const names = new Map();
  const nameFor = (id) => names.get(id) ?? (id ? id.slice(0, 8) : 'someone');
  const wanted = (event) =>
    filters.length === 0 || filters.some((f) => event.type.toLowerCase().includes(f));

  let lastSeq = Number(flagValue(argv, '--since') ?? 0);

  // Prime from history so `watch` is useful immediately rather than only showing
  // whatever happens next.
  if (historyCount > 0) {
    const past = await getJson(port, '/events', token, host);
    const events = (past?.events ?? []).slice(-historyCount);
    if (events.length === 0) console.log(dim('  (no history yet)'));
    for (const { seq, event } of events) {
      if (wanted(event)) emit(event, seq);
      if (seq > lastSeq) lastSeq = seq;
    }
  }

  if (!asJson) {
    console.log('');
    console.log(`  ${bold('watching')} ${host}:${port}${dim('  — Ctrl-C to stop')}`);
    if (raw) {
      console.log(dim('  raw: unfiltered collector output, including what the'));
      console.log(dim('       tracker would normally suppress as noise'));
    }
    if (filters.length) console.log(dim(`  filter: ${filters.join(', ')}`));
    console.log(`  ${'─'.repeat(56)}`);
  }

  function emit(event, seq) {
    if (asJson) {
      console.log(JSON.stringify({ seq, ...event }));
      return;
    }
    const { mark, text, meta } = describe(event, nameFor);
    const clock = new Date(event.at).toLocaleTimeString('en-GB', { hour12: false });
    console.log(`  ${dim(clock)} ${mark} ${text}${meta ? dim(`  ${meta}`) : ''}`);
  }

  let backoff = 1000;
  let stopping = false;
  process.on('SIGINT', () => {
    stopping = true;
    if (!asJson) console.log(dim('\n  stopped\n'));
    process.exit(0);
  });

  // eslint-disable-next-line no-constant-condition
  while (!stopping) {
    const url =
      `ws://${host}:${port}/ws?token=${encodeURIComponent(token)}` +
      (lastSeq > 0 ? `&since=${lastSeq}` : '') +
      (raw ? '&raw=1' : '');
    const closed = await new Promise((resolve) => {
      let ws;
      try {
        ws = new WebSocket(url);
      } catch (err) {
        resolve(err.message);
        return;
      }
      ws.addEventListener('open', () => {
        backoff = 1000;
      });
      // Not named `raw`: that would shadow the --raw flag from the enclosing
      // scope, making `kind` below always 'raw' and silently printing nothing.
      ws.addEventListener('message', (message) => {
        let frame;
        try {
          frame = JSON.parse(String(message.data));
        } catch {
          return;
        }
        if (typeof frame.seq === 'number' && frame.seq > lastSeq) lastSeq = frame.seq;

        if (frame.kind === 'snapshot') {
          for (const player of frame.snapshot?.players ?? []) {
            if (player.name) names.set(player.id, player.name);
          }
          return;
        }
        // In raw mode the firehose is the superset, so the filtered stream is
        // ignored to avoid printing everything twice.
        const kind = raw ? 'raw' : 'event';
        if (frame.kind === kind && frame.event && wanted(frame.event)) {
          emit(frame.event, frame.seq);
        }
      });
      ws.addEventListener('close', () => resolve('connection closed'));
      ws.addEventListener('error', () => resolve('connection failed'));
    });

    if (stopping) break;
    if (!asJson) {
      console.log(dim(`  ${closed} — retrying in ${Math.round(backoff / 1000)}s`));
    }
    await new Promise((r) => setTimeout(r, backoff));
    backoff = Math.min(backoff * 2, 15000);
  }
}

/** One event as a symbol, a sentence and some dim metadata. */
function describe(event, nameFor) {
  const who = nameFor(
    event.type.startsWith('follow') && event.targetIsSelf ? event.followerId : event.playerId,
  );
  const conf = event.confidence === 'inferred' ? 'inferred' : '';
  const meta = [conf, event.source === 'log' ? 'desktop log' : ''].filter(Boolean).join(' · ');

  switch (event.type) {
    case 'follow.started':
      return event.targetIsSelf
        ? { mark: red('▲'), text: bold(`${who} started following you`), meta }
        : { mark: dim('▲'), text: `you started following ${nameFor(event.targetId)}`, meta };
    case 'follow.stopped':
      return event.targetIsSelf
        ? { mark: dim('▽'), text: `${who} stopped following you`, meta }
        : { mark: dim('▽'), text: 'you stopped following', meta };
    case 'notification.shown':
      // A wave is the loudest thing Gather itself will tell you about, and the
      // one most worth seeing here.
      return {
        mark: event.notificationType === 'wave' ? yellow('✋') : dim('!'),
        text: event.title ?? `notification: ${event.notificationType}`,
        meta: [event.body, meta].filter(Boolean).join(' · '),
      };
    case 'self.changed':
      return {
        mark: dim('you'),
        text: event.inOffice != null ? (event.inOffice ? 'in office' : 'left office') : 'state changed',
        meta: '',
      };
    case 'space.changed':
      return { mark: dim('#'), text: `space ${event.spaceName ?? event.spaceId ?? 'unknown'}`, meta };
    case 'bridge.status':
      return {
        mark: event.healthy ? green('✓') : yellow('✗'),
        text: `${event.collector} ${event.healthy ? 'connected' : 'disconnected'}`,
        meta: event.detail ?? '',
      };
    default:
      return { mark: dim('·'), text: `${event.type}${event.text ? ` ${event.text}` : ''}`, meta };
  }
}

/**
 * Replay a log file through the notification reader.
 *
 * The fastest way to check the regex still matches after a Gather update: point
 * it at a log you know contained a wave and see whether one comes out. Zero
 * notifications over a long log is the failure signature.
 */
async function cmdReplay() {
  const file = argv.find((a) => !a.startsWith('-') && a !== 'replay') ?? gatherLogFile;
  const asJson = argv.includes('--json');
  const reader = new DesktopNotificationReader();
  const counts = new Map();
  let lines = 0;

  const rl = createInterface({ input: createReadStream(file), crlfDelay: Infinity });
  for await (const line of rl) {
    lines++;
    for (const event of reader.feed(line)) {
      counts.set(event.notificationType, (counts.get(event.notificationType) ?? 0) + 1);
      if (asJson) console.log(JSON.stringify(event));
    }
  }

  if (asJson) return;
  const total = [...counts.values()].reduce((a, b) => a + b, 0);
  console.log('');
  console.log(`  ${bold(file)}`);
  console.log(`  ${'─'.repeat(56)}`);
  line('lines read', String(lines));
  line('notifications', String(total));
  for (const [type, n] of [...counts].sort((a, b) => b[1] - a[1])) line(type, String(n));
  if (total === 0) {
    console.log('');
    console.log(yellow('  Nothing matched. If this log should contain a wave or a meeting'));
    console.log(yellow('  invite, the IPC line has changed shape — see'));
    console.log(yellow('  bridge/lib/desktop-notifications.js.'));
  }
  console.log('');
}

/**
 * Push: install the Firebase service account, inspect it, or send a test.
 *
 * `setup` exists because the alternative is telling somebody to `cp` a file to a
 * dotfile path and `chmod 600` it, and the whole point of the credential is that
 * it is not left world-readable in ~/Downloads.
 */
async function cmdPush() {
  const sub = argv[argv.indexOf('push') + 1];

  if (sub === 'setup') {
    const source = argv[argv.indexOf('setup') + 1];
    if (!source) {
      throw new Error(
        `Which file?\n  ${INVOKE} push setup ~/Downloads/gather-companion-firebase-adminsdk-....json`,
      );
    }
    // Validated before it is copied: a wrong file put in place and only rejected
    // at the next daemon start is a much worse error to debug.
    const account = readServiceAccount(source);
    copyFileSync(source, fcmKeyFile);
    chmodSync(fcmKeyFile, 0o600);
    console.log('');
    console.log(`  ${green('Push credentials installed.')}`);
    line('project', account.projectId);
    line('account', account.clientEmail);
    line('stored at', `${fcmKeyFile} (0600)`);
    console.log('');
    console.log(`  Restart to pick it up:  ${bold(`${INVOKE} restart`)}`);
    console.log(dim('  Then open the app once so the phone can register for pushes.'));
    console.log('');
    return;
  }

  if (sub === 'test') {
    const registry = new PushRegistry();
    const devices = registry.list();
    if (devices.length === 0) {
      throw new Error(
        'No phone has registered for pushes yet.\n' +
          '  Open the app while it is paired — it registers on connect.',
      );
    }
    const sender = new FcmSender({ keyFile: fcmKeyFile, log: () => {} });
    sender.account(); // throws with a fixable message if it is not set up
    console.log('');
    for (const device of devices) {
      const result = await sender.send({
        token: device.token,
        title: 'Gather Companion',
        body: 'Push is working. This is a test from your Mac.',
        data: { type: 'test' },
        collapseId: 'test',
      });
      const id = `${device.platform} ${device.token.slice(0, 12)}…`;
      if (result.ok) console.log(`  ${green('sent')}     ${id}`);
      else if (result.drop) {
        registry.forget(device.token);
        console.log(`  ${yellow('dropped')}  ${id} — ${result.detail}`);
      } else console.log(`  ${red('failed')}   ${id} — ${result.detail}`);
    }
    console.log('');
    return;
  }

  // Default: status.
  const registry = new PushRegistry();
  let account = null;
  let problem = null;
  try {
    account = readServiceAccount(fcmKeyFile);
  } catch (error) {
    problem = error.message;
  }

  console.log('');
  console.log(`  ${bold('Push notifications')}`);
  console.log(`  ${'─'.repeat(56)}`);
  line('credentials', account ? green(account.projectId) : red('not installed'));
  const devices = registry.list();
  line('devices', devices.length ? green(`${devices.length} registered`) : yellow('none yet'));
  const kinds = registry.kinds();
  line('wakes on', Object.keys(kinds).filter((k) => kinds[k]).join(', ') || dim('nothing'));
  console.log('');

  if (problem) {
    console.log(`  ${problem}`);
    console.log('');
    console.log(`  Install it with:  ${bold(`${INVOKE} push setup <file.json>`)}`);
    console.log('');
    console.log(dim('  The file comes from the Firebase console:'));
    console.log(dim('  Project settings → Service accounts → Generate new private key.'));
    console.log('');
    process.exitCode = 1;
    return;
  }

  if (devices.length === 0) {
    console.log(dim('  Nothing to send to yet. Open the app while it is paired — it'));
    console.log(dim('  registers its push token as soon as it connects.'));
    console.log('');
    return;
  }
  console.log(`  Send a test:  ${bold(`${INVOKE} push test`)}`);
  console.log('');
}

// ---- helpers ----------------------------------------------------------------

function line(label, value) {
  console.log(`  ${label.padEnd(16)} ${value}`);
}

function labelOf(player) {
  return player.name ?? player.id.slice(0, 8);
}

function resolvePort() {
  return parsePort(argv, readConfig().port ?? DEFAULT_PORT);
}

function isGatherRunning() {
  try {
    execFileSync('pgrep', ['-f', 'GatherV2.app/Contents/MacOS/GatherV2'], { stdio: 'pipe' });
    return true;
  } catch {
    return false;
  }
}

async function pingBridge(port) {
  try {
    const res = await fetch(`http://127.0.0.1:${port}/health`, {
      signal: AbortSignal.timeout(1500),
    });
    if (!res.ok) return false;
    const body = await res.json();
    return body?.name === 'gather-app-bridge';
  } catch {
    return false;
  }
}

async function getJson(port, path, token, host = '127.0.0.1') {
  try {
    const res = await fetch(
      `http://${host}:${port}${path}?token=${encodeURIComponent(token ?? '')}`,
      { signal: AbortSignal.timeout(2000) },
    );
    if (!res.ok) return null;
    return await res.json();
  } catch {
    return null;
  }
}

async function waitForBridge(port, attempts = 20) {
  for (let i = 0; i < attempts; i++) {
    if (await pingBridge(port)) return true;
    await new Promise((r) => setTimeout(r, 250));
  }
  return false;
}

function printPairing({ port, token, up }) {
  const hosts = lanAddresses();
  const host = hosts[0] ?? '127.0.0.1';
  console.log('');
  line('status', up === null ? dim('—') : up ? green('answering') : red('not answering'));
  line('port', String(port));
  line('token', token);
  console.log('');
  console.log('  In the phone app, enter:');
  console.log(`    ${bold(`${host}:${port}`)}`);
  console.log(`    ${bold(token)}`);
  if (hosts.length > 1) {
    console.log(dim(`  other addresses: ${hosts.slice(1).join(', ')}`));
  }
  console.log('');
}

function tailLog(n) {
  try {
    const lines = readFileSync(logFile, 'utf8').trimEnd().split('\n');
    return lines
      .slice(-n)
      .map((l) => `    ${l}`)
      .join('\n');
  } catch {
    return '    (no log yet)';
  }
}

function version() {
  try {
    const pkg = JSON.parse(readFileSync(join(launchd.packageRoot, 'package.json'), 'utf8'));
    return pkg.version ?? '0.0.0';
  } catch {
    return '0.0.0';
  }
}

function usage() {
  console.log(`
  ${bold('gather-app-bridge')} — stream Gather V2 presence to your phone

  ${bold('Usage')}
    ${INVOKE}                    install as a background service and pair
    ${INVOKE} run                run in the foreground (no launchd)
    ${INVOKE} status             is it alive, and who is around
    ${INVOKE} pair               show a QR square for the phone to scan
    ${INVOKE} adopt              reuse your signed-in Gather session (best fidelity)
    ${INVOKE} doctor             what can it see, and how to see more
    ${INVOKE} resync             force a full state resync
    ${INVOKE} logs [-f]          daemon log
    ${INVOKE} token              show pairing details again
    ${INVOKE} start|stop|restart
    ${INVOKE} uninstall
    ${INVOKE} replay [file]      re-check the notification regex on a log

  ${bold('Push notifications')}
    ${INVOKE} push                 is push set up, and who is registered
    ${INVOKE} push setup <file>    install the Firebase service account JSON
    ${INVOKE} push test            send a test notification to every phone

  ${bold('Watching the event feed')}
    ${INVOKE} watch                       attach to the live stream
    ${INVOKE} watch --history 20          show the last 20 events first
    ${INVOKE} watch --filter follow,notification
    ${INVOKE} watch --json | jq .         machine-readable, one event per line
    ${INVOKE} watch --raw                 everything intercepted, unfiltered

  ${bold('Options')}
    --port <n>        LAN port to serve on (default ${DEFAULT_PORT})
    --space <uuid>    watch a specific space (run; default: last one you opened)
    --token <s>       use a specific pairing token
    --log-file <p>    tail a different Gather log (run)
    --host <h>        bridge to attach to (watch, default 127.0.0.1)
    --history <n>     replay the last n events before following (watch)
    --since <seq>     resume from a sequence number (watch)
    --filter <a,b>    only event types containing these words (watch)
    --raw             unfiltered firehose: everything intercepted (watch)
    --json            raw JSON, one event per line (watch, replay)

  Runs as a LaunchAgent: starts at login, restarts if it dies, survives sleep.
`);
}
