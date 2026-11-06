# Memory benchmark: scenario M (shared catalog)

The app for the memory pilot in `docs/benchmark/memory-pilot-protocol.md` (PR #33). It asks one question: when several windows show the same data set, how much memory does the process tree save if the data lives once in Rust instead of once per window, and what does the framework cost on top of a hand-written service?

One source, one executable per arm. Only the data source differs:

| Arm | Cargo feature | Where the catalog lives | What crosses IPC per step |
|---|---|---|---|
| **A** per-window | none | each window calls `catalog_load` once, keeps the whole catalog in its JS heap and builds its own indexes | nothing |
| **B** shared, hand-written | `shared` | one `Catalog` with its indexes, managed Tauri state; `catalog_page`, `catalog_aggregate`, `catalog_get` | one page (≤ 100 rows), the 32 totals or ≤ 20 records |
| **C** framework | `framework` | the same `Catalog` and indexes as the cached output of one `Shared` operation (`catalog.load`, `CachePolicy::Forever`) in `shared-runtime`; pages, totals and records are `View`s that charge a `ResponseBudget` per item; the same three commands with the same request checks | as B |

Arm C uses `shared-runtime` from #35 at `b65177d76fbea799e3afe6504ff255cec7c0da88`. That is the head Group 1 reviewed and accepted for arm C (#35 comment 6446126629). It is merged into this branch by merge commit `29aece3`, on top of `5be3846`. Nothing else in #35 is changed here. The runtime limits are set in `framework::runtime_config`:
- one execution slot and a queue of 4;
- `N` concurrent projections;
- a 10 s deadline and a 2 s shutdown grace;
- a cache budget of 2 × `D` + 16 MiB.

At startup, arm C loads the catalog into the runtime's cache before the windows open, as arms A and B generate it at startup. The runner still refuses `-Phase Pilot` until there is a native smoke of all three arms and the frozen protocol has had its final check (#33 §10).

Everything else is the same in all arms: the frontend (`src/window.ts` runs one window; only `setupSource` picks the source), the table, the windows (`main`, `w1`…), the workload, the timing, the release profile, `Cargo.lock` (the crate is a member of the root workspace) and `--locked`. Runtime Lab and its public IPC contract are not touched; the `catalog_*` commands exist only in this app.

## Data set

`catalog::generate(seed, D)` builds records (id, name, category 0–31, price, two timestamps, a short note) from a xorshift generator until the Rust representation reaches `D` bytes: struct sizes, string capacities and the three `u32` indexes (`catalog::data_bytes`). The app reports that exact size (`config.rustDataBytes`) and the record count in every report. D16 is on the order of 100 k records; the exact count is in every report. Every arm generates the catalog once at startup so that they do the same work before the measured phases. Arm B keeps it with its indexes. Arm C builds the same catalog and indexes inside the runtime's operation and keeps it in the runtime's cache. Arm A drops it and serves `catalog_load` from a fresh copy per call, as a plain backend reading a file would.

Arm A builds in JS the same indexes the Rust service has (by name, by price, by category and price, and the per-category totals), so in both arms each step costs work proportional to its response, not to the data set.

## Workload

Every window runs the same 15-step cycle (`workload::cycle`), one step every `--step-interval-ms` (default 500 ms): page 1 of 100 rows sorted by name, 10 more pages, sort by price, filter one category sorted by price, the per-category totals, 20 records by id. Windows start at different pages, filter different categories and read different ids. Each response is rendered into the table and its checksum (FNV-1a 32 over a canonical text, `catalog.ts`/`catalog.rs`) compared with the one computed by a naive reference implementation from a separate, transient copy of the data before the load. `src/fixtures/catalog-small.json` is written by a Rust test so the frontend tests check arm A against the Rust reference.

A run: every window sets up its source and shows the first page → main fixes the plan once all are ready → idle (`--idle-before`, 20 s) → warm-up (`--warmup`, 30 s, the workload runs, not measured) → load (`--duration`, 120 s) → idle (`--idle-after`, 30 s) → every window reports → main writes the report → exit. Steps are due at fixed times (`warmupAt + i × interval`); one that ends after the next was due is an overrun, and the next starts at once. A window passes only if every step succeeded with the right checksum and it completed every scheduled load step. The report records each phase's start so the monitor samples can be split by phase, and per window: time to first page, arm A's load and index time, p50/p95/max latency per step kind, and `performance.memory.usedJSHeapSize` samples (diagnostic).

## Limits

| Limit | Where |
|---|---|
| `--data-mib` 0–256, `--windows` 1–8, `--step-interval-ms` 100–10 000, phases ≤ 600 s | `config.rs`; an invalid value exits with code 2 and, with `--report`, writes `{"configError": …, "passed": false}` |
| page `limit` ≤ 100, valid sort/category, ≤ 20 ids per `catalog_get` | `commands.rs` (arm B), the same values as the workload |
| one report per window, once, ≤ 1 MiB each | `coordinator.rs` |
| `catalog_begin`, `catalog_collect`, `catalog_write_report`, `catalog_exit` only from `main` | `commands.rs` and `capabilities/main.json` |

## Running

```powershell
cd benchmarks\catalog
npm ci
npm test
# Smoke run (all three arms, short phases), builds every arm first:
.\scripts\Run-CatalogTriplets.ps1 -Phase Smoke -Arms A,B,C -Cells N2D0,N2D16 -Triplets 1 -IdleBeforeSeconds 5 -WarmupSeconds 5 -LoadSeconds 20 -IdleAfterSeconds 5 -PauseSeconds 10 -MonitorScript C:\path\to\Measure-ProcessTree.ps1 -OutputDirectory C:\results\catalog-smoke
.\scripts\Summarize-CatalogRuns.ps1 -ResultsDirectory C:\results\catalog-smoke
```

One run by hand: `catalog-bench.exe --data-mib 16 --windows 2 --report out.json` (`--seed`, `--step-interval-ms`, `--idle-before`, `--warmup`, `--duration`, `--idle-after`). Without `--report` the app starts interactively and does not exit by itself.

`Run-CatalogTriplets.ps1` builds each arm (`bin\arm-A.exe`, `bin\arm-B.exe`), writes `configuration.json` (git SHA and status, OS, CPU, RAM, power plan, WebView2, tool versions, SHA256 of every executable, of the monitor and of the scripts, this README and the protocol if present) and `schedule.csv` before the first run, pauses before every run (`-PauseSeconds`, default 30), starts each run as a fresh process with its own WebView2 user data folder (`profiles\<run>`, via `WEBVIEW2_USER_DATA_FOLDER`), samples the whole process tree every 1 s with the monitor, and keeps every report, monitor CSV, diagnostics CSV and log, failed runs included. A results directory is used once. The monitor must be #43 `167a67d` or later: the runner passes `-UnitCheckRequireChildName msedgewebview2.exe`, so the private-memory unit is verified on a stable WebView2 process, not on the host alone, and refuses an older monitor. With `-ExpectedSchedule <schedule.csv>` (a plan written and reviewed before the run, `plans\`) the runner stops before building if the schedule it would follow differs from that file in any row, field or order, and records the file's SHA-256 in `configuration.json`.

**Order** (`CatalogSchedule.ps1`, protocol revision 3 §6, Q8): the unit is a triplet, one run per arm, adjacent in time, same cell. Cells are interleaved block by block (one triplet per cell, cell order rotated each block). Arm orders are balanced **per cell**: each cell walks through the six permutations (the cyclic shifts of A,B,C, then those of C,B,A) from its own starting point, so with 6 triplets per cell every cell uses every permutation once and puts every arm in every position twice, and with any other count a cell's permutations differ by at most one use. The seed (`-ScheduleSeed`) is recorded. With two arms each cell alternates AB and BA. `schedule.csv` is read back and checked by `Test-CatalogSchedule` (every cell, triplet and arm once, adjacent triplets, contiguous order, same order as the runs) before the first run; an incomplete file stops the runner.

`Summarize-CatalogRuns.ps1` writes into a new `analysis-<time>` directory: `runs.csv` (one row per scheduled run with validity and reasons), `triplets.csv` (B − A, C − A, C − B per triplet, valid runs only), `processes.csv` (each process's mean Private Bytes during load), `summary.csv` and `summary.md`. It is **descriptive only** and marks every result "descriptive, no conclusion"; the confirmatory analysis (protocol §8b) is written and reviewed separately, before any confirmatory run.

- Co-primary measures (protocol revision 3): `LoadPrivateMBAvg`, the time average over the load phase of Σ Private Bytes over the host and every WebView2 process (`ExePrivateMBLoadAvg` and `WebViewPrivateMBLoadAvg` split it), and `RunCpuSeconds`, the CPU time of the whole tree from process start to the end of the idle-after phase: each process's last cumulative CPU time from the monitor diagnostics, summed (`StartupCpuSeconds` to the warm-up start; `LoadCpuSeconds` the load phase). Working Set appears only as `LoadWorkingSetMBUpperBound` (shared pages counted once per process) and is never used for a claim.
- Validity (protocol §7): report passed; exit codes 0; ≥ 80 % of expected load samples; median load interval within 20 % of 1 s and no gap over 5 s; a verified process tree (with a monitor that records process identities, #43: no load row with `UnverifiedProcessCount` > 0 and no WebView2 process of the app outside the tree in the diagnostics; a short-lived child that is in the tree is allowed, summed in the samples where it is seen and counted in `TransientProcesses`; with an older monitor CSV, the same process count in every load sample); both co-primary measures finite. Whole-run CPU is checked over the whole measured interval, post-load idle included: first sample no later than the idle-before start, no unreadable CPU in any monitor row, a cumulative CPU value in every diagnostics row, ≥ 80 % coverage and no gap over 5 s. A missing CPU value is never counted as zero: with monitor #43 `167a67d` or later the reason column (exited before its first read, access denied, PID already reused, left the tree, read error) and the PIDs are named in the invalid reason. With that monitor a process that exits during the run is read through a held handle and its final CPU time is in the diagnostics; with older monitors it contributes its last observed value (at most one interval of its CPU is missing). Either way it is counted in `CpuExitedProcesses`. A process that starts and exits between two samples is not seen at all. Invalid runs stay in the tables with their reasons.
- Retained size (protocol §4): host and WebView2 Private above the D0 cell with the same windows and arm, next to the generator size and the JS heap.

**Thresholds** (`CatalogThresholds.ps1`, protocol #33 §8b, Q7 proposal): the reference for a percentage threshold is the arm A (δ, η) or arm B (ε) median over the valid **pilot** runs of a cell, rounded to 0.1 MiB / 0.01 s, with at least 4 valid runs; otherwise that cell has no threshold for that outcome (no fallback to the floor). `New-CatalogThresholds` gives the rows of `thresholds.csv`, which is frozen before any confirmatory run, and refuses any phase but `Pilot`. In the sign test a difference exactly at the threshold counts against H1 and stays in `n`. Nothing here is run yet; the confirmatory analysis will read thresholds only through `Import-CatalogThresholds`, which hashes the file first and stops on any difference from the SHA-256 recorded at the confirmatory freeze (protocol §10a), or on a missing file, a malformed hash, a missing, unexpected or duplicated cell/kind/outcome row, or a non-numeric threshold.

`Test-CatalogScripts.ps1` checks the schedule's balance for the pilot shape, the threshold forms, references, sign counts at the threshold and the protocol's cut-offs, and the summarizer end to end on synthetic data, in Windows PowerShell 5.1 and PowerShell 7 (CI).

## What this does not show

WebView2 processes exist in every arm, one renderer per window; nothing here shares them. A smaller process tree in arm B or C means the renderers hold less data, not that any process is shared. CI runs on the Actions Windows Server image and is a build and correctness check only; measurements come from native runs on a named machine, reported with that machine's OS, at an exact SHA.
