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
# Confirmatory, only after the rule below is agreed: look 1, then (if needed) the extension and look 2.
.\scripts\Run-SymmetricPairs.ps1 -Phase Confirmatory -MonitorProfile Cpu -Pairs 10 -MonitorScript C:\path\to\Measure-ProcessTree.ps1 -OutputDirectory C:\results\confirm-cpu
.\scripts\Run-SymmetricPairs.ps1 -Phase Confirmatory -MonitorProfile Ram -Pairs 10 -ExecutablesFrom C:\results\confirm-cpu -MonitorScript C:\path\to\Measure-ProcessTree.ps1 -OutputDirectory C:\results\confirm-ram
.\scripts\Summarize-SymmetricRuns.ps1 -ResultsDirectory C:\results\confirm-cpu, C:\results\confirm-ram
.\scripts\Run-SymmetricPairs.ps1 -Phase Confirmatory -MonitorProfile Cpu -FirstPair 11 -Pairs 10 -Scenarios S1,S3 -ExecutablesFrom C:\results\confirm-cpu -MonitorScript C:\path\to\Measure-ProcessTree.ps1 -OutputDirectory C:\results\confirm-cpu-ext
.\scripts\Summarize-SymmetricRuns.ps1 -ResultsDirectory C:\results\confirm-cpu, C:\results\confirm-ram -ExtensionDirectory C:\results\confirm-cpu-ext
```

One run by hand: `symmetric-bench.exe --scenario S2 --report out.json --duration 60` (`--iterations`, `--buffer-mb`, `--requests-per-window`, `--round-interval-ms`, `--idle-before`, `--idle-after`). Without `--report` the app starts interactively.

`Run-SymmetricPairs.ps1` pauses before every run (`-PauseSeconds`, default 30), starts each run from a fresh process, alternates the order (odd pairs plain first, even pairs runtime first) and keeps every report, monitor CSV, diagnostics CSV and log. It records the git SHA, the OS, WebView2, tool versions and the SHA256 of both executables and of the monitor script in `configuration.json`.

`Summarize-SymmetricRuns.ps1` writes `runs.csv` (with validity), `pairs.csv` (runtime − plain per pair, with validity), `summary.csv` and `summary.md` into a new `analysis-<time>` directory, with correctness (counters) and resources in separate tables, and the actual monitor intervals and the monitor's own CPU time per run.

## Monitoring profiles

Each profile goes to its own output directory and is summarized on its own:

| `-MonitorProfile` | Sampling | Compared | Why |
|---|---|---|---|
| `Cpu` (default) | 1 s | memory averages, CPU seconds, latency | the CPU comparison is made only at this one rate |
| `Ram` | 0.2 s | memory (average and largest sample), latency | sees more short peaks, but cannot guarantee catching each one, so `LoadPrivateMBMaxSample` is the largest sampled value, not the true peak; WMI every 0.2 s costs the observer more CPU, so CPU is not compared here. Needs a monitor that accepts fractional intervals (PR #19) |

The monitor runs as a separate process, so its own CPU is not in the app's sums; it is recorded per run (`MonitorCpuSeconds`) as the observer overhead. The idle phase before the load gives an idle CPU baseline (`IdleBeforeCpuSeconds`).

## Statistical rule (proposed, to be agreed before confirmatory runs)

Fixed in `Summarize-SymmetricRuns.ps1` before any confirmatory pair runs; changing it afterwards would need a new, separately agreed series.

- **Estimand:** the median paired difference, runtime − plain, per scenario and metric, over valid pairs. The test, the interval and the effect threshold all refer to this one median; no mean is used.
- **Pilot:** the first 5 pairs per scenario and profile (`-Phase Pilot`). Summarized descriptively, marked "pilot: no conclusion", never pooled with confirmatory pairs. It checks the experiment (counters, overruns, validity, intervals, spread), not the effect.
- **Primary hypotheses, one family over both profiles:** per scenario, "the median paired difference of `LoadCpuSeconds` is 0" in the `Cpu` profile and "the median paired difference of `LoadPrivateMBAvg` is 0" in the `Ram` profile: 2 × 4 = 8 tests. Any overall claim ("runtime changes CPU or RAM in scenario X") rests only on these 8, and the familywise error over all of them is held at 0.05, so a headline across both profiles is covered. CPU is judged only at the 1 s rate and memory only at the 0.2 s rate. Everything else (memory in the `Cpu` profile, `LoadPrivateMBMaxSample`, working set, latency) is secondary and descriptive. A confirmatory analysis therefore takes the `Cpu` and the `Ram` directory together (`-ResultsDirectory cpu,ram`) and refuses one profile alone.
- **Test:** exact two-sided sign test of "median difference = 0". Zero differences carry no sign and are dropped, so the test is conditional on the non-zero ones; their count is shown (`ZeroDiffs`).
- **Interval:** the closed order-statistic interval for the median over all differences, zeros included, at level 1 − α of the look. Its stated coverage is a guaranteed minimum for any distribution, ties included, and is exact only for continuous differences. With zero differences it is not exactly the inversion of the sign test, so the decision uses only the test; the interval is reported alongside.
- **No rounding before statistics:** values are used as read from the monitor and report files; `runs.csv`, `pairs.csv` and `summary.csv` are written at full precision, only `summary.md` is rounded for reading. `Test-SymmetricStats.ps1` checks the test, the interval (with positive, negative and zero differences), its coverage by simulation with and without ties, and the joint `Cpu`/`Ram` family. `Test-SummarizerQuality.ps1` checks that failed launches remain visible, monitor failures invalidate a run, load-phase cadence is checked, non-finite values are rejected, and missing secondary-metric data is excluded metric-by-metric. Both run under PowerShell 7 and Windows PowerShell 5.1 in CI.
- **Looks (interim analysis accounted for):** the one confirmatory family spanning both profiles uses α = 0.05 and is split in advance between two looks (Bonferroni over looks: 0.025 + 0.025). Holm is applied to the predeclared family of 8 primary tests at each look; the look-2 tests are only those not rejected at look 1.
  - Look 1: confirmatory pairs 1–10 of both profiles (`-Phase Confirmatory`, `-FirstPair 1 -Pairs 10`). Holm over the 8 primary tests at α = 0.025.
  - A test rejected at look 1 is final. Only the undecided tests continue: pairs 11–20 run once, in a new directory (`-FirstPair 11 -Pairs 10`) with the same executables, monitor and settings, and only for the profiles and scenarios with an undecided test.
  - Look 2: pairs 1–20 together, Holm over the tests still undecided at α = 0.025. What is not rejected is "no detectable difference". There is no third look and no other early stop.
- **Decision:** a rejected test is "runtime lower" or "runtime higher" when |median difference| ≥ 2% of the plain median, otherwise "difference below 2% of plain". No winner is declared otherwise.
- **Power, stated in advance:** with 8 tests, look 1 can reject only if all 10 pairs are valid and have the same sign (smallest Holm-adjusted p = 8 × 2/1024 = 0.016; with 9 valid pairs it is 0.031, so nothing can be rejected); look 2 needs at most 3 of 20 pairs with the other sign. Smaller or less consistent effects end as "no detectable difference".
- **Minimum data:** a test needs at least 8 valid pairs in its look, otherwise "insufficient valid pairs". Invalid pairs are not replaced, so the order and the number of runs stay as planned.

## Run validity

A run is valid only if all of these hold; a pair is valid only if both runs are. Invalid runs and pairs stay in `runs.csv` and `pairs.csv` with `InvalidReason` and are left out of every median, interval and p-value. Every raw report and monitor file is kept.

- the report exists, is `passed` (every round had the expected counters), has no `abort`, and names the expected build and scenario;
- `runs.log` records app exit code 0, monitor exit code 0, and no timeout;
- all scheduled or logged launches appear in `runs.csv`, even if the app never wrote a JSON report; missing or malformed reports invalidate the run and remain auditable;
- the monitor CSV exists and covers at least 80% of expected load samples (load duration ÷ nominal interval); unparsable, NaN and infinite numeric values are treated as missing, never as zero;
- during the measured load (not merely across the whole session), the median actual interval is within ±20% of nominal, no sampling interval is missing/non-positive, and no load interval is longer than 5 × nominal;
- the primary metric is readable: CPU values for the `Cpu` profile and private-memory values for the `Ram` profile. Missing private-memory data does not automatically invalidate a CPU-primary run, and unreadable CPU data does not automatically invalidate a RAM-primary run; however, a secondary metric is included only when its own samples are valid for both runs of the pair.

The 80%, ±20% and 5× thresholds are checked against the pilot data before they are frozen. Overruns are not a validity criterion: if a build cannot keep up with the offered load, that is part of the result and is reported.

## Run order and protocol

`Run-SymmetricPairs.ps1` writes `schedule.csv` with every planned run before the first one: scenarios in the given order, pairs in order within a scenario, odd pairs plain first and even pairs runtime first. It copies this README to `protocol.md`, records the SHA256 of both scripts and of this README in `configuration.json`, and refuses to reuse a directory that already has results. `Summarize-SymmetricRuns.ps1` lists any run missing from, added to or out of order against the schedule under "Protocol deviations", and writes each analysis to a new `analysis-<time>` directory.

Memory columns: `Private` is the sum of `PrivatePageCount` (bytes, checked by the monitor at startup) over the process tree; `ExePrivateMBLoadAvg` is the app process alone, `WebViewPrivateMBLoadAvg` the rest of the tree. Working set is a sum of working sets, not unique RAM.

## Not in scope here

S5 and S6 (memory-heavy scenarios) are deferred until S1–S4 have been reviewed.
