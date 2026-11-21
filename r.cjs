// The v5 driver: zero-JSON, zero-copy streaming over cases.json.
//
// cases.json is read DIRECTLY into the WASM transducer's input region
// (fs.readSync into the memory buffer) and scanned structurally on that
// memory — never JSON.parse'd as a whole, and no case's bytes are ever
// copied in JS: for each case we locate the raw escaped bytes of its
// "text" string and the "header" flag that follows, point the transducer
// at the span in place, and let it assemble the case's complete answer
// object in its answer region (see transduce.wat). The driver writes
// that region to answers.json with a single writeSync per case.
//
// Fallbacks keep the output exact no matter what: a file larger than the
// input region is read into a JS Buffer instead and each case copied in
// (the v4 path); a case whose escaped text exceeds the input region, or
// for which the transducer reports overflow, is answered by solve.js
// (the semantic reference) via JSON.parse of just that case's string
// literal; if the structural scan does not recognize the file at all,
// the whole file is answered the v1 way (JSON.parse + solve.js).

const gb = typeof process.getBuiltinModule === 'function'
  ? process.getBuiltinModule.bind(process)
  : null;
const fs = gb ? gb('fs') : require('node:fs');
(gb ? gb('node:v8') : require('node:v8')).setFlagsFromString('--no-incremental-marking');

const INPUT_DIR = process.env.MAKEFUN_INPUT_DIR ?? '/input';
const OUTPUT_DIR = process.env.MAKEFUN_OUTPUT_DIR ?? '/output';

// WASM memory layout (must match transduce.wat).
const IN_BASE = 0x200000;
const IN_CAP = 0x1000000; // 16 MiB input region

const wasmBytes = fs.readFileSync(__dirname + '/w.wasm');
const instance = new WebAssembly.Instance(new WebAssembly.Module(wasmBytes), {});
const mem = instance.exports.memory;
const transduce = instance.exports.transduce;
const memBuf = Buffer.from(mem.buffer);

let solveRun = null;
function loadSolve() {
  if (solveRun === null) solveRun = require('./solve.js').run;
  return solveRun;
}

// ---- load cases.json -------------------------------------------------------
// Preferred path: the whole file lands in the WASM input region, so the
// scan below runs on a Buffer view of that memory and every case span is
// already where the transducer wants it. The memory is one fixed block
// that never grows, so the view stays valid for the whole run.
const inPath = INPUT_DIR + '/cases.json';
let data = null; // Buffer whose index 0 is file offset 0
let zeroCopy = false;
{
  const ifd = fs.openSync(inPath, 'r');
  const size = fs.fstatSync(ifd).size;
  if (size <= IN_CAP) {
    let off = 0;
    while (off < size) {
      const n = fs.readSync(ifd, memBuf, IN_BASE + off, size - off, off);
      if (n <= 0) break;
      off += n;
    }
    if (off === size) {
      data = memBuf.subarray(IN_BASE, IN_BASE + size);
      zeroCopy = true;
    }
  }
  fs.closeSync(ifd);
  if (data === null) data = fs.readFileSync(inPath);
}

// ---- structural scan -------------------------------------------------------
// Collect {s, e, header} per case: the escaped text spans [s, e) of the
// "text":"..." string body, plus the header flag after it. Both patterns
// can only occur structurally: inside a string body every quote byte is
// the second byte of a \" pair, so '","header":' — whose third byte is a
// quote preceded by a comma, not a backslash — never matches inside a
// body; the span end is the '","header":' match start. As a belt-and-
// braces check, the match is only accepted when the run of backslashes
// immediately before that quote is even (zero included), which is
// exactly the condition for it to be the string's closing quote; on an
// odd run the search resumes after the match. If anything is not found
// where it must be, the scan gives up and the driver falls back.
const TEXT_PAT = Buffer.from('"text":"');
const END_PAT = Buffer.from('","header":');
const cases = [];
let scanOk = true;
{
  let p = 0;
  for (;;) {
    const t = data.indexOf(TEXT_PAT, p);
    if (t === -1) break;
    const s = t + TEXT_PAT.length;
    let i = -1;
    let hb = 0;
    let from = s;
    for (;;) {
      const m = data.indexOf(END_PAT, from);
      if (m === -1) break;
      let bs = 0;
      let j = m - 1;
      while (j >= s && data[j] === 0x5c) { bs++; j--; }
      if ((bs & 1) === 1) { from = m + 1; continue; }
      const b = data[m + END_PAT.length];
      if (b !== 0x74 && b !== 0x66) break; // 't' | 'f'
      i = m;
      hb = b;
      break;
    }
    if (i === -1) { scanOk = false; break; }
    cases.push({ s, e: i, header: hb === 0x74 });
    p = i + 1;
  }
}

function fallbackCase(c) {
  const text = JSON.parse(data.toString('utf8', c.s - 1, c.e + 1));
  return Buffer.from(JSON.stringify(loadSolve()({ text, header: c.header })));
}

const OPEN = Buffer.from('[');
const CLOSE = Buffer.from(']');
const COMMA = Buffer.from(',');

function writeAll(ofd, buf, off, len) {
  let done = 0;
  while (done < len) {
    done += fs.writeSync(ofd, buf, off + done, len - done, null);
  }
}

if (!scanOk) {
  const all = JSON.parse(data.toString('utf8'));
  const run = loadSolve();
  fs.writeFileSync(
    OUTPUT_DIR + '/answers.json',
    Buffer.from(JSON.stringify(all.map((c) => run(c.input)))));
} else {
  const ofd = fs.openSync(OUTPUT_DIR + '/answers.json', 'w');
  writeAll(ofd, OPEN, 0, 1);
  for (let ci = 0; ci < cases.length; ci++) {
    if (ci > 0) writeAll(ofd, COMMA, 0, 1);
    const c = cases[ci];
    const len = c.e - c.s;
    let wrote = false;
    if (len <= IN_CAP) {
      let inPtr = IN_BASE;
      if (zeroCopy) {
        inPtr = IN_BASE + c.s;
      } else {
        data.copy(memBuf, IN_BASE, c.s, c.e);
      }
      let status = 1;
      try {
        transduce(inPtr, len, c.header ? 1 : 0);
        status = memBuf.readInt32LE(0);
      } catch {
        status = 1;
      }
      if (status === 0) {
        const ansPtr = memBuf.readInt32LE(16);
        const ansLen = memBuf.readInt32LE(20);
        writeAll(ofd, memBuf, ansPtr, ansLen);
        wrote = true;
      }
    }
    if (!wrote) {
      const fb = fallbackCase(c);
      writeAll(ofd, fb, 0, fb.length);
    }
  }
  writeAll(ofd, CLOSE, 0, 1);
  fs.closeSync(ofd);
}
