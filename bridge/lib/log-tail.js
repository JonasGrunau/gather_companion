import { EventEmitter } from 'node:events';
import { createReadStream, statSync } from 'node:fs';

/**
 * Follows a growing log file, line by line, for months at a time.
 *
 * Everything here exists because of one of three failure modes:
 *
 *  1. **Rotation.** electron-log caps `main.log` at 2 MB and renames it to
 *     `main.old.log`, then creates a fresh `main.log`. A tailer holding the old
 *     fd keeps reading a file nobody writes to any more, silently. So we watch
 *     the *inode*, not the handle, and reopen when it changes.
 *  2. **Truncation.** `main.log` can also be truncated in place, after which the
 *     file is shorter than our read offset. Detected as `size < offset`.
 *  3. **Sleep.** `fs.watch` on macOS does not reliably survive the machine
 *     suspending — it stops delivering events without erroring. A plain stat
 *     poll is therefore the primary trigger and `fs.watch` only an accelerator,
 *     never the other way round.
 *
 * Emits `line` (string) and `error`.
 */
export class LogTail extends EventEmitter {
  /**
   * @param {string} file
   * @param {{ pollMs?: number, fromStart?: boolean }} [options]
   */
  constructor(file, { pollMs = 400, fromStart = false } = {}) {
    super();
    this.file = file;
    this.pollMs = pollMs;
    this.fromStart = fromStart;

    this._offset = 0;
    this._inode = null;
    this._partial = '';
    this._reading = false;
    this._timer = null;
    this._watcher = null;
    this._stopped = false;
    /** Whether the file existed last time we looked, so we can log transitions. */
    this._present = null;
  }

  start() {
    this._stopped = false;
    const stat = this._stat();
    if (stat) {
      this._inode = stat.ino;
      // Start at the end: on a fresh boot the existing file is history, and
      // replaying it would fire notifications for people who walked past hours
      // ago.
      this._offset = this.fromStart ? 0 : stat.size;
    }
    // `_present` stays null so the first poll emits the initial transition —
    // consumers learn the collector is healthy from that event, and pre-setting
    // it here means they never hear about it.

    this._timer = setInterval(() => this._poll(), this.pollMs);
    this._timer.unref?.();
    this._poll();
  }

  stop() {
    this._stopped = true;
    if (this._timer) clearInterval(this._timer);
    this._timer = null;
  }

  /** True when the file exists and we are positioned in it. */
  get healthy() {
    return this._present === true;
  }

  _stat() {
    try {
      return statSync(this.file);
    } catch {
      return null;
    }
  }

  _poll() {
    if (this._stopped || this._reading) return;

    const stat = this._stat();
    if (!stat) {
      if (this._present !== false) {
        this._present = false;
        this.emit('presence', false);
      }
      return;
    }

    if (this._present !== true) {
      this._present = true;
      this.emit('presence', true);
    }

    // Rotated: a different file now answers to this name.
    if (this._inode !== null && stat.ino !== this._inode) {
      this._inode = stat.ino;
      this._offset = 0;
      this._partial = '';
    } else if (stat.size < this._offset) {
      // Truncated in place.
      this._offset = 0;
      this._partial = '';
    }
    if (this._inode === null) this._inode = stat.ino;

    if (stat.size > this._offset) this._read(stat.size);
  }

  _read(upTo) {
    const start = this._offset;
    if (upTo <= start) return;
    this._reading = true;

    const stream = createReadStream(this.file, {
      start,
      end: upTo - 1,
      encoding: 'utf8',
    });

    let consumed = 0;
    stream.on('data', (chunk) => {
      consumed += Buffer.byteLength(chunk, 'utf8');
      const text = this._partial + chunk;
      const lines = text.split('\n');
      // The last element is either '' (chunk ended on a newline) or a partial
      // line still being written — hold it until the rest arrives.
      this._partial = lines.pop() ?? '';
      for (const line of lines) this.emit('line', line);
    });

    stream.on('error', (err) => {
      this._reading = false;
      this.emit('error', err);
    });

    stream.on('close', () => {
      this._offset = start + consumed;
      this._reading = false;
    });
  }
}
