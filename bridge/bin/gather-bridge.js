#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { createReadStream, existsSync, readFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { join } from 'node:path';

import { flagValue, parseCommand, parsePort } from '../lib/cli-args.js';
import { DEFAULT_CDP_PORT, probeCdp } from '../lib/cdp.js';
import { playerIdOf } from '../lib/events.js';
import * as launchd from '../lib/launchd.js';
import { GatherLogParser } from '../lib/log-parser.js';
import { pairPayload } from '../lib/pairing.js';
import { render as renderQr } from '../lib/qr.js';
import {
  ensureStateDir,
  ensureToken,
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
  const cdpPort = Number(flagValue(argv, '--cdp-port') ?? DEFAULT_CDP_PORT);
  const logSource = flagValue(argv, '--log-file') ?? gatherLogFile;
  ensureStateDir();
  rotateLogIfLarge();

  const log = (msg) => console.log(`${new Date().toISOString()} ${msg}`);
  const server = new BridgeServer({ token, port, cdpPort, logSource, log });

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
  log(`tailing ${logSource}`);

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
  const cdp = await probeCdp(Number(flagValue(argv, '--cdp-port') ?? DEFAULT_CDP_PORT));

  console.log('');
  console.log(`  ${bold('Gather bridge')}`);
  console.log(`  ${'─'.repeat(56)}`);
  line('installed', state.installed ? green('yes') : red('no'));
  line('running', state.running ? green(`yes (pid ${state.pid})`) : red('no'));
  line('answering', up ? green(`yes on :${port}`) : red(`no on :${port}`));
  line('gather log', existsSync(gatherLogFile) ? green('present') : yellow('not found'));
  line('devtools', cdp ? green(`yes — ${cdp.Browser ?? 'connected'}`) : dim('not enabled (optional)'));

  if (up) {
    const collectors = await getJson(port, '/collectors', config.token);
    if (collectors) {
      line('log collector', collectors.health?.logTail ? green('live') : red('down'));
      line(
        'cdp collector',
        collectors.health?.cdp ? green('live') : dim(collectors.cdpDetail ?? 'not attached'),
      );
    }
    const snapshot = await getJson(port, '/state', config.token);
    if (snapshot) {
      const near = (snapshot.players ?? []).filter((p) => p.isNear);
      const followers = (snapshot.players ?? []).filter((p) => p.isFollowingMe);
      line('space', snapshot.self?.spaceId ?? dim('unknown'));
      line('next to you', near.length ? near.map(labelOf).join(', ') : dim('nobody'));
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
  console.log(dim('  pairing token kept in ~/.gather-bridge.json'));
}

function cmdToken() {
  const token = ensureToken(flagValue(argv, '--token'));
  const port = readConfig().port ?? DEFAULT_PORT;
  printPairing({ port, token, up: null });
}

/**
 * Explains, concretely, what the bridge can and cannot see right now.
 *
 * The interesting case is the CDP collector: without it there are no names, no
 * coordinates and no `followTargetId`, so "someone is following you" cannot be
 * observed — only guessed from movement. This prints the exact command that
 * fixes that.
 */
async function cmdDoctor() {
  const cdpPort = Number(flagValue(argv, '--cdp-port') ?? DEFAULT_CDP_PORT);
  const running = isGatherRunning();
  const cdp = await probeCdp(cdpPort);
  const space = readGatherSpace();

  console.log('');
  console.log(`  ${bold('Gather bridge — doctor')}`);
  console.log(`  ${'─'.repeat(56)}`);
  line('GatherV2 app', existsSync(GATHER_BINARY) ? green('installed') : red('not found'));
  line('GatherV2 running', running ? green('yes') : yellow('no'));
  line('log file', existsSync(gatherLogFile) ? green(gatherLogFile) : yellow('not created yet'));
  line('last space', space.spaceId ?? dim('unknown'));
  line('devtools port', cdp ? green(`open on ${cdpPort}`) : yellow(`closed on ${cdpPort}`));
  console.log('');

  if (cdp) {
    console.log(green('  Full fidelity available.'));
    console.log('  Names, positions, cluster-based adjacency and real follow');
    console.log('  detection are all readable.');
    console.log('');
    return;
  }

  console.log(yellow('  Running in log-only mode.'));
  console.log('  You still get: who joined or left the space, who came near you');
  console.log('  (from Gather\'s own proximity-gated media connections), who muted,');
  console.log('  who shared a screen, and notification types.');
  console.log('');
  console.log('  Not available without devtools: display names, coordinates, and');
  console.log('  reliable "someone is following me" — that field lives in the web');
  console.log('  app\'s own state, not in the log.');
  console.log('');
  console.log(`  ${bold('To enable it:')}`);
  console.log('    1. Quit GatherV2 completely (Cmd+Q — it holds a single-instance lock,');
  console.log('       so launching a second copy just focuses the first one).');
  console.log('    2. Start it with the devtools port open:');
  console.log('');
  console.log(`       ${dim('"' + GATHER_BINARY + '" \\')}`);
  console.log(`       ${dim(`  --remote-debugging-port=${cdpPort} --remote-allow-origins='*' &`)}`);
  console.log('');
  console.log('    3. Sign in as usual. The bridge attaches on its own within a few');
  console.log('       seconds — no restart needed.');
  console.log('');
  console.log(dim('  --remote-debugging-port is a stock Chromium switch; Electron passes it'));
  console.log(dim('  through and Gather\'s own debug-flag gate does not apply to it.'));
  console.log('');
}

/**
 * Forces a full state resync.
 *
 * The game server sends its full state dump once per connection, so a bridge
 * that attached to an already-running client sees only heartbeats until somebody
 * moves. This reloads the Gather renderer (~2s) to make the dump happen again.
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
  const meta = [conf, event.source === 'log' ? 'log' : event.source === 'cdp' ? 'cdp' : '']
    .filter(Boolean)
    .join(' · ');

  switch (event.type) {
    case 'follow.started':
      return event.targetIsSelf
        ? { mark: red('▲'), text: bold(`${who} started following you`), meta }
        : { mark: dim('▲'), text: `you started following ${nameFor(event.targetId)}`, meta };
    case 'follow.stopped':
      return event.targetIsSelf
        ? { mark: dim('▽'), text: `${who} stopped following you`, meta }
        : { mark: dim('▽'), text: 'you stopped following', meta };
    case 'proximity.entered':
      return {
        mark: green('●'),
        text: bold(`${who} is next to you`),
        meta: [event.distance != null ? `${event.distance.toFixed(1)} tiles` : '', meta]
          .filter(Boolean)
          .join(' · '),
      };
    case 'proximity.left':
      return { mark: dim('○'), text: `${who} moved away`, meta };
    case 'audio.range':
      return {
        mark: dim(event.inRange ? '♪' : '·'),
        text: `${who} ${event.inRange ? 'came into' : 'left'} earshot`,
        meta,
      };
    case 'player.joinedSpace':
      return { mark: dim('+'), text: `${who} joined the space`, meta };
    case 'player.leftSpace':
      return { mark: dim('-'), text: `${who} left the space`, meta };
    case 'media.changed': {
      const what =
        event.track === 'screen'
          ? event.paused
            ? 'stopped sharing their screen'
            : 'started sharing their screen'
          : event.track === 'audio'
            ? event.paused
              ? 'muted'
              : 'unmuted'
            : event.paused
              ? 'turned their camera off'
              : 'turned their camera on';
      return { mark: dim('◐'), text: `${who} ${what}`, meta };
    }
    case 'chat.message':
      return { mark: '💬', text: `${who}: ${event.text}`, meta };
    case 'notification.shown':
      return {
        mark: dim('!'),
        text: event.title ?? `notification: ${event.notificationType}`,
        meta,
      };
    case 'self.changed': {
      const bits = [
        event.audioEnabled != null ? `mic ${event.audioEnabled ? 'on' : 'off'}` : '',
        event.videoEnabled != null ? `cam ${event.videoEnabled ? 'on' : 'off'}` : '',
        event.screensharing != null ? (event.screensharing ? 'screensharing' : 'stopped sharing') : '',
        event.inOffice != null ? (event.inOffice ? 'in office' : 'left office') : '',
      ].filter(Boolean);
      return { mark: dim('you'), text: bits.join(', ') || 'state changed', meta: '' };
    }
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

/** Replay a log file through the parser — the fastest way to check the regexes. */
async function cmdReplay() {
  const file = argv.find((a) => !a.startsWith('-') && a !== 'replay') ?? gatherLogFile;
  const asJson = argv.includes('--json');
  const parser = new GatherLogParser();
  const counts = new Map();
  const players = new Set();
  let lines = 0;

  const rl = createInterface({ input: createReadStream(file), crlfDelay: Infinity });
  for await (const line of rl) {
    lines++;
    for (const event of parser.feed(line)) {
      counts.set(event.type, (counts.get(event.type) ?? 0) + 1);
      const id = playerIdOf(event);
      if (id) players.add(id);
      if (asJson) console.log(JSON.stringify(event));
    }
  }

  if (asJson) return;
  console.log('');
  console.log(`  ${bold(file)}`);
  console.log(`  ${'─'.repeat(56)}`);
  line('lines read', String(lines));
  line('distinct players', String(players.size));
  for (const [type, n] of [...counts].sort((a, b) => b[1] - a[1])) {
    line(type, String(n));
  }
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
  console.log('  In the iPhone app, enter:');
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
    ${INVOKE} doctor             what can it see, and how to see more
    ${INVOKE} resync             force a full state resync (reloads the renderer)
    ${INVOKE} logs [-f]          daemon log
    ${INVOKE} token              show pairing details again
    ${INVOKE} start|stop|restart
    ${INVOKE} uninstall
    ${INVOKE} replay [file]      parse a log file and summarise it

  ${bold('Watching the event feed')}
    ${INVOKE} watch                       attach to the live stream
    ${INVOKE} watch --history 20          show the last 20 events first
    ${INVOKE} watch --filter follow,proximity
    ${INVOKE} watch --json | jq .         machine-readable, one event per line
    ${INVOKE} watch --raw                 everything intercepted, unfiltered

  ${bold('Options')}
    --port <n>        LAN port to serve on (default ${DEFAULT_PORT})
    --cdp-port <n>    Gather's devtools port (default ${DEFAULT_CDP_PORT})
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
