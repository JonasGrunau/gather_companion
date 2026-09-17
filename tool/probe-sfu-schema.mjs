/**
 * Which request shapes does Gather's SFU actually accept?
 *
 * `probe-sfu.mjs` records what the desktop client *sends*. This asks the server
 * directly what it *takes*: it connects one socket.io session to a media node
 * as the second (grunauluca) account, in the throwaway space, and sends each
 * candidate shape of a request, printing the ack — or the absence of one, which
 * on this socket is how zod says no. Nothing here carries media; a transport
 * and an audio producer are created and closed again so `produce` can be
 * exercised at all.
 *
 * It exists because of 2026-09-17: the phone had been sending
 * `set-player-conversation-metadata {meetingId: null, …}` for weeks, and the
 * server had been answering with silence. Five minutes here settled what a
 * month of reading the desktop's traffic could not, because the desktop never
 * sends the wrong shape.
 *
 * ```sh
 * node tool/probe-sfu-schema.mjs
 * IDB=~/Library/Application\ Support/GatherV2/IndexedDB/https_app.v2.gather.town_0.indexeddb.leveldb \
 *   SPACE=<space-id> node tool/probe-sfu-schema.mjs    # another account / space
 * ```
 *
 * Reads a Firebase refresh token out of the named profile's IndexedDB, the way
 * `probe-connect.mjs adopt` does, and mints an ID token. Defaults to the
 * instance-B profile in `~/.gather-alt/` so the primary account's desktop client
 * is never told it has a second connection. Findings are written up in
 * `docs/protocol/observed-wire-protocol.md`, "Schema probe".
 */
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';

const IDB = process.env.IDB ?? join(process.env.HOME, '.gather-alt/profile-b/IndexedDB/https_app.v2.gather.town_0.indexeddb.leveldb');
const KEY = 'AIzaSyDPwTbXLMPbIkg6UKr49VrHWwkrOdRh__E';
const SPACE = process.env.SPACE ?? 'bfe5d402-3a4c-4988-a3e8-b2a760371c14'; // the throwaway space
const SFU = 'wss://sfu-v2.eu-central-1-a.prod.aws.gather.town/ip-10-206-193-82';

function refreshTokens(dir) {
  const readString = (buf, i) => {
    if (buf[i] !== 0x22) return null;
    let len = 0, shift = 0, j = i + 1;
    for (; j < buf.length; j++) {
      len |= (buf[j] & 0x7f) << shift;
      if ((buf[j] & 0x80) === 0) { j++; break; }
      shift += 7;
      if (shift > 28) return null;
    }
    if (len <= 0 || len > 4096 || j + len > buf.length) return null;
    return buf.slice(j, j + len).toString('latin1');
  };
  const found = [];
  for (const file of readdirSync(dir).filter((f) => /\.(log|ldb)$/.test(f))) {
    const buf = readFileSync(join(dir, file));
    for (let at = buf.indexOf('refreshToken'); at !== -1; at = buf.indexOf('refreshToken', at + 1)) {
      const t = readString(buf, at + 'refreshToken'.length);
      if (t && t.length > 100 && /^[A-Za-z0-9_-]+$/.test(t)) found.push(t);
    }
  }
  return [...new Set(found.reverse())];
}

async function idToken() {
  for (const token of refreshTokens(IDB)) {
    const res = await fetch(`https://securetoken.googleapis.com/v1/token?key=${KEY}`, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ grant_type: 'refresh_token', refresh_token: token }),
    });
    if (res.ok) { const b = await res.json(); return { id: b.id_token, uid: b.user_id }; }
  }
  throw new Error('no working refresh token in ' + IDB);
}

class Sio {
  constructor(url, auth) {
    this.ws = new WebSocket(url);
    this.acks = new Map();
    this.nextAck = 0;
    this.seq = 0;
    this.ready = new Promise((res, rej) => { this.onConnect = res; this.onFail = rej; });
    this.ws.addEventListener('message', (e) => this.onMessage(String(e.data)));
    this.ws.addEventListener('error', (e) => this.onFail(new Error('ws error ' + (e.message ?? ''))));
    this.ws.addEventListener('close', (e) => console.log('  [close]', e.code, e.reason));
    this.auth = auth;
  }
  onMessage(m) {
    if (m[0] === '0') { this.ws.send('40' + JSON.stringify(this.auth)); return; }
    if (m === '2') { this.ws.send('3'); return; }
    if (m.startsWith('40')) { this.onConnect(JSON.parse(m.slice(2) || '{}')); return; }
    if (m.startsWith('44')) { this.onFail(new Error('CONNECT refused: ' + m.slice(2))); return; }
    const kind = m.slice(0, 2);
    const rest = m.slice(2);
    const idLen = rest.match(/^\d*/)[0].length;
    const id = idLen ? Number(rest.slice(0, idLen)) : null;
    const payload = JSON.parse(rest.slice(idLen));
    if (kind === '43') { const cb = this.acks.get(id); this.acks.delete(id); cb?.(payload); return; }
    if (kind === '42') { console.log('  [event]', JSON.stringify(payload).slice(0, 300)); return; }
    console.log('  [other]', m.slice(0, 200));
  }
  call(name, zodData, { bare = false, timeout = 5000 } = {}) {
    const id = this.nextAck++;
    const args = bare ? zodData : { wsSequenceNumber: ++this.seq, zodData };
    return new Promise((res) => {
      const t = setTimeout(() => { this.acks.delete(id); res('<<no ack in 5s>>'); }, timeout);
      this.acks.set(id, (p) => { clearTimeout(t); res(p); });
      this.ws.send('42' + id + JSON.stringify([name, args]));
    });
  }
  emit(name, zodData) {
    this.ws.send('42' + JSON.stringify([name, { wsSequenceNumber: ++this.seq, zodData }]));
  }
  close() { this.ws.send('41'); this.ws.close(); }
}

const short = (v) => { const s = JSON.stringify(v); return s.length > 260 ? s.slice(0, 260) + '…(' + s.length + 'B)' : s; };

const { id: token, uid } = await idToken();
console.log('account uid', uid.slice(0, 8) + '…');

const sfu = new Sio(`${SFU}/socket.io/?sessionId=${randomUUID()}&EIO=4&transport=websocket`, { spaceId: SPACE, token });
console.log('CONNECT ->', short(await sfu.ready));

const caps = await sfu.call('get-rtp-capabilities', {});
console.log('get-rtp-capabilities ->', typeof caps, Array.isArray(caps) ? Object.keys(caps[0] ?? {}) : caps);

const tests = [
  ['transport-create  desktop shape     ', { direction: 'send', iceTransportRequestOptions: { forceTurn: false, trafficAccelerator: 'GlobalAccelerator' } }],
];
let transportId = null;
for (const [label, args] of tests) {
  const r = await sfu.call('transport-create', args);
  const first = Array.isArray(r) ? r[0] : r;
  const ok = first && typeof first === 'object' && first.id;
  if (ok && !transportId) transportId = first.id;
  console.log(label, '->', ok ? `OK id=${first.id.slice(0, 8)}… keys=${Object.keys(first).join(',')}` : short(r));
}

for (const [label, args] of [
  ['metadata meetingId:null clusterId:null', { meetingId: null, clusterId: null }],
  ['metadata meetingId:"" clusterId:""    ', { meetingId: '', clusterId: '' }],
  ['metadata clusterId only               ', { clusterId: '' }],
  ['metadata meetingId:"" clusterId:uuid  ', { meetingId: '', clusterId: randomUUID() }],
]) {
  console.log(label, '->', short(await sfu.call('set-player-conversation-metadata', args)));
}

if (transportId) {
  const audioRtp = {
    mid: '0',
    codecs: [{ mimeType: 'audio/opus', payloadType: 111, clockRate: 48000, channels: 2,
      parameters: { minptime: 10, useinbandfec: 1, 'sprop-stereo': 0, usedtx: 1 },
      rtcpFeedback: [{ type: 'transport-cc', parameter: '' }, { type: 'nack', parameter: '' }] }],
    headerExtensions: [
      { uri: 'urn:ietf:params:rtp-hdrext:sdes:mid', id: 4, encrypt: false, parameters: {} },
      { uri: 'http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time', id: 2, encrypt: false, parameters: {} },
      { uri: 'http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01', id: 3, encrypt: false, parameters: {} },
      { uri: 'urn:ietf:params:rtp-hdrext:ssrc-audio-level', id: 1, encrypt: false, parameters: {} },
    ],
    encodings: [{ ssrc: 1000000000 + Math.floor(Math.random() * 1e9), active: true, dtx: true, maxBitrate: 24000 }],
    rtcp: { cname: 'probezod', reducedSize: true },
    msid: 'probe probe',
  };
  for (const [label, extra] of [
    ['produce audio  without highQualityScreenShare', {}],
    ['produce audio  with    highQualityScreenShare', { highQualityScreenShare: false }],
    ['produce audio  with    bogus unknown key      ', { bogusKey: 1 }],
  ]) {
    const r = await sfu.call('produce', { transportId, tag: 'audio', kind: 'audio', rtpParameters: audioRtp, ...extra });
    console.log(label, '->', short(r));
    sfu.emit('produce-close', { tag: 'audio' });
    await new Promise((r) => setTimeout(r, 300));
  }
  // Fields the phone sends for consume; a bogus peer is fine, only the schema matters.
  console.log('consume-request bogus peer ->', short(await sfu.call('consume-request', { srcId: randomUUID(), srcStreamId: SPACE, requested: true })));
}

await new Promise((r) => setTimeout(r, 500));
sfu.close();
await new Promise((r) => setTimeout(r, 300));
process.exit(0);
