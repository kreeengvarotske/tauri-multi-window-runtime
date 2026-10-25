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
# Pilot: 5 alternating pairs per scenario/profile (separate exploratory dataset).
.\scripts\Run-SymmetricPairs.ps1 -Phase Pilot -MonitorProfile Cpu -MonitorScript C:\path\to\Measure-ProcessTree.ps1 -OutputDirectory C:\results\pilot-cpu
.\scripts\Run-SymmetricPairs.ps1 -Phase Pilot -MonitorProfile Ram -ExecutablesFrom C:\results\pilot-cpu -MonitorScript C:\path\to\Measure-ProcessTree.ps1 -OutputDirectory C:\results\pilot-ram
.\scripts\Summarize-SymmetricRuns.ps1 -ResultsDirectory C:\results\pilot-cpu
.\scripts\Summarize-SymmetricRuns.ps1 -ResultsDirectory C:\results\pilot-ram
# Confirmatory: one fixed series of 20 pairs in every scenario/profile. Review/freeze the protocol first.
.\scripts\Run-SymmetricPairs.ps1 -Phase Confirmatory -MonitorProfile Cpu -Pairs 20 -MonitorScript C:\path\to\Measure-ProcessTree.ps1 -OutputDirectory C:\results\confirm-cpu
.\scripts\Run-SymmetricPairs.ps1 -Phase Confirmatory -MonitorProfile Ram -Pairs 20 -ExecutablesFrom C:\results\confirm-cpu -MonitorScript C:\path\to\Measure-ProcessTree.ps1 -OutputDirectory C:\results\confirm-ram
.\scripts\Summarize-SymmetricRuns.ps1 -ResultsDirectory C:\results\confirm-cpu, C:\results\confirm-ram
```

One run by hand: `symmetric-bench.exe --scenario S2 --report out.json --duration 60` (`--iterations`, `--buffer-mb`, `--requests-per-window`, `--round-interval-ms`, `--idle-before`, `--idle-after`). Without `--report` the app starts interactively.

`Run-SymmetricPairs.ps1` pauses before every run (`-PauseSeconds`, default 30), starts each run from a fresh process, alternates the order (odd pairs plain first, even pairs runtime first) and keeps every report, monitor CSV, diagnostics CSV and log. It records the git SHA, the OS, WebView2, tool versions and the SHA256 of both executables and of the monitor script in `configuration.json`.

`Summarize-SymmetricRuns.ps1` writes `runs.csv` (with validity), `pairs.csv` (runtime − plain per pair, with validity), `summary.csv` and `summary.md` into a new `analysis-<time>` directory, with correctness (counters) and resources in separate tables, and the actual monitor intervals and the monitor's own CPU time per run.

## Monitoring profiles

Each profile goes to its own output directory and is summarized on its own:

| `-MonitorProfile` | Sampling | Compared | Why |
|---|---|---|---|
| `Cpu` (default) | 1 s | memory averages, CPU seconds, latency | the CPU comparison is made only at this one rate |
| `Ram` | 0.2 s | memory (average and largest sample), latency | sees more short peaks, but cannot guarantee catching each one, so `LoadPrivateMBMaxSample` is the largest sampled value, not the true peak; WMI every 0.2 s costs the observer more CPU, so CPU is not compared here. Needs a monitor that accepts fractional intervals; use the current monitor proposal in PR #24, not a stale-base branch. |

The monitor runs as a separate process, so its own CPU is not in the app's sums; it is recorded per run (`MonitorCpuSeconds`) as the observer overhead. The idle phase before the load gives an idle CPU baseline (`IdleBeforeCpuSeconds`).

## Statistical rule (fixed-N proposal; review and freeze before confirmatory runs)

The code enforces this protocol: changes after the first confirmatory pair require a new, separately agreed series. Do not begin the confirmatory series until the project review explicitly approves this rule.

- **Estimand:** the median paired difference, runtime − plain, per scenario and metric, over valid pairs. The test, the interval and the effect threshold all refer to this one median; no mean is used.
- **Pilot:** the first 5 pairs per scenario and profile (`-Phase Pilot`). Summarized descriptively, marked "pilot: no conclusion", never pooled with confirmatory pairs. It checks the experiment (counters, overruns, validity, intervals, spread), not the effect.
- **Primary hypotheses, one family over both profiles:** per scenario, "the median paired difference of `LoadCpuSeconds` is 0" in the `Cpu` profile and "the median paired difference of `LoadPrivateMBAvg` is 0" in the `Ram` profile: 2 × 4 = 8 tests. Any overall claim ("runtime changes CPU or RAM in scenario X") rests only on these 8, and the familywise error over all of them is held at 0.05, so a headline across both profiles is covered. CPU is judged only at the 1 s rate and memory only at the 0.2 s rate. Everything else (memory in the `Cpu` profile, `LoadPrivateMBMaxSample`, working set, latency) is secondary and descriptive. A confirmatory analysis therefore takes the `Cpu` and the `Ram` directory together (`-ResultsDirectory cpu,ram`) and refuses one profile alone.
- **Test:** two-sided sign test of "the median of all valid paired differences is 0". Every valid pair stays in n; an exact zero counts as neither positive nor negative. If 0 is a median, P(d > 0) ≤ ½ and P(d < 0) ≤ ½, so each sign count is at most Binomial(n, ½) in distribution, and p = 2 · min(P(X ≥ positives), P(X ≥ negatives)) is valid. It is exact for continuous differences (then it equals the usual sign test) and conservative when there are zeros, so 10 positive differences and 10 zeros give p = 1, not 10/10 evidence. The zero count is shown (`ZeroDiffs`).
- **Interval:** the closed order-statistic 95% interval for the median over all differences, zeros included. Its stated coverage is a guaranteed minimum for any distribution, ties included, and is exact only for continuous differences. The decision uses the sign test plus the practical-effect threshold; the interval is reported alongside.
- **No rounding before statistics:** values are used as read from the monitor and report files; `runs.csv`, `pairs.csv` and `summary.csv` are written at full precision, only `summary.md` is rounded for reading. `Test-SymmetricStats.ps1` checks the test, the interval (with a mix of positive, negative and zero differences), its coverage by simulation with and without ties, and an end-to-end summary of synthetic `Cpu` and `Ram` results as one family.
- **Confirmatory sample size:** exactly 20 planned pairs for each of S1–S4 in both profiles. One analysis occurs only after both complete schedules have been run; there is no analysis after pair 10, no interim stopping or extension, and no data-dependent selection of hypotheses. Holm is applied once at α = 0.05 to the fixed family of 8 primary hypotheses. A hypothesis with fewer than 8 valid pairs has p = 1 for the family correction and the report says "insufficient valid pairs"; failed/missing pairs are retained as invalid and never replaced.
- **Decision:** a rejected test is "runtime lower" or "runtime higher" when |median difference| ≥ 2% of the plain median, otherwise "difference below 2% of plain". No winner is declared otherwise.
- **Power, stated in advance:** with a fixed family of 8 tests and 20 pairs, 17 or more valid differences in one direction (at most 3 in the other direction or zero) gives the worst-case Holm-adjusted p no larger than 8 × 2 × 1351/2^20 ≈ 0.0206. Sixteen in one direction is not enough for the worst-case Holm threshold. Smaller or less consistent effects end as "no detectable difference".
- **Minimum data:** a primary test needs at least 8 valid pairs; otherwise it remains in the fixed family with p = 1 and is reported as "insufficient valid pairs". Invalid pairs are not replaced, so every scheduled series remains fixed at 20 pairs.

## Run validity

A run is valid only if all of these hold; a pair is valid only if both runs are. Invalid runs and pairs stay in `runs.csv` and `pairs.csv` with `InvalidReason` and are left out of every median, interval and p-value. A scheduled or logged launch without a JSON report is listed as an invalid run, so a crash cannot drop a pair. Every raw report and monitor file is kept.

- the report exists, is `passed` (every round had the expected counters), has no `abort`, and names the expected build and scenario;
- `runs.log` has the run with app exit code 0, no timeout and monitor exit code 0;
- the monitor CSV exists and covers at least 80% of the expected load samples (load duration ÷ nominal interval);
- in the `Cpu` profile, all load-phase CPU samples are readable and finite; in the `Ram` profile, all load-phase private-memory samples are readable and finite (CPU is not compared in the `Ram` profile);
- every load row has a positive, finite interval; the median interval **within the load phase** is within ±20% of nominal and no load interval is longer than 5 × nominal (the whole-run median is reported for context only);
- the profile's primary metric could be computed.

Incomplete **secondary** metrics do not invalidate an otherwise valid primary run. Instead, that metric is excluded from any pairwise summary unless both builds have complete finite samples for that metric; the counts are shown as `MetricExcludedPairs` in `summary.csv` and `summary.md`. This avoids averaging only the readable samples and silently changing the measured quantity.

The 80%, ±20% and 5× thresholds are checked against the pilot data before they are frozen. Overruns are not a validity criterion: if a build cannot keep up with the offered load, that is part of the result and is reported.

## Run order and protocol

`Run-SymmetricPairs.ps1` writes `schedule.csv` with every planned run before the first one: scenarios in the given order, pairs in order within a scenario, odd pairs plain first and even pairs runtime first. It copies this README to `protocol.md`, records the SHA256 of both scripts and of this README in `configuration.json`, and refuses to reuse a directory that already has results. `Summarize-SymmetricRuns.ps1` lists any run missing from, added to or out of order against the schedule under "Protocol deviations", and writes each analysis to a new `analysis-<time>` directory.

Memory columns: `Private` is the sum of `PrivatePageCount` (bytes, checked by the monitor at startup) over the process tree; `ExePrivateMBLoadAvg` is the app process alone, `WebViewPrivateMBLoadAvg` the rest of the tree. Working set is a sum of working sets, not unique RAM.

## Not in scope here

S5 and S6 (memory-heavy scenarios) are deferred until S1–S4 have been reviewed.
