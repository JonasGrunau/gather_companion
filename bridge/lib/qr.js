/**
 * A QR code for a pairing payload, drawn into a terminal. No dependencies.
 *
 * The bridge ships with none and must keep it that way — the installed copy in
 * `~/.gather-app-bridge/bridge` is run straight from launchd with no
 * `node_modules` to resolve — so this is ISO/IEC 18004 by hand rather than a
 * library. That stays affordable by fixing everything the payload allows:
 *
 *   - **Versions 1 to 3** (21×21, 25×25, 29×29), the smallest that fits.
 *   - **Error correction level M**, which is a *single* block at all three, so
 *     there is no splitting and no interleaving. Version 4 would need both.
 *   - **Alphanumeric mode**, whose 45-character alphabet covers `0-9`, `A-Z`,
 *     `-`, `.` and `:` — a pairing code, and a `HOST:PORT:CODE` triple.
 *
 * Capacity runs 20, 38 and 61 characters. [encode] refuses anything longer
 * rather than emitting a symbol that cannot be scanned; a payload that outgrows
 * 61 needs version 4, and with it the block interleaving this deliberately
 * avoids.
 */

/** Symbol index per ISO/IEC 18004 table 5. Position in this string *is* the value. */
const ALPHANUMERIC = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:';

/**
 * The three sizes, at error correction level M.
 *
 * `align` is the centre of the one alignment pattern each version past the first
 * carries. Versions 2 and 3 define centres at 6 and that coordinate, and three
 * of the four combinations land on a finder — so exactly one pattern is drawn,
 * at the bottom right.
 */
const VERSIONS = [
  { version: 1, size: 21, data: 16, ecc: 10, chars: 20, align: null },
  { version: 2, size: 25, data: 28, ecc: 16, chars: 38, align: 18 },
  { version: 3, size: 29, data: 44, ecc: 26, chars: 61, align: 22 },
];

const MAX_CHARS = VERSIONS[VERSIONS.length - 1].chars;

/** Level M, as the two bits that go into the format information. */
const EC_LEVEL_BITS = 0b00;

// ---- GF(256) ------------------------------------------------------------------

// The field QR arithmetic happens in: bytes under the primitive polynomial
// x^8 + x^4 + x^3 + x^2 + 1, with 2 as the generator.
const EXP = new Uint8Array(512);
const LOG = new Uint8Array(256);
{
  let x = 1;
  for (let i = 0; i < 255; i++) {
    EXP[i] = x;
    LOG[x] = i;
    x <<= 1;
    if (x & 0x100) x ^= 0x11d;
  }
  // Doubled so a sum of two logs never needs a modulo.
  for (let i = 255; i < 512; i++) EXP[i] = EXP[i - 255];
}

const mul = (a, b) => (a === 0 || b === 0 ? 0 : EXP[LOG[a] + LOG[b]]);

/** The generator polynomial for [n] check symbols: ∏ (x - α^i). Highest degree first. */
function generatorPoly(n) {
  let g = [1];
  for (let i = 0; i < n; i++) {
    const next = new Array(g.length + 1).fill(0);
    for (let j = 0; j < g.length; j++) {
      next[j] ^= g[j];
      next[j + 1] ^= mul(g[j], EXP[i]);
    }
    g = next;
  }
  return g;
}

/**
 * Reed-Solomon check symbols: the remainder of data·x^n over [generatorPoly].
 *
 * Exported so the tests can pin it against the worked example in the standard —
 * it is the part of this file with no visible failure mode short of a code that
 * will not scan.
 */
export function checkSymbols(data, n) {
  const g = generatorPoly(n);
  const rem = new Uint8Array(data.length + n);
  rem.set(data);
  for (let i = 0; i < data.length; i++) {
    const factor = rem[i];
    if (factor === 0) continue;
    for (let j = 0; j < g.length; j++) rem[i + j] ^= mul(g[j], factor);
  }
  return Array.from(rem.subarray(data.length));
}

// ---- bitstream ----------------------------------------------------------------

class Bits {
  constructor() {
    this.bits = [];
  }

  push(value, width) {
    for (let i = width - 1; i >= 0; i--) this.bits.push((value >>> i) & 1);
  }

  get length() {
    return this.bits.length;
  }

  /** Terminated, byte-aligned, and padded to [dataCodewords] the way the spec says. */
  codewords(dataCodewords) {
    const capacity = dataCodewords * 8;
    // Up to four zero bits, or fewer if the stream nearly fills the capacity.
    for (let i = 0; i < 4 && this.bits.length < capacity; i++) this.bits.push(0);
    while (this.bits.length % 8 !== 0) this.bits.push(0);

    const out = [];
    for (let i = 0; i < this.bits.length; i += 8) {
      let byte = 0;
      for (let j = 0; j < 8; j++) byte = (byte << 1) | this.bits[i + j];
      out.push(byte);
    }
    // The two prescribed pad codewords, alternating, for whatever is left.
    for (let i = 0; out.length < dataCodewords; i++) out.push(i % 2 === 0 ? 0xec : 0x11);
    return out;
  }
}

/** Mode indicator, character count, then the payload in base-45 pairs. */
function encodeAlphanumeric(text) {
  const bits = new Bits();
  bits.push(0b0010, 4);
  // Nine bits for the count in versions 1 through 9.
  bits.push(text.length, 9);

  for (let i = 0; i < text.length; i += 2) {
    const first = ALPHANUMERIC.indexOf(text[i]);
    if (i + 1 === text.length) {
      bits.push(first, 6);
    } else {
      bits.push(first * 45 + ALPHANUMERIC.indexOf(text[i + 1]), 11);
    }
  }
  return bits;
}

// ---- the symbol ---------------------------------------------------------------

/**
 * Grid state. `dark` is the symbol; `fixed` marks the modules that belong to a
 * function pattern, which the data walk skips and the mask leaves alone.
 */
function blankGrid(size) {
  return {
    size,
    dark: Array.from({ length: size }, () => new Array(size).fill(false)),
    fixed: Array.from({ length: size }, () => new Array(size).fill(false)),
  };
}

function setFixed(grid, row, col, dark) {
  grid.dark[row][col] = dark;
  grid.fixed[row][col] = true;
}

/**
 * Finders, separators, timing, alignment, and the one module that is always dark.
 */
function drawFunctionPatterns(grid, spec) {
  const SIZE = grid.size;
  // Three finders, each with the light separator along its inner edges. Drawn
  // one module larger in every direction so the separator falls out of the same
  // loop; the out-of-range positions are simply skipped.
  for (const [top, left] of [
    [0, 0],
    [0, SIZE - 7],
    [SIZE - 7, 0],
  ]) {
    for (let dr = -1; dr <= 7; dr++) {
      for (let dc = -1; dc <= 7; dc++) {
        const row = top + dr;
        const col = left + dc;
        if (row < 0 || row >= SIZE || col < 0 || col >= SIZE) continue;
        const ring = Math.max(Math.abs(dr - 3), Math.abs(dc - 3));
        setFixed(grid, row, col, ring !== 2 && ring <= 3);
      }
    }
  }

  // Timing patterns: alternating modules bridging the finders, dark at even
  // coordinates.
  for (let i = 8; i < SIZE - 8; i++) {
    setFixed(grid, 6, i, i % 2 === 0);
    setFixed(grid, i, 6, i % 2 === 0);
  }

  // Just above the bottom-left finder, in the format strip. Always dark.
  setFixed(grid, SIZE - 8, 8, true);

  // The single alignment pattern, from version 2 on: a 5×5 target that lets a
  // reader correct for a symbol photographed at an angle. Drawn after the timing
  // patterns, which it is allowed to overlap and override.
  if (spec.align !== null) {
    for (let dr = -2; dr <= 2; dr++) {
      for (let dc = -2; dc <= 2; dc++) {
        const ring = Math.max(Math.abs(dr), Math.abs(dc));
        setFixed(grid, spec.align + dr, spec.align + dc, ring !== 1);
      }
    }
  }

  // Reserve both copies of the format information so the data walk steps over
  // them; the values are written once a mask has been chosen.
  for (let i = 0; i < 15; i++) {
    for (const [row, col] of formatPositions(i, SIZE)) {
      if (!grid.fixed[row][col]) setFixed(grid, row, col, false);
    }
  }
}

/**
 * Where bit [i] of the 15-bit format information lives, in both copies, as
 * `[row, col]`.
 *
 * The two copies run in opposite directions and are not each other's transpose:
 * the first goes down column 8 and then left along row 8, the second up column 8
 * from the bottom and then right along row 8. Writing one of them transposed
 * makes the copies disagree, and a reader that happens to trust the wrong one
 * recovers the wrong mask and decodes noise — with every function pattern still
 * perfectly in place, so the symbol looks entirely correct.
 */
function formatPositions(i, SIZE) {
  const first =
    i < 6 ? [i, 8] : i === 6 ? [7, 8] : i === 7 ? [8, 8] : i === 8 ? [8, 7] : [8, 14 - i];
  // Eight modules leftward along row 8, then seven downward along column 8. The
  // split matters twice over. Give the column eight and its last position is
  // (13, 8) — the always-dark module, which is not a format bit: the symbol then
  // has one module nobody reserved, the data walk puts an extra bit in it, and
  // every codeword after that lands one bit early, which shows up only as pad
  // codewords reading 0xD8 0x23 instead of 0xEC 0x11. Swap which half gets bits
  // 0-7 and the copy still passes a reader that only consults the other one,
  // which is a bug that survives every test until it meets a scanner that
  // prefers this copy.
  // `SIZE - 15 + i`, not `i + 6`. The two agree at version 1 and nowhere else:
  // this strip is anchored to the bottom edge, so writing it as a constant
  // offset from the top put it seven rows too high at version 2. The symbol
  // still decoded — the misplaced modules cost fewer errors than Reed-Solomon
  // can repair — which is the worst way for this to be wrong, because it spends
  // the entire error-correction budget on being wrong and leaves nothing for the
  // blur and glare a camera actually contributes.
  const second = i < 8 ? [8, SIZE - 1 - i] : [SIZE - 15 + i, 8];
  return [first, second];
}

/** BCH(15,5) over the level and mask, masked with the constant from the spec. */
function formatBits(mask) {
  const data = (EC_LEVEL_BITS << 3) | mask;
  let rem = data;
  for (let i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
  return ((data << 10) | rem) ^ 0x5412;
}

function drawFormat(grid, mask) {
  const bits = formatBits(mask);
  for (let i = 0; i < 15; i++) {
    const bit = ((bits >>> i) & 1) === 1;
    for (const [row, col] of formatPositions(i, grid.size)) {
      grid.dark[row][col] = bit;
      grid.fixed[row][col] = true;
    }
  }
}

/**
 * The zigzag walk: two-module columns from the right, alternating direction,
 * stepping over column 6 (the vertical timing pattern) and every function module.
 */
function drawCodewords(grid, codewords) {
  const SIZE = grid.size;
  let bit = 0;
  const total = codewords.length * 8;

  for (let right = SIZE - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5;
    for (let vert = 0; vert < SIZE; vert++) {
      for (let j = 0; j < 2; j++) {
        const col = right - j;
        const upward = ((right + 1) & 2) === 0;
        const row = upward ? SIZE - 1 - vert : vert;
        if (grid.fixed[row][col] || bit >= total) continue;
        grid.dark[row][col] = ((codewords[bit >>> 3] >>> (7 - (bit & 7))) & 1) === 1;
        bit++;
      }
    }
  }
}

const MASKS = [
  (row, col) => (row + col) % 2 === 0,
  (row) => row % 2 === 0,
  (row, col) => col % 3 === 0,
  (row, col) => (row + col) % 3 === 0,
  (row, col) => (Math.floor(col / 3) + Math.floor(row / 2)) % 2 === 0,
  (row, col) => ((row * col) % 2) + ((row * col) % 3) === 0,
  (row, col) => (((row * col) % 2) + ((row * col) % 3)) % 2 === 0,
  (row, col) => (((row + col) % 2) + ((row * col) % 3)) % 2 === 0,
];

function applyMask(grid, mask) {
  const test = MASKS[mask];
  for (let row = 0; row < grid.size; row++) {
    for (let col = 0; col < grid.size; col++) {
      if (!grid.fixed[row][col] && test(row, col)) grid.dark[row][col] = !grid.dark[row][col];
    }
  }
}

/**
 * The four penalties from the spec, summed. Lower is better.
 *
 * Readers accept any mask, so this only buys scan reliability — but the whole
 * point of a code on a screen is that it is read on the first try, and the
 * penalties are what steer away from a symbol full of look-alike finders.
 */
function penalty(grid) {
  const SIZE = grid.size;
  const lines = [];
  for (let i = 0; i < SIZE; i++) {
    let row = '';
    let col = '';
    for (let j = 0; j < SIZE; j++) {
      row += grid.dark[i][j] ? '1' : '0';
      col += grid.dark[j][i] ? '1' : '0';
    }
    lines.push(row, col);
  }

  let score = 0;

  // N1: every run of five or more, and every module beyond five.
  for (const line of lines) {
    let run = 1;
    for (let i = 1; i <= line.length; i++) {
      if (i < line.length && line[i] === line[i - 1]) {
        run++;
        continue;
      }
      if (run >= 5) score += 3 + (run - 5);
      run = 1;
    }
  }

  // N2: every 2×2 block of one colour.
  for (let row = 0; row < SIZE - 1; row++) {
    for (let col = 0; col < SIZE - 1; col++) {
      const a = grid.dark[row][col];
      if (a === grid.dark[row][col + 1] && a === grid.dark[row + 1][col] && a === grid.dark[row + 1][col + 1]) {
        score += 3;
      }
    }
  }

  // N3: the 1:1:3:1:1 finder ratio with four light modules to one side, which
  // is what makes a reader mistake part of the payload for a finder.
  for (const line of lines) {
    score += 40 * (count(line, '10111010000') + count(line, '00001011101'));
  }

  // N4: how far the proportion of dark modules strays from half, per 5%.
  let dark = 0;
  for (let row = 0; row < SIZE; row++) for (let col = 0; col < SIZE; col++) if (grid.dark[row][col]) dark++;
  const percent = (dark * 100) / (SIZE * SIZE);
  score += 10 * Math.floor(Math.abs(percent - 50) / 5);

  return score;
}

function count(haystack, needle) {
  let found = 0;
  for (let i = haystack.indexOf(needle); i !== -1; i = haystack.indexOf(needle, i + 1)) found++;
  return found;
}

/**
 * Encodes [text] as a version 1-M QR symbol, returning it as rows of booleans
 * where true is a dark module. No quiet zone — [render] adds that.
 *
 * @throws if [text] holds a character outside the alphanumeric set, or is longer
 *   than a version 1 symbol can carry.
 */
export function encode(text, { mask: forced = null } = {}) {
  const upper = String(text).toUpperCase();
  if (upper.length === 0 || upper.length > MAX_CHARS) {
    throw new Error(`this encoder holds 1 to ${MAX_CHARS} characters, not ${upper.length}`);
  }
  for (const ch of upper) {
    if (!ALPHANUMERIC.includes(ch)) throw new Error(`cannot encode ${JSON.stringify(ch)}`);
  }

  // The smallest that fits. A bigger symbol is not more robust — it is more
  // modules to resolve in the same amount of camera.
  const spec = VERSIONS.find((v) => upper.length <= v.chars);
  const data = encodeAlphanumeric(upper).codewords(spec.data);
  const codewords = [...data, ...checkSymbols(data, spec.ecc)];

  let best = null;
  for (let mask = 0; mask < MASKS.length; mask++) {
    if (forced !== null && mask !== forced) continue;
    const grid = blankGrid(spec.size);
    drawFunctionPatterns(grid, spec);
    drawCodewords(grid, codewords);
    applyMask(grid, mask);
    drawFormat(grid, mask);
    const score = penalty(grid);
    if (best === null || score < best.score) best = { score, grid };
  }
  return best.grid.dark.map((row) => [...row]);
}

// ---- drawing ------------------------------------------------------------------

/** Quiet zone, in modules, on every side. */
const QUIET = 2;

const FG_BLACK = '[30m';
const FG_WHITE = '[97m';
const BG_BLACK = '[40m';
const BG_WHITE = '[107m';
const RESET = '[0m';

/**
 * The symbol as lines ready to print, two module-rows per line.
 *
 * Both colours are always written, never left to the terminal: a dark-themed
 * terminal would otherwise render the light modules dark and the code would not
 * scan at all. Half-block characters keep the symbol square — a terminal cell is
 * about twice as tall as it is wide — and one `▀` with a foreground for the upper
 * module and a background for the lower covers all four combinations.
 *
 * @param {string} text
 * @param {{indent?: string}} [options]
 */
export function render(text, { indent = '' } = {}) {
  const modules = encode(text);
  const width = modules.length + QUIET * 2;
  const padded = [
    ...Array.from({ length: QUIET }, () => new Array(width).fill(false)),
    ...modules.map((row) => [
      ...new Array(QUIET).fill(false),
      ...row,
      ...new Array(QUIET).fill(false),
    ]),
    ...Array.from({ length: QUIET }, () => new Array(width).fill(false)),
  ];
  // An odd number of rows would leave the last line half-drawn; a light row
  // extends the quiet zone rather than clipping the symbol.
  if (padded.length % 2 !== 0) padded.push(new Array(width).fill(false));

  const lines = [];
  for (let row = 0; row < padded.length; row += 2) {
    let line = '';
    for (let col = 0; col < width; col++) {
      const upper = padded[row][col];
      const lower = padded[row + 1][col];
      line += `${upper ? FG_BLACK : FG_WHITE}${lower ? BG_BLACK : BG_WHITE}▀`;
    }
    lines.push(`${indent}${line}${RESET}`);
  }
  return lines;
}
