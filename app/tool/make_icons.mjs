#!/usr/bin/env node
/**
 * Draws the Gather Companion app icon and writes every size the iOS asset
 * catalogue asks for.
 *
 * The icon is generated rather than committed as an opaque blob so the design is
 * reviewable and re-renderable: change a constant here, re-run, and every size
 * updates in step. Zero dependencies — the PNG encoder is `node:zlib` plus a
 * CRC table, in the same spirit as the bridge's hand-rolled `qr.js`.
 *
 * The mark is a proximity ping on a 32×32 pixel grid: you are the white block in
 * the middle, the two rings are the radius the bridge watches, and the green
 * marker on the outer ring is somebody who just walked into it. Pixel geometry
 * nods at the medium (a tile-grid virtual office) without borrowing anything
 * from Gather's own mark; the palette is the app's own `GatherTokens.dark`.
 *
 *   node app/tool/make_icons.mjs [--preview]
 */

import { deflateSync } from 'node:zlib';
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const iconset = join(here, '..', 'ios', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset');

// ── palette ────────────────────────────────────────────────────────────────
// Straight out of lib/theme/gather_theme.dart, so the icon and the first screen
// the user sees are the same few colours.
const BG_TOP = [0x24, 0x2B, 0x52]; // lifted indigo, so the tile is not a black hole on a wallpaper
const BG_BOTTOM = [0x0D, 0x10, 0x1F]; // deeper than `background`, so the tile has a floor
const BRAND = [0x42, 0x57, 0xDA]; // GatherTokens.brand
const BRAND_SOFT = [0x68, 0x86, 0xF2]; // GatherTokens.brandSoft
const FOREGROUND = [0xEC, 0xEE, 0xF5]; // GatherTokens.foreground
const OK = [0x3F, 0xBF, 0x87]; // GatherTokens.ok — the "someone is here" marker

// ── the mark, on a 32×32 cell grid ─────────────────────────────────────────
const GRID = 32;
const C = GRID / 2; // centre of the grid, in cell units

const RING_R = 9; // the watched radius — leaves the margin iOS tiles want
const RING_W = 1; // half-thickness, in cells — so the ring is 2 cells thick
const PING_ANGLE = 45; // degrees, counter-clockwise from east

const pingX = C + RING_R * Math.cos((PING_ANGLE * Math.PI) / 180);
const pingY = C - RING_R * Math.sin((PING_ANGLE * Math.PI) / 180);

/**
 * Colour of one cell of the mark, or null where the background shows through.
 * Returns `[r, g, b, alpha]` with alpha in 0..1.
 *
 * Three shapes and no more: at 29px an icon gets about that many before it
 * turns to soup.
 */
function cell(cx, cy) {
  const x = cx + 0.5;
  const y = cy + 0.5;
  const dx = x - C;
  const dy = y - C;
  const d = Math.hypot(dx, dy);

  // Whoever just walked into range: a 4×4 block, corners knocked off, sitting
  // on the ring like a bead on a wire.
  const px = x - pingX;
  const py = y - pingY;
  if (Math.abs(px) < 2 && Math.abs(py) < 2 && !(Math.abs(px) > 1 && Math.abs(py) > 1)) {
    return [...OK, 1];
  }

  // "You": the same block shape, larger and white, dead centre.
  if (Math.abs(dx) < 3 && Math.abs(dy) < 3 && !(Math.abs(dx) > 2 && Math.abs(dy) > 2)) {
    return [...FOREGROUND, 1];
  }

  // The ring, cut back around the ping so the two never touch.
  if (Math.abs(d - RING_R) <= RING_W && Math.hypot(px, py) > 4.2) {
    return [...BRAND_SOFT, 0.95];
  }

  return null;
}

/**
 * A soft brand-coloured bloom under the centre block — the ping going out.
 * Continuous rather than cell-quantised, so it stays smooth behind the pixels.
 */
function glow(u, v) {
  const d = Math.hypot(u * GRID - C, v * GRID - C);
  const t = Math.max(0, 1 - d / RING_R);
  return 0.5 * Math.pow(t, 1.7);
}

// Bake the grid once; every output size samples the same 32×32 map.
const MAP = Array.from({ length: GRID }, (_, cy) =>
  Array.from({ length: GRID }, (_, cx) => cell(cx, cy)),
);

/** Background gradient at normalised position `t` (0 = top, 1 = bottom). */
function background(t) {
  // Eased so most of the tile stays dark and the lift reads as light from above.
  const k = Math.pow(t, 0.85);
  return [
    BG_TOP[0] + (BG_BOTTOM[0] - BG_TOP[0]) * k,
    BG_TOP[1] + (BG_BOTTOM[1] - BG_TOP[1]) * k,
    BG_TOP[2] + (BG_BOTTOM[2] - BG_TOP[2]) * k,
  ];
}

/**
 * Renders the icon at `size`×`size`, supersampled `SS`× per axis so the cell
 * edges land smooth at 29px instead of chewed.
 */
function render(size) {
  const SS = 4;
  const px = Buffer.alloc(size * size * 3);
  for (let py = 0; py < size; py++) {
    for (let pxi = 0; pxi < size; pxi++) {
      let r = 0;
      let g = 0;
      let b = 0;
      for (let sy = 0; sy < SS; sy++) {
        for (let sx = 0; sx < SS; sx++) {
          const u = (pxi + (sx + 0.5) / SS) / size;
          const v = (py + (sy + 0.5) / SS) / size;
          const bg = background(v);
          const gl = glow(u, v);
          for (let i = 0; i < 3; i++) bg[i] = bg[i] * (1 - gl) + BRAND[i] * gl;
          const c = MAP[Math.min(GRID - 1, Math.floor(v * GRID))][
            Math.min(GRID - 1, Math.floor(u * GRID))
          ];
          if (c) {
            const a = c[3];
            r += c[0] * a + bg[0] * (1 - a);
            g += c[1] * a + bg[1] * (1 - a);
            b += c[2] * a + bg[2] * (1 - a);
          } else {
            r += bg[0];
            g += bg[1];
            b += bg[2];
          }
        }
      }
      const n = SS * SS;
      const o = (py * size + pxi) * 3;
      px[o] = Math.round(r / n);
      px[o + 1] = Math.round(g / n);
      px[o + 2] = Math.round(b / n);
    }
  }
  return px;
}

// ── PNG encoder (8-bit RGB, no alpha — App Store rejects transparent icons) ──
const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();

function crc32(buf) {
  let c = -1;
  for (const byte of buf) c = CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'latin1'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}

function encodePng(size, rgb) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 2; // colour type: truecolour
  const stride = size * 3;
  const raw = Buffer.alloc((stride + 1) * size);
  for (let y = 0; y < size; y++) {
    raw[y * (stride + 1)] = 0; // filter: none
    rgb.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

// ── outputs ────────────────────────────────────────────────────────────────
const TARGETS = {
  'Icon-App-20x20@1x.png': 20,
  'Icon-App-20x20@2x.png': 40,
  'Icon-App-20x20@3x.png': 60,
  'Icon-App-29x29@1x.png': 29,
  'Icon-App-29x29@2x.png': 58,
  'Icon-App-29x29@3x.png': 87,
  'Icon-App-40x40@1x.png': 40,
  'Icon-App-40x40@2x.png': 80,
  'Icon-App-40x40@3x.png': 120,
  'Icon-App-60x60@2x.png': 120,
  'Icon-App-60x60@3x.png': 180,
  'Icon-App-76x76@1x.png': 76,
  'Icon-App-76x76@2x.png': 152,
  'Icon-App-83.5x83.5@2x.png': 167,
  'Icon-App-1024x1024@1x.png': 1024,
};

mkdirSync(iconset, { recursive: true });
const cache = new Map();
for (const [name, size] of Object.entries(TARGETS)) {
  if (!cache.has(size)) cache.set(size, encodePng(size, render(size)));
  writeFileSync(join(iconset, name), cache.get(size));
  console.log(`  ${name.padEnd(30)} ${size}×${size}`);
}

if (process.argv.includes('--preview')) {
  const out = join(here, 'icon-preview.png');
  writeFileSync(out, encodePng(512, render(512)));
  console.log(`  preview → ${out}`);
}
