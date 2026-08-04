/** Flags that consume the next argument, which is therefore not the command. */
export const VALUE_FLAGS = new Set([
  '--port',
  '--token',
  '--cdp-port',
  '--log-file',
  '--host',
  '--since',
  '--history',
  '--filter',
]);

/**
 * The first bare word in `argv`, skipping the values of value-taking flags.
 *
 * Naively taking the first non-`-` token reads `--port 7789` as the command
 * `7789`; and with no bare word at all the default is `install`, so `--version`
 * would silently reinstall the daemon. Both were real.
 */
export function parseCommand(argv, fallback) {
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('-')) {
      if (VALUE_FLAGS.has(a)) i++;
      continue;
    }
    return a;
  }
  return fallback;
}

/** Value of `--name x` or `--name=x`. */
export function flagValue(argv, name) {
  const i = argv.indexOf(name);
  if (i >= 0 && i + 1 < argv.length) return argv[i + 1];
  const inline = argv.find((a) => a.startsWith(`${name}=`));
  return inline ? inline.slice(name.length + 1) : undefined;
}

export function parsePort(argv, fallback) {
  const raw = flagValue(argv, '--port');
  if (raw == null) return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 1 || n > 65535) throw new Error(`Invalid port: ${raw}`);
  return n;
}
