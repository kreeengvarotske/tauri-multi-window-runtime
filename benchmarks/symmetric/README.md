# Symmetric benchmark (stage 9, S1–S4)

One source, two executables. The only difference between them is the request path:

| Build | Cargo feature | Path of `bench_run` |
|---|---|---|
| `plain` | none | the operation runs for every request, as in a plain Tauri app |
| `runtime` | `runtime` | the request goes through `runtime_core::CachedService` (`NoStore` for S1–S3, a 1 h TTL for S4) |

Everything else is shared: the frontend, the round runner, the counters (atomics in Rust in both builds), the two windows, the release profile and `Cargo.lock` (the crate is a member of the root workspace) and `--locked`. The UI does no polling, history or live stats. The design is in [issue #13, design v2](https://github.com/kreeengvarotske/tauri-multi-window-runtime/issues/13#issuecomment-6399295696). Runtime Lab's public contract (`src/lib/runtime`, the `runtime_*` commands and their permissions) is not touched; the `bench_*` commands exist only in this app.

## Operation

`work(key, bufferMb, iterations)` allocates a `bufferMb` buffer (default 4 MB, at most 8), fills it from the key, makes `iterations` dependent passes over it and returns a 64-bit checksum. Only the checksum leaves the function; the buffer is freed before it returns. It runs on Tokio's blocking pool, never on an async worker. Rust tests pin reference checksums; the runner compares every response with the checksum computed by `bench_expected` before the load.

**Memory limit.** At most `2 × requestsPerWindow × bufferMb ≤ 128 MiB` of buffers can exist at once (every request of both windows running its own execution, as in `plain`). The app checks this when it parses its arguments, before any operation can run; an invalid combination exits with code 2 and, for an automated run, writes `{"configError": …, "passed": false}` to the report path. The default 2 × 10 × 4 MB is 80 MiB.

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
# Pilot: builds both variants, runs 5 alternating pairs per scenario with the process monitor.
.\scripts\Run-SymmetricPairs.ps1 -Phase Pilot -MonitorProfile Cpu -MonitorScript C:\path\to\Measure-ProcessTree.ps1 -OutputDirectory C:\results\pilot-cpu
.\scripts\Summarize-SymmetricRuns.ps1 -ResultsDirectory C:\results\pilot-cpu
```

One run by hand: `symmetric-bench.exe --scenario S2 --report out.json --duration 60` (`--iterations`, `--buffer-mb`, `--requests-per-window`, `--round-interval-ms`, `--idle-before`, `--idle-after`). Without `--report` the app starts interactively.

`Run-SymmetricPairs.ps1` pauses before every run (`-PauseSeconds`, default 30), starts each run from a fresh process, alternates the order (odd pairs plain first, even pairs runtime first) and keeps every report, monitor CSV, diagnostics CSV and log. It records the git SHA, the OS, WebView2, tool versions and the SHA256 of both executables and of the monitor script in `configuration.json`.

`Summarize-SymmetricRuns.ps1` writes `runs.csv`, `pairs.csv` (runtime − plain per pair), `summary.csv` and `summary.md`, with correctness (counters) and resources in separate tables, and the actual monitor intervals and the monitor's own CPU time per run.

## Monitoring profiles

Each profile goes to its own output directory and is summarized on its own:

| `-MonitorProfile` | Sampling | Compared | Why |
|---|---|---|---|
| `Cpu` (default) | 1 s | memory averages, CPU seconds, latency | the CPU comparison is made only at this one rate |
| `Ram` | 0.2 s | memory (average and peak), latency | sees more short peaks, but cannot guarantee catching each one; WMI every 0.2 s costs the observer more CPU, so CPU is not compared here. Needs a monitor that accepts fractional intervals (PR #19) |

The monitor runs as a separate process, so its own CPU is not in the app's sums; it is recorded per run (`MonitorCpuSeconds`) as the observer overhead. The idle phase before the load gives an idle CPU baseline (`IdleBeforeCpuSeconds`).

## Statistical rule (proposed, to be agreed before confirmatory runs)

- **Pilot:** the first 5 pairs per scenario and profile (`-Phase Pilot`). Summarized descriptively, marked "pilot: no conclusion", never pooled with confirmatory pairs. The pilot is for checking the experiment (counters, overruns, missing values, intervals, run-to-run spread), not for conclusions.
- **Confirmatory:** 10 new pairs per scenario and profile (`-Phase Confirmatory`), fresh processes, same alternating order, same machine and settings, recorded in `configuration.json`.
- **Primary metrics** per scenario: `Cpu` profile — `LoadCpuSeconds` and `LoadPrivateMBAvg`; `Ram` profile — `LoadPrivateMBPeak` and `LoadPrivateMBAvg`. Everything else is descriptive.
- **Test:** two-sided sign-flip permutation test of the paired differences (exact for up to 14 pairs, otherwise 20 000 random flips with a fixed seed), Holm correction over all primary tests of one results directory (2 metrics × 4 scenarios = 8).
- **Uncertainty:** 95% bootstrap interval of the median paired difference (10 000 resamples, fixed seed).
- **Decision:** "runtime lower" or "runtime higher" only if the Holm-adjusted p < 0.05, the interval excludes 0 and |median difference| ≥ 2% of the plain median. Otherwise "no detectable difference"; no winner is declared.
- **Extension:** if a primary metric shows no detectable difference after 10 pairs, at most one extension by another 10 pairs, analyzed together with the first 10 (20 confirmatory pairs); no further extension, no stopping early on a good result.
- Every pair is published. A failed or incomplete run stays in the data with its reason and is counted in `IncompletePairs`.

Memory columns: `Private` is the sum of `PrivatePageCount` (bytes, checked by the monitor at startup) over the process tree; `ExePrivateMBLoadAvg` is the app process alone, `WebViewPrivateMBLoadAvg` the rest of the tree. Working set is a sum of working sets, not unique RAM.

## Not in scope here

S5 and S6 (memory-heavy scenarios) are deferred until S1–S4 have been reviewed.
