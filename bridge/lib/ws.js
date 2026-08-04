import { createHash } from 'node:crypto';
import { EventEmitter } from 'node:events';

/**
 * Minimal RFC 6455 server, just enough for this bridge.
 *
 * Deliberately dependency-free: `install` copies the package into
 * ~/.superset-bridge/bridge and runs it straight from launchd, so a
 * self-contained tree with no node_modules to resolve is what makes that copy
 * safe.
 *
 * Only the server half lives here — the outbound connection to Superset's
 * /events uses Node's built-in WebSocket client (Node 22+).
 */

const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

/** Largest inbound message we will assemble. Clients only send tiny commands. */
const MAX_INBOUND = 1 << 20; // 1 MiB

/** Drop a client whose socket has fallen this far behind rather than grow forever. */
const MAX_BACKLOG = 8 << 20; // 8 MiB

export function isWebSocketUpgrade(req) {
  return (
    req.method === 'GET' &&
    String(req.headers.upgrade || '').toLowerCase() === 'websocket' &&
    typeof req.headers['sec-websocket-key'] === 'string'
  );
}

/** Completes the handshake and returns a connection, or null if malformed. */
export function acceptWebSocket(req, socket) {
  const key = req.headers['sec-websocket-key'];
  if (!key) {
    socket.destroy();
    return null;
  }
  const accept = createHash('sha1')
    .update(key + GUID)
    .digest('base64');

  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
      'Upgrade: websocket\r\n' +
      'Connection: Upgrade\r\n' +
      `Sec-WebSocket-Accept: ${accept}\r\n` +
      '\r\n',
  );
  socket.setNoDelay(true);
  socket.setTimeout(0);
  return new WsConnection(socket);
}

/** Builds an unmasked server frame. Exported for the framing tests. */
export function encodeFrame(opcode, payload = Buffer.alloc(0)) {
  const len = payload.length;
  let header;
  if (len < 126) {
    header = Buffer.alloc(2);
    header[1] = len;
  } else if (len < 65536) {
    header = Buffer.alloc(4);
    header[1] = 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(len), 2);
  }
  header[0] = 0x80 | opcode; // FIN, no RSV
  return Buffer.concat([header, payload]);
}

/** Emits `message` (string) and `close`. */
export class WsConnection extends EventEmitter {
  constructor(socket) {
    super();
    this.socket = socket;
    this.closed = false;
    this._buf = Buffer.alloc(0);
    this._fragments = [];
    this._fragmentOpcode = 0;
    this._fragmentLength = 0;

    socket.on('data', (chunk) => this._onData(chunk));
    socket.on('error', () => this._teardown());
    socket.on('close', () => this._teardown());
  }

  send(text) {
    if (this.closed) return;
    // A phone that stops reading (backgrounded, bad Wi-Fi) must not be able to
    // grow the daemon's heap without bound.
    if (this.socket.writableLength > MAX_BACKLOG) {
      this.close(1009);
      return;
    }
    try {
      this.socket.write(encodeFrame(0x1, Buffer.from(text, 'utf8')));
    } catch {
      this._teardown();
    }
  }

  close(code = 1000) {
    if (this.closed) return;
    const payload = Buffer.alloc(2);
    payload.writeUInt16BE(code, 0);
    try {
      this.socket.write(encodeFrame(0x8, payload));
      this.socket.end();
    } catch {
      /* already gone */
    }
    this._teardown();
  }

  _teardown() {
    if (this.closed) return;
    this.closed = true;
    try {
      this.socket.destroy();
    } catch {
      /* already gone */
    }
    this.emit('close');
  }

  _onData(chunk) {
    this._buf = this._buf.length ? Buffer.concat([this._buf, chunk]) : chunk;
    while (!this.closed && this._readFrame()) {
      /* keep draining */
    }
  }

  /** Returns true when a whole frame was consumed and another may follow. */
  _readFrame() {
    const buf = this._buf;
    if (buf.length < 2) return false;

    const fin = (buf[0] & 0x80) !== 0;
    const opcode = buf[0] & 0x0f;
    const masked = (buf[1] & 0x80) !== 0;
    let length = buf[1] & 0x7f;
    let offset = 2;

    if (length === 126) {
      if (buf.length < offset + 2) return false;
      length = buf.readUInt16BE(offset);
      offset += 2;
    } else if (length === 127) {
      if (buf.length < offset + 8) return false;
      const big = buf.readBigUInt64BE(offset);
      if (big > BigInt(MAX_INBOUND)) {
        this.close(1009);
        return false;
      }
      length = Number(big);
      offset += 8;
    }

    // RFC 6455 §5.1: every client-to-server frame is masked.
    if (!masked) {
      this.close(1002);
      return false;
    }
    if (buf.length < offset + 4) return false;
    const mask = buf.subarray(offset, offset + 4);
    offset += 4;

    if (buf.length < offset + length) return false;

    const payload = Buffer.from(buf.subarray(offset, offset + length));
    for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
    this._buf = buf.subarray(offset + length);

    // Control frames are never fragmented and may interleave with data frames.
    if (opcode >= 0x8) {
      if (opcode === 0x8) this.close(1000);
      else if (opcode === 0x9) {
        try {
          this.socket.write(encodeFrame(0xa, payload));
        } catch {
          this._teardown();
        }
      }
      return !this.closed;
    }

    if (opcode === 0x0 && this._fragments.length === 0) {
      this.close(1002); // continuation with nothing to continue
      return false;
    }

    if (opcode !== 0x0) this._fragmentOpcode = opcode;
    this._fragments.push(payload);
    this._fragmentLength += payload.length;
    if (this._fragmentLength > MAX_INBOUND) {
      this.close(1009);
      return false;
    }

    if (fin) {
      const message = Buffer.concat(this._fragments, this._fragmentLength);
      const isText = this._fragmentOpcode === 0x1;
      this._fragments = [];
      this._fragmentLength = 0;
      if (isText) this.emit('message', message.toString('utf8'));
    }
    return true;
  }
}
