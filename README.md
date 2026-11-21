# csv-speed-01

[![make.fun · csv-reader-speed-01-run-20261121](https://make.fun/badge/csv-reader-speed-01-run-20261121.svg)](https://make.fun/bounty/csv-reader-speed-01-run-20261121?utm_source=github&utm_medium=readme&utm_campaign=csv-reader-speed-01-run-20261121)
[![rank](https://make.fun/badge/csv-reader-speed-01-run-20261121/envystilllearning/csv-speed-01/rank.svg)](https://make.fun/bounty/csv-reader-speed-01-run-20261121/leaderboard?utm_source=github&utm_medium=readme&utm_campaign=csv-reader-speed-01-run-20261121)
[![reward](https://make.fun/badge/csv-reader-speed-01-run-20261121/envystilllearning/csv-speed-01/reward.svg)](https://make.fun/bounty/csv-reader-speed-01-run-20261121/leaderboard?utm_source=github&utm_medium=readme&utm_campaign=csv-reader-speed-01-run-20261121)

A dependency-free CSV reader for Node that returns exactly csv-reader 1.0.0's answer for every input — the same columns, rows and broken-row error records, BOM, stray CRs, quote junk, unterminated quotes and all.

## Architecture (v4): zero-JSON streaming + a WebAssembly transducer

The timed work never touches `JSON.parse` of the cases file, row objects, or `JSON.stringify` of the answers:

- `main.ts` is a one-line shim: `require('./r.cjs')`.
- `r.cjs` reads `cases.json` as one Buffer and scans it structurally: for each case it locates the raw *escaped* bytes of the `"text"` string (escape-aware span scan) and the `"header"` flag after it. Each case's escaped bytes are copied into the transducer's memory; the answer is then assembled from the transducer's output regions with Buffer copies only.
- `w.wasm` (source: `transduce.wat`) does the per-case work in two passes over flat memory regions: **pass A** decodes the JSON string escapes into the case's real text bytes (including `\uXXXX`, with surrogate pairs combined into their astral codepoint and lone surrogates carried as WTF-8); **pass B** parses the decoded bytes with exactly csv-reader 1.0.0's semantics — a faithful port of `solve.js` — and serializes each record and each error object directly into output regions, escaping strings byte-for-byte as `JSON.stringify` would (a WTF-8 lone surrogate becomes a `\uXXXX` escape again). The driver wraps the regions as `{"columns":…,"rows":[…],"errors":[…]}` per case.

Fallbacks keep the output exact: a case whose escaped text exceeds the 16 MiB input region, or whose parse overflows an output region, is answered by `solve.js` (the semantic reference) through `JSON.parse` of just that case's string literal; if the structural scan does not recognize the file at all, the whole file is answered the plain JS way. (`solve.js` is also the compliance artifact: it exports `run({text, header})` with the same semantics in readable JS. `worker.mjs` remains from an earlier split-driver experiment and is unused.)

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
