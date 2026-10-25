# Symmetric benchmark (stage 9, S1–S4)

One source, two executables. The only difference between them is the request path:

| Build | Cargo feature | Path of `bench_run` |
|---|---|---|
| `plain` | none | the operation runs for every request, as in a plain Tauri app |
| `runtime` | `runtime` | the request goes through `runtime_core::CachedService` (`NoStore` for S1–S3, a 1 h TTL for S4) |

Everything else is shared: the frontend, the round runner, the counters (atomics in Rust in both builds), the two windows, the release profile and `Cargo.lock` (the crate is a member of the root workspace) and `--locked`. The UI does no polling, history or live stats. The design is in [issue #13, design v2](https://github.com/kreeengvarotske/tauri-multi-window-runtime/issues/13#issuecomment-6399295696). Runtime Lab's public contract (`src/lib/runtime`, the `runtime_*` commands and their permissions) is not touched; the `bench_*` commands exist only in this app.

## Operation

`work(key, bufferMb, iterations)` allocates a `bufferMb` buffer (default 4 MB, at most 8), fills it from the key, makes `iterations` dependent passes over it and returns a 64-bit checksum. Only the checksum leaves the function; the buffer is freed before it returns. It runs on Tokio's blocking pool, never on an async worker. Rust tests pin reference checksums; the runner compares every response with the checksum computed by `bench_expected` before the load.

## Scenarios and expected counters per round

| ID | Windows × requests | Keys | plain | runtime |
|---|---|---|---|---|
| S1 | 1 × 1 | one | executed 1 | executed 1 |
| S2 | 2 × 10 | one | executed 20 | executed 1, coalesced 19 |
| S3 | 2 × 10 | 20 distinct | executed 20 | executed 20 |
| S4 | 2 × 10, no clear between rounds | one | executed 20 | round 1: executed 1, coalesced 19; later rounds: cache hits 20 |

A round passes only if every counter delta matches, every request succeeded and every checksum is right. These checks are about **correctness** (coalescing and caching happen exactly where they should). They are **not** evidence of lower RAM or CPU use; that is measured separately.

Both windows exist in every scenario, S1 included, so both builds always have the same windows and WebView2 processes.

## Load

Rounds start at a fixed cadence (`--round-interval-ms`, default 500 ms), so both builds get the same offered load and differ only in how much work they do for it. A round that runs past the next start is marked `overrun`. The secondary window starts its half first and confirms only after sending its requests, so main's requests overlap them. If the secondary fails or closes, the run stops, waits until no request is in flight (`clean`) or 10 s (`dirty`), and the report does not pass.

A run: wait for the secondary page → compute expected checksums → idle (`--idle-before`) → load (`--duration`) → idle (`--idle-after`) → write the report → exit. The report records the time of each phase so the monitor samples can be split by phase.

## Running

```powershell
cd benchmarks\symmetric
npm ci
npm test
# Builds both variants, runs 5 alternating pairs per scenario with the process monitor from PR #18.
.\scripts\Run-SymmetricPairs.ps1 -MonitorScript C:\path\to\tmwr-pr18\benchmarks\windows\Measure-ProcessTree.ps1 -OutputDirectory C:\path\to\results
.\scripts\Summarize-SymmetricRuns.ps1 -ResultsDirectory C:\path\to\results
```

One run by hand: `symmetric-bench.exe --scenario S2 --report out.json --duration 60` (`--iterations`, `--buffer-mb`, `--requests-per-window`, `--round-interval-ms`, `--idle-before`, `--idle-after`). Without `--report` the app starts interactively.

`Run-SymmetricPairs.ps1` pauses before every run (`-PauseSeconds`, default 30), starts each run from a fresh process, alternates the order (odd pairs plain first, even pairs runtime first) and keeps every report, monitor CSV, diagnostics CSV and log. It records the git SHA, the OS, WebView2, tool versions and the SHA256 of both executables and of the monitor script in `configuration.json`.

`Summarize-SymmetricRuns.ps1` writes `runs.csv`, `pairs.csv` (runtime − plain per pair), `summary.csv` and `summary.md`. The verdict for a metric is "runtime lower" or "runtime higher" only when every paired difference has the same sign and the absolute median difference is larger than the spread (max − min) of either build's own values; otherwise "within spread". Five pairs are an exploratory minimum, not statistical proof; when a difference is within the spread, run more pairs instead of drawing a conclusion.

Memory columns: `Private` is the sum of `PrivatePageCount` (bytes, checked by the monitor at startup) over the process tree; `ExePrivateMBLoadAvg` is the app process alone, `WebViewPrivateMBLoadAvg` the rest of the tree. Working set is a sum of working sets, not unique RAM.

## Not in scope here

S5 and S6 (memory-heavy scenarios) are deferred until S1–S4 have been reviewed.
