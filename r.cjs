// The v4 driver: zero-JSON streaming over cases.json.
//
// cases.json is read as ONE Buffer and scanned structurally (never
// JSON.parse'd as a whole): for each case we locate the raw escaped bytes
// of its "text" string and the "header" flag that follows, copy the bytes
// into the WASM transducer's memory, and assemble that case's answer from
// the regions the transducer filled (see transduce.wat) with Buffer
// copies only — no row objects, no JSON.stringify of answers.
//
// Fallbacks keep the output exact no matter what: a case whose escaped
// text exceeds the WASM input region, or for which the transducer reports
// overflow, is answered by solve.js (the semantic reference) via
// JSON.parse of just that case's string literal. If the structural scan
// itself does not recognize the file, the whole file is answered the v1
// way (JSON.parse + solve.js).

const fs = require('node:fs');
const path = require('node:path');

require('node:v8').setFlagsFromString('--no-incremental-marking');

const INPUT_DIR = process.env.MAKEFUN_INPUT_DIR ?? '/input';
const OUTPUT_DIR = process.env.MAKEFUN_OUTPUT_DIR ?? '/output';

// WASM memory layout (must match transduce.wat).
const IN_BASE = 0x200000;
const IN_CAP = 0x1000000; // 16 MiB of escaped input per case
const TABLE = 0x1000;
const ERR_BASE = 0x4200000;

const wasmBytes = fs.readFileSync(path.join(__dirname, 'w.wasm'));
const instance = new WebAssembly.Instance(new WebAssembly.Module(wasmBytes), {});
const mem = instance.exports.memory;
const transduce = instance.exports.transduce;
const memBuf = Buffer.from(mem.buffer);

let solveRun = null;
function loadSolve() {
  if (solveRun === null) solveRun = require('./solve.js').run;
  return solveRun;
}

const data = fs.readFileSync(path.join(INPUT_DIR, 'cases.json'));

// ---- structural scan -------------------------------------------------------
// Collect {s, e, header} per case: the escaped text spans [s, e) of the
// "text":"..." string body, plus the header flag after it. The pattern
// '"text":"' can only occur structurally: inside a string body every
// quote is escaped, so the pattern's bare quotes never appear there, and
// we only search from outside a consumed span.
const TEXT_PAT = Buffer.from('"text":"');
const HDR_PAT = Buffer.from('"header":');
const cases = [];
let scanOk = true;
{
  let p = 0;
  for (;;) {
    const t = data.indexOf(TEXT_PAT, p);
    if (t === -1) break;
    const s = t + TEXT_PAT.length;
    let i = s;
    while (i < data.length) {
      const b = data[i];
      if (b === 0x5c) { i += 2; continue; }
      if (b === 0x22) break;
      i += 1;
    }
    if (i >= data.length) { scanOk = false; break; }
    const hIdx = data.indexOf(HDR_PAT, i);
    if (hIdx === -1 || hIdx > i + 64) { scanOk = false; break; }
    const hb = data[hIdx + HDR_PAT.length];
    if (hb !== 0x74 && hb !== 0x66) { scanOk = false; break; } // 't' | 'f'
    cases.push({ s, e: i, header: hb === 0x74 });
    p = i + 1;
  }
}

function assemble(header) {
  const recCount = memBuf.readInt32LE(4);
  const errLen = memBuf.readInt32LE(8);
  const parts = [Buffer.from('{"columns":')];
  const rec = (k) => {
    const off = memBuf.readInt32LE(TABLE + k * 8);
    const len = memBuf.readInt32LE(TABLE + k * 8 + 4);
    return memBuf.subarray(off, off + len);
  };
  let firstRow = 0;
  if (header) {
    parts.push(recCount > 0 ? rec(0) : Buffer.from('[]'));
    firstRow = 1;
  } else {
    parts.push(Buffer.from('null'));
  }
  parts.push(Buffer.from(',"rows":['));
  for (let k = firstRow; k < recCount; k++) {
    if (k > firstRow) parts.push(Buffer.from(','));
    parts.push(rec(k));
  }
  parts.push(Buffer.from('],"errors":['));
  if (errLen > 0) parts.push(memBuf.subarray(ERR_BASE, ERR_BASE + errLen));
  parts.push(Buffer.from(']}'));
  return Buffer.concat(parts);
}

function fallbackCase(c) {
  const text = JSON.parse(data.toString('utf8', c.s - 1, c.e + 1));
  return Buffer.from(JSON.stringify(loadSolve()({ text, header: c.header })));
}

let out;
if (!scanOk) {
  const all = JSON.parse(data.toString('utf8'));
  const run = loadSolve();
  out = Buffer.from(JSON.stringify(all.map((c) => run(c.input))));
} else {
  const parts = [Buffer.from('[')];
  for (let ci = 0; ci < cases.length; ci++) {
    if (ci > 0) parts.push(Buffer.from(','));
    const c = cases[ci];
    const len = c.e - c.s;
    let ans = null;
    if (len <= IN_CAP) {
      data.copy(memBuf, IN_BASE, c.s, c.e);
      let status = 1;
      try {
        transduce(IN_BASE, len, c.header ? 1 : 0);
        status = memBuf.readInt32LE(0);
      } catch {
        status = 1;
      }
      if (status === 0) ans = assemble(c.header);
    }
    parts.push(ans === null ? fallbackCase(c) : ans);
  }
  parts.push(Buffer.from(']'));
  out = Buffer.concat(parts);
}

fs.writeFileSync(path.join(OUTPUT_DIR, 'answers.json'), out);
