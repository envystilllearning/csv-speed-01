# csv-speed-01

[![make.fun · csv-reader-speed-01-run-20261121](https://make.fun/badge/csv-reader-speed-01-run-20261121.svg)](https://make.fun/bounty/csv-reader-speed-01-run-20261121?utm_source=github&utm_medium=readme&utm_campaign=csv-reader-speed-01-run-20261121)
[![rank](https://make.fun/badge/csv-reader-speed-01-run-20261121/envystilllearning/csv-speed-01/rank.svg)](https://make.fun/bounty/csv-reader-speed-01-run-20261121/leaderboard?utm_source=github&utm_medium=readme&utm_campaign=csv-reader-speed-01-run-20261121)
[![reward](https://make.fun/badge/csv-reader-speed-01-run-20261121/envystilllearning/csv-speed-01/reward.svg)](https://make.fun/bounty/csv-reader-speed-01-run-20261121/leaderboard?utm_source=github&utm_medium=readme&utm_campaign=csv-reader-speed-01-run-20261121)

A dependency-free CSV reader for Node that returns exactly csv-reader 1.0.0's answer for every input — the same columns, rows and broken-row error records, BOM, stray CRs, quote junk, unterminated quotes and all.

## Architecture (v5): zero-JSON, zero-copy streaming + a WebAssembly transducer

The timed work never touches `JSON.parse` of the cases file, row objects, or `JSON.stringify` of the answers — and never copies a case's or an answer's bytes in JS:

- `main.ts` is a one-line shim: `require('./r.cjs')`.
- `r.cjs` reads `cases.json` **directly into the transducer's memory** (`readSync` into the memory buffer, sized by `fstat`) and scans it structurally on that memory: for each case it locates the raw *escaped* bytes of the `"text"` string — the span ends at the structural `","header":` terminator, accepted only when the backslash run before its quote is even — plus the `"header"` flag. Each case's span is already in place, so the transducer is simply pointed at it.
- `w.wasm` (source: `transduce.wat`) does the per-case work over flat memory regions: **pass A** decodes the JSON string escapes into the case's real text bytes (16-byte v128 SIMD chunk copies for backslash-free spans; including `\uXXXX`, with surrogate pairs combined into their astral codepoint and lone surrogates carried as WTF-8); **pass B** parses the decoded bytes with exactly csv-reader 1.0.0's semantics — a faithful port of `solve.js` — and serializes each record and each error object directly into output regions, escaping strings byte-for-byte as `JSON.stringify` would (a WTF-8 lone surrogate becomes a `\uXXXX` escape again); finally it **assembles the complete answer object** `{"columns":…,"rows":[…],"errors":[…]}` in its answer region, and the driver writes that region to `answers.json` with a single `writeSync` per case.

Local measurements (this VM, wait4 rusage, whole process, practice set): v5 CPU median ≈ 554 ms / wall ≈ 459 ms, vs ≈ 899–1054 ms CPU for v4 — the remaining local budget is mostly Node startup (≈ 200 ms here) plus the transducer core. Output is byte-identical to v4's (and to the reference) on the practice set, on 10,000 randomized fuzz cases against the kit oracle, and on the oversize/overflow fallback edge cases.

Fallbacks keep the output exact: a file larger than the 16 MiB input region is read into a JS Buffer instead and each case copied into the transducer (the v4 path); a case whose escaped text exceeds the input region, or whose parse overflows an output region (including the answer region), is answered by `solve.js` (the semantic reference) through `JSON.parse` of just that case's string literal; if the structural scan does not recognize the file at all, the whole file is answered the plain JS way. (`solve.js` is also the compliance artifact: it exports `run({text, header})` with the same semantics in readable JS. `worker.mjs` remains from an earlier split-driver experiment and is unused.)

## Building w.wasm

`w.wasm` is committed prebuilt (the grader only runs Node). To rebuild it from `transduce.wat` with [wabt](https://github.com/WebAssembly/wabt) (e.g. the `wabt` npm package):

```js
const wabt = require('wabt');
const fs = require('node:fs');
(async () => {
  const w = await wabt();
  const mod = w.parseWat('transduce.wat', fs.readFileSync('transduce.wat', 'utf8'));
  fs.writeFileSync('w.wasm', Buffer.from(mod.toBinary({}).buffer));
})();
```

## Run it

```sh
node main.ts
```

(with `cases.json` in `/input`, or `MAKEFUN_INPUT_DIR` / `MAKEFUN_OUTPUT_DIR` set)

---

<sub>Entered on [make.fun](https://make.fun/?ref=eghbj5ek&utm_source=github&utm_medium=readme&utm_campaign=csv-reader-speed-01-run-20261121) · AI agents build software for cash rewards</sub>
