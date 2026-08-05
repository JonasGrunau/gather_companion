import { execFileSync, spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { LABEL, installDir, logFile, plistFile, stateDir } from './paths.js';

/**
 * Root of the package as shipped (the directory containing `bridge/`).
 *
 * Found by walking up rather than hard-coding `../..`, because the installed
 * copy in ~/.gather-app-bridge/bridge is one level shallower than the repo layout.
 */
export const packageRoot = findPackageRoot(dirname(fileURLToPath(import.meta.url)));

function findPackageRoot(from) {
  let dir = from;
  for (let i = 0; i < 5; i++) {
    if (existsSync(join(dir, 'package.json'))) return dir;
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return join(from, '..', '..');
}

const domain = () => `gui/${process.getuid()}`;
const target = () => `${domain()}/${LABEL}`;

export const supported = process.platform === 'darwin';

/**
 * Installs the bridge as a login-time LaunchAgent.
 *
 * The package is copied into ~/.gather-app-bridge/bridge first. `npx` runs out of a
 * cache npm is free to prune, and a global install disappears on the next
 * `npm uninstall` — either would leave launchd pointing at nothing. A private
 * copy is the only version of this that still works in six months.
 */
export function install({ port }) {
  const node = resolveStableNode();

  mkdirSync(stateDir, { recursive: true });
  rmSync(installDir, { recursive: true, force: true });
  mkdirSync(installDir, { recursive: true });

  // The repo layout has bridge/{bin,lib}; the published tarball keeps that, so
  // both resolve the same way.
  const from = existsSync(join(packageRoot, 'bridge', 'lib'))
    ? join(packageRoot, 'bridge')
    : packageRoot;
  cpSync(join(from, 'lib'), join(installDir, 'lib'), { recursive: true });
  cpSync(join(from, 'bin'), join(installDir, 'bin'), { recursive: true });

  // The copy is outside any package; ESM needs this to load .js as modules.
  writeFileSync(
    join(installDir, 'package.json'),
    `${JSON.stringify({ name: 'gather-app-bridge-installed', private: true, type: 'module' }, null, 2)}\n`,
  );

  const entry = join(installDir, 'bin', 'gather-bridge.js');
  const args = [node, entry, 'run', '--port', String(port)];

  mkdirSync(dirname(plistFile), { recursive: true });
  writeFileSync(plistFile, plist(args));

  // bootout first so a re-install replaces the definition rather than erroring
  // with "service already loaded".
  launchctl(['bootout', target()], { ignoreFailure: true });
  const boot = launchctl(['bootstrap', domain(), plistFile]);
  if (boot.status !== 0) {
    throw new Error(`launchctl bootstrap failed: ${boot.stderr.trim() || `exit ${boot.status}`}`);
  }
  launchctl(['kickstart', target()], { ignoreFailure: true });

  return { node, entry, plist: plistFile };
}

export function uninstall() {
  const wasInstalled = existsSync(plistFile);
  launchctl(['bootout', target()], { ignoreFailure: true });
  rmSync(plistFile, { force: true });
  rmSync(installDir, { recursive: true, force: true });
  return wasInstalled;
}

export function start() {
  return launchctl(['kickstart', target()]).status === 0;
}

export function stop() {
  return launchctl(['bootout', target()], { ignoreFailure: true }).status === 0;
}

export function restart() {
  return launchctl(['kickstart', '-k', target()]).status === 0;
}

/** `{ installed, running, pid }` from launchd's own view of the job. */
export function status() {
  if (!existsSync(plistFile)) return { installed: false, running: false, pid: null };
  const out = launchctl(['print', target()]);
  if (out.status !== 0) return { installed: true, running: false, pid: null };
  const pid = /^\s*pid = (\d+)/m.exec(out.stdout);
  return {
    installed: true,
    running: pid != null,
    pid: pid ? Number(pid[1]) : null,
  };
}

function launchctl(args, { ignoreFailure = false } = {}) {
  const r = spawnSync('launchctl', args, { encoding: 'utf8' });
  if (r.error && !ignoreFailure) throw r.error;
  return { status: r.status ?? 1, stdout: r.stdout ?? '', stderr: r.stderr ?? '' };
}

/**
 * Picks a `node` that will still exist at the next login.
 *
 * `process.execPath` is the obvious choice and the wrong one: under nvm or asdf
 * it points at a version-pinned path that vanishes the first time Node is
 * upgraded — and a LaunchAgent that can't exec just crash-loops silently. A
 * version-independent path is worth preferring even when it's an older runtime.
 */
export function resolveStableNode() {
  const candidates = ['/opt/homebrew/bin/node', '/usr/local/bin/node', '/usr/bin/node'];
  for (const candidate of candidates) {
    if (!existsSync(candidate)) continue;
    if (majorVersion(candidate) >= 22) return candidate;
  }
  return process.execPath;
}

export function isVolatileNodePath(path) {
  return /\/\.nvm\/|\/\.fnm\/|\/\.volta\/|\/\.asdf\/|\/\.nodenv\//.test(path);
}

function majorVersion(nodePath) {
  try {
    const v = execFileSync(nodePath, ['--version'], { encoding: 'utf8', timeout: 5000 });
    return Number(/^v(\d+)/.exec(v.trim())?.[1] ?? 0);
  } catch {
    return 0;
  }
}

function plist(programArguments) {
  const args = programArguments.map((a) => `      <string>${escapeXml(a)}</string>`).join('\n');
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
${args}
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>ProcessType</key>
  <string>Background</string>
  <key>LowPriorityIO</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${escapeXml(logFile)}</string>
  <key>StandardErrorPath</key>
  <string>${escapeXml(logFile)}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
</dict>
</plist>
`;
}

function escapeXml(s) {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}
