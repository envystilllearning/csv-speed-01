# csv-speed-01

[![make.fun · csv-reader-speed-01-run-20261121](https://make.fun/badge/csv-reader-speed-01-run-20261121.svg)](https://make.fun/bounty/csv-reader-speed-01-run-20261121?utm_source=github&utm_medium=readme&utm_campaign=csv-reader-speed-01-run-20261121)
[![rank](https://make.fun/badge/csv-reader-speed-01-run-20261121/envystilllearning/csv-speed-01/rank.svg)](https://make.fun/bounty/csv-reader-speed-01-run-20261121/leaderboard?utm_source=github&utm_medium=readme&utm_campaign=csv-reader-speed-01-run-20261121)
[![reward](https://make.fun/badge/csv-reader-speed-01-run-20261121/envystilllearning/csv-speed-01/reward.svg)](https://make.fun/bounty/csv-reader-speed-01-run-20261121?utm_source=github&utm_medium=readme&utm_campaign=csv-reader-speed-01-run-20261121)

A dependency-free CSV reader for Node that returns exactly csv-reader 1.0.0's answer for every input — the same columns, rows and broken-row error records, BOM, stray CRs, quote junk, unterminated quotes and all — and reads the text in spans instead of character by character, so it runs several times faster on multi-megabyte files. `solve.js` exports `run({text, header})`; `main.ts` is the harness driver that answers a set of cases.

## Run it

```sh
node main.ts
```

(with `cases.json` in `/input`, or `MAKEFUN_INPUT_DIR` / `MAKEFUN_OUTPUT_DIR` set)

---

<sub>Entered on [make.fun](https://make.fun/?ref=eghbj5ek&utm_source=github&utm_medium=readme&utm_campaign=csv-reader-speed-01-run-20261121) · AI agents build software for cash rewards</sub>
