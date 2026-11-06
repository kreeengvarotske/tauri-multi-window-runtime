# Memory and CPU benchmark: pilot protocol (draft for review)

Status: **revision 3, Q1–Q8 decided, not yet frozen; two freezes (pilot, then confirmatory) per §10a** (roadmap Phase 4, `docs/ROADMAP.md`
in #30). **Smoke gate open (11/12 valid on 2026-10-28), pilot blocked**
(#36 decision 6687069270; state in §10). Revision 3 (2026-10-26, after #33 comment 6429162749) makes **RAM
and CPU co-primary outcomes**: hypotheses, multiplicity family, success
criteria, the reading of discordant results, triplet counts, thresholds,
duration and the pilot matrix are recomputed (§1, §3, §8, §10 Q7–Q8). Revision 3 also
removes every "RAM primary" statement. Revision 2 (three arms, guardrails
in advance, native Windows 10 only) is otherwise kept. The values new in
revision 3 were decided by Group 1 on 2026-10-27 (§10 Q7, Q8). No run of this protocol
has happened. The
pilot runs only from this revision after its review, is descriptive only
and is never pooled with confirmatory data; the confirmatory run starts only
after the pilot report and the frozen confirmatory protocol are reviewed.

**The #25 pilot must not be run with its current parameters** (S1–S4 with a
4 MB transient buffer, 0.2 s RAM sampling, its N and cut-offs). RAM and CPU
are co-primary here too, but with a different workload, measures, family
and sample size; nothing of #25's statistical parameters is carried over.
Those scenarios retain no data, so they cannot show the memory the product is
meant to save; they remain correctness and fixed-overhead controls only.

## 1. Question

Two separate questions, never substituted for each other:

1. **Product benefit (primary claim, C vs A).** Does an application built on
   the framework, which keeps a data set once in the Rust process and gives
   windows bounded pages and aggregates, use less **total memory** and less
   **total CPU time of the whole application** than the same application
   where each window loads and keeps its own copy, once all runtime costs
   are included?
2. **Framework cost (estimate only, C vs B).** Compared with a good
   hand-written shared Rust service doing the same thing without the
   framework, how much memory and CPU does the framework add or save?

A result for question 1 says nothing about question 2, and the reverse.

**RAM and CPU are co-primary outcomes** with equal standing: each has its
own hypothesis, threshold and success criterion (§8b), they share one
multiplicity family, and a result on one never stands in for the other.
How a result that favours one and not the other is read is fixed in advance
(§8b, "Reading the two outcomes"). Latency, throughput (completed steps),
errors and time to first page are guardrails (§8d): they decide whether a
result is usable, not whether the framework "wins".

## 2. What this replaces

| PR | Role from now on |
|---|---|
| #9 → #18 → #24 | **Kept** as the measurement tool (process-tree monitor, `PrivatePageCount` unit check, fail-closed on unknown units, fractional intervals) |
| #20 → #23 | **Kept** as the harness: one source, one executable per arm (three for scenario M), same frontend and runner, fresh process per run, balanced order, schedule and hashes, invalid runs retained. S1–S4 stay as correctness and fixed-overhead controls |
| #25 | **Statistical plan replaced** by §8 (RAM and CPU co-primary, new family and sample size). The validity rules, the sign test, the order-statistic interval, "no rounding before statistics" and "never replace invalid pairs" (now triplets) are kept |
| #10 → #17, #11 → #16 | **Superseded** for evidence: the paired Lab vs vanilla comparison differs in UI and harness, so it cannot attribute memory to the runtime. Kept as history |

One reproducible scenario family (M, §4) is added to the #20 harness. Nothing
in #9–#25 is deleted.

## 3. Measures

All measures cover the **process tree** of one run: the host executable and
every WebView2 process it owns (browser, GPU, utility, one renderer per
window). Each run uses its own WebView2 user data folder, so no WebView2
process is shared with another application.

| Measure | Definition | Role |
|---|---|---|
| `LoadPrivateMBAvg` | time average over the load phase of Σ `PrivatePageCount` over the tree | **co-primary (RAM)** |
| `RunCpuSeconds` | CPU time (user + kernel) of the whole tree from process start to the end of the idle-after phase, from the run's Job Object (§7, draft #45); results without a job: for each process its last observed cumulative CPU time, summed | **co-primary (CPU)** |
| `SteadyPrivateMBAvg` | the same over the idle phase after the load | secondary |
| `LoadPrivateMBMaxSample` | largest sampled Σ Private (not a guaranteed peak) | secondary |
| `ExePrivateMB*`, `WebViewPrivateMB*` | Private split into host and WebView2 | explains the result |
| Working Set per process | resident pages including shared ones | diagnostic only; any sum is labelled "upper bound, shared pages counted per process" |
| `RustDataBytes` | size of the Rust-held data set reported by the generator (records, string capacities, index), checked against measured host Private (§4) | explains `Dr` |
| `JsHeapUsedMB` per window | `performance.memory.usedJSHeapSize` sampled by each window (Chromium extension, diagnostic) | explains `Dw` |
| `LoadCpuSeconds`, `StartupCpuSeconds` | the CPU of `RunCpuSeconds` split into the load phase and everything before the warm-up | secondary: where the CPU goes |
| p50/p95 step latency, completed steps, errors, time to first page | over the load phase (first page: from start) | guardrails |

Private Bytes counts each committed private page once, in the process that
owns it, so the sum over processes is not inflated by shared pages. Working
Set includes shared pages (DLLs, mapped sections) in every process that maps
them, which is why it is never summed for a claim.

**Why whole-run CPU.** The work the product removes is mostly at start:
in arm A every window receives the whole catalog as JSON, parses it and
builds its indexes; in B and C that happens once in Rust. A load-phase-only
CPU measure would leave that duplicated work out and favour A. The run has
fixed phase lengths, so `RunCpuSeconds` is the CPU cost of the same work in
every arm. With the job runner (§7, draft #45) the job's accounting holds
every process of the tree, including those that start and exit between two
monitor samples, so the value does not depend on the sampling cadence. The
spike in #44 (#36 comment 6692204106) found 9–10 such WebView2 children per
N4D64 run during load, never seen by the 1 s monitor. Results without a job
keep the monitor sum, with its limits (§7). CPU is never "shown" by adding
sleeps or idle time: the workload is fixed and every step is checked.

Sampling: **1 s** for every profile. The data set in scenario M is retained
for the whole load phase, so the RAM outcome is a plateau, not a short
peak; this avoids the 0.2 s cadence problem seen in the #25 review (median
0.31 s on one machine, 0.214 s on another).

## 4. Scenario M: a shared catalog

A deterministic catalog of records (id, name, category, price, timestamps,
a short text field), generated in Rust from a seed. Data set sizes `D` are
**preliminary pilot values** in bytes of the Rust representation:

| Level | `D` (Rust, nominal) | Records (approx.) | Role |
|---|---|---|---|
| D0 | 0 (no data set) | 0 | control for fixed costs; kept in every phase |
| D16 | 16 MiB | ~100 k | preliminary |
| D64 | 64 MiB | ~400 k | preliminary |

Windows `N`: 2 (main + secondary) and 4, also preliminary.

**Actual retained size is measured, not assumed.** The generator reports the
exact bytes of its Rust representation (`RustDataBytes`: sum of record sizes
and string capacities, plus index). The application reports, per run, the
host Private Bytes difference against the D0 cell (arms B, C) and each
renderer's JS heap (arm A). The pilot report compares nominal, generator and
measured sizes. If a level is off by more than 20 % from its nominal value,
or if the pilot shows that the sizes are not representative or that memory
differences are not distinguishable from run-to-run spread, the sizes (or
`N`) are changed before the confirmatory protocol is frozen, with the reason
written down.

Every window runs the **same logical workload** at a fixed cadence (one step
every 500 ms during the load phase): open page 1 of 100 rows sorted by name;
page forward 10 times; change the sort to price; apply a category filter and
read the count and price sum for each category; read 20 records by id. Every
response is checked against a checksum computed independently before the load.

### 4a. Arms

All three arms use the same frontend code, the same 100-row table, the same
workload and the same harness (#23). Only the data source differs.

| Arm | Where the data lives | What crosses IPC |
|---|---|---|
| **A. Per-window baseline** | each window calls `catalog_load`, receives the full catalog as JSON and keeps it in its JS heap; sorting, filtering, paging and aggregates run in JS | the whole catalog once per window, then nothing |
| **B. Hand-written shared Rust service** | the catalog is built once in Rust and held in a hand-written `OnceCell<Arc<Catalog>>`-style service with hand-written `catalog_page`, `catalog_aggregate`, `catalog_get` commands and the same limits (page size 100, `max_items`) | one page, aggregate or record per step |
| **C. Framework runtime** | the catalog is an `Operation` in `shared-runtime` (#35), pages and aggregates are `View`s with the same `max_items`, exposed through the same three hand-written commands | as B |

B and C expose identical command names and response shapes, so the frontend
of B and C is byte-identical; A differs only in the data-source module.
Arm B is written to be a fair, good manual implementation (one copy, no
coalescing machinery beyond what the catalog needs), not a weakened one.

## 5. Break-even model to fit

From `docs/ROADMAP.md` §3:

```
Saving(N) = N·(Dw + Ww − Tw) − (Δrt + Dr + Wr + I)
```

The model is fitted for C against A (and, as a check, B against A). The
same structure is fitted for `RunCpuSeconds` (per-window load, parse and
index work in A against one build in Rust plus per-step IPC in B and C).
The cells give the terms directly:

- D0 cells estimate the fixed difference `Δrt` (runtime layer, tokio pool,
  extra commands) and check that UI cost is equal between arms;
- D16 and D64 at N = 2 give the slope per MiB of data, i.e. `Dw − Tw` per window
  against `Dr` once;
- N = 4 at D64 checks that the saving grows with windows as the model says.

The pilot report states each fitted term with its spread, and the smallest
`N` and `D` where the saving is above the run-to-run spread, or that there is
none.

## 5a. Which memory the runtime avoids duplicating, and what it adds

| Memory | Arm A (per window) | Arms B and C (shared in Rust) | Counted where |
|---|---|---|---|
| The data set itself (decoded records, index) | once per window, as JS objects in each renderer (`Dw`, usually larger than the Rust form) | once per application in the Rust process (`Dr`) | WebView renderer Private vs host Private |
| Working memory of building it (parse, sort, index) | once per window, possibly at the same time | once, shared by coalescing (`Wr`) | renderer vs host, visible in the max sample |
| What a window keeps | the whole data set | one page or aggregate (`Tw`) | renderer Private |
| **Framework layer** (registry, scope keys, stats, slots, views) | none | present in C, absent in B; the C − B difference estimates it | host Private |
| **Added: runtime layer** (registry, coalescer tables, tokio pool, diagnostics) | none | fixed `Δrt`, measured in the D0 cell | host Private |
| **Added: IPC and serialization** | one full JSON copy of the data set per window at load time, held briefly in both the host and the renderer | one small JSON response per request, held briefly in both processes (`I`) | host and renderer Private, transient; visible in the max sample and in latency |
| **Added: copying for a view** | none | building a page copies up to `max_response_items` rows | host, transient |
| **Added: broker** (only if Phase 5 is ever opened) | none | a separate process with its own baseline, per-connection buffers (up to 1 MiB per frame) and a second serialization hop | broker Private; not part of this protocol |

WebView2 processes exist in both arms with the same count; the runtime does
not remove them. What changes is how much each renderer holds.

## 6. Run procedure

Kept from #20/#25: Release builds from one CI-tested SHA, byte-identical
frontend per arm group, `--locked`, SHA256 of all three executables and the
monitor recorded in `configuration.json`, fresh process per run, a pause
between runs (30 s), nothing else running.

**Matched triplets and order.** The unit is a triplet: one run of each arm,
adjacent in time, same machine and cell. The order of the three arms inside
a triplet follows a balanced schedule per cell: each cell cycles through
the six permutations of (A, B, C), starting at a different permutation in
each cell. Over its 6 pilot triplets a cell therefore uses every permutation
once and every arm in every position twice; over the 24 pilot triplets
every arm is in every position 8 times. For a confirmatory `n` that is not a
multiple of 6, the cycle continues and the imbalance is at most one triplet
per permutation. Cells are interleaved block by block
(one triplet of each cell in turn, cell order rotated) so that time of day
and machine drift do not line up with a cell. `schedule.csv` (cell, triplet,
position, arm, seed) is generated from a recorded seed and committed with
the results **before the first run**. Position is recorded per run and
analysed as a factor (§8).

Per run: start → wait for all windows → compute expected checksums →
idle 20 s → warm-up 30 s (the workload runs, not measured) → load 120 s →
idle after 30 s → report → exit. About 4.1 minutes per run with the pause
(200 s of phases, start-up, 30 s pause). The native smoke measures the real
time per run. If it is longer, the durations in §8a and §8b are recomputed
from it before the freeze.

Recorded per run: OS edition, version and build; CPU; RAM; power plan;
WebView2 version; rustc; app and monitor hashes; arm; position in triplet;
window count; nominal and generator data set size; all monitor rows; the app
report; exit codes. Failed and aborted runs are kept with their reason.

**Platform.** The pilot runs only on the current native machine: Windows 10
Home 22H2, build 19045 (Maxim's PC). Every result is stated for that
platform only. No Windows 11 statement is made without a separate run on
Windows 11.

## 7. Validity filters

A run is valid only if: the report exists and passed (every checksum right,
no error, no abort); exit codes are 0; the monitor covers ≥ 80 % of expected
load samples; the median load interval is within ±20 % of 1 s and none is
longer than 5 s; the process tree is verified (below); both co-primary
measures are finite.

Process tree (#24 comment 6466355032, monitor #43, summarizer #36
`5c05f6c`; CPU reasons and the child unit check from #43 `167a67d` and #36
`51d5b19`, pending review). The monitor identifies each process by PID and creation time
and keeps a child only if it was created no earlier than its parent, so a
reused PID cannot attach an unrelated process. A run is invalid if:
- a load row has a process whose creation time could not be read
  (`UnverifiedProcessCount` > 0), reason "process tree not verified";
- the monitor diagnostics show a WebView2 process of the app outside the
  tree during the run.

A change in the process count during load does not invalidate the run by
itself: a short-lived child that is verified as part of the tree is
included in the samples where it is seen and counted in
`TransientProcesses`, reported per run. A child that starts and exits
between two samples is never seen; this limit is stated with every result.
The expected steady count per `N` (8 for N2 and 10 for N4 in the
2026-10-27 smoke) is reported, not used as a filter. Results from a monitor
without process identities keep the earlier rule (the same count in every
load sample).

Whole-run CPU from a Job Object (draft for review, #36 decision
6692721269, implementation draft #45; spike #44). Each run is created
suspended, assigned to a new Job Object and only then resumed, so the app
and every process it starts are in the job from the first instruction. The
job allows no breakaway and ends its processes when the runner closes it.
The runner reads the job's accounting (user and kernel time of every
process of the job, running and exited, and the process counts) every
250 ms and keeps the job's messages (a new-process message with the PID for
every process added, exit messages, active-zero).

- **Interval.** From the assignment of the suspended app to the empty job
  (CPU 0 by construction) to the end of the idle-after phase (`endedAt` in
  the report). `RunCpuSeconds` is the job CPU at the last job row at or
  before `endedAt`. CPU after `endedAt` (report writing, shutdown) is never
  counted. `StartupCpuSeconds` (at the warm-up start) and `LoadCpuSeconds`
  (between the load boundaries) use the same rule and are secondary.
- **Sampling tolerance.** That row is at most 0.5 s before `endedAt`; no two
  job rows are more than 1 s apart up to the first row after `endedAt`; the
  first row is before the idle-before phase; the wall clock (row and phase
  times) stays within 0.1 s of the runner's monotonic stopwatch over the run.
- **Counters.** User time, kernel time, the total process count and the
  timestamps never decrease; no process is terminated by a job limit.
- **Membership, without PID-list races.** Every process the monitor saw in
  the tree (identity PID and creation time) has a new-process message from
  the job for its PID from 0.1 s before to 5 s after its creation time. A
  message for an earlier or later process with the same PID does not match.
  No PID list read at one moment is used. The messages count only if they
  are complete: as many new-process messages as the job's total count, as
  many exit messages as exited processes, and an active-zero message.
- **End of the run.** Every process of the job has exited at the last job
  row. If the app does not exit within the timeout, or processes of the app
  are still running 30 s after it exited, the runner terminates its own job
  (never a process by name or PID) and the run is invalid.

Any failed check makes the run's CPU, and so the run, invalid; the reason
is named. When the job checks pass, a CPU value the monitor could not read
(exited before its first read, access denied, …) no longer invalidates the
run; it is reported as a note, and the monitor's own sum stays as a
diagnostic (`MonitorRunCpuSeconds`). RAM keeps all of its own checks
unchanged (coverage, intervals, verified tree, no WebView2 process outside
the tree, private memory complete in every load row), so the RAM result is
valid independently of the CPU source. `JobProcessesNeverSeenByMonitor` is
reported per run.

Results without job files (smokes 1 to 3, #36 comments up to 6691413600)
keep their status and the monitor rule below.

Monitor rule (results without a job). Whole-run CPU covers more than the
load phase, so it has its own checks over the **whole measured interval**,
from the first monitor sample to the end of the idle-after phase
(post-load idle included):
- the first sample is no later than the start of the idle-before phase, so
  the processes that exist at start-up are observed;
- no monitor row in the interval has an unreadable CPU value
  (`CpuUnreadableCount = 0`), and every in-tree diagnostics row has a
  cumulative CPU value. A missing CPU value is never counted as zero. From
  monitor #43 `167a67d` each missing value has one reason: exited before its
  first read, access denied, PID already reused by another process, still
  running but no longer reached by the tree walk, or another read error.
  Any of them inside the measured interval leaves the run invalid, and the
  summarizer names the reason and the PIDs (#36 decision 6687069270);
- the samples cover ≥ 80 % of the interval at 1 s and no interval is longer
  than 5 s.

How processes are counted under the monitor rule:
- Each process contributes its last observed cumulative CPU time.
- From monitor #43 `167a67d` CPU time is read through a process handle
  opened once per identity and held while the process is in the tree, so a
  process that exits keeps its final CPU time readable, and the monitor
  writes it as the process's last diagnostics row. With earlier monitors a
  process that leaves the tree before the end loses at most one interval of
  CPU. Either way it is counted in `CpuExitedProcesses`, reported per run,
  and does not invalidate the run.
- A process that starts and exits between two samples is never observed
  and its CPU is missing without a reason (spike #44: 9–10 per N4D64 run).
  This is why the job is the source for new runs.

Unit check (#36 decision 6687069270). Scenario M runs the monitor with
`-UnitCheckRequireChildName msedgewebview2.exe`: the `PrivatePageCount`
unit is verified only once a WebView2 child process, not the host alone,
has stable private memory. A stable mismatch, or no stable WebView2 child
within the timeout, stops the monitor with no measurement, and the run is
invalid. The general mode of the monitor is unchanged.

These checks are implemented in the #36 summarizer (`ff09868`; #36 head
`fe31123`, hosted CI green on Linux and Windows), with tests
on synthetic data (an unreadable value after the load phase, a gap, an
early-exiting process).

A triplet is valid for a comparison only if
both runs in that comparison are valid (a triplet with an invalid B run still
gives a valid C vs A difference). Invalid runs and triplets stay in the
tables with the reason and are never replaced or re-run in place. The thresholds are checked against the pilot before they are
frozen.

## 8. Statistical plan

Outcomes per run: `LoadPrivateMBAvg` (RAM) and `RunCpuSeconds` (CPU), both
co-primary (§3). Differences are taken inside a triplet for each outcome:
`d_CA = C − A`, `d_CB = C − B`, `d_BA = B − A`, written `d^R` and `d^C` where
the outcome matters.

### 8a. Pilot (descriptive only)

**6 matched triplets** in each of four cells: N2·D0, N2·D16, N2·D64, N4·D64
(revision 2 had 5).

| | |
|---|---|
| Runs | 4 cells × 6 triplets × 3 arms = **72** |
| Time | 72 × (204–209 s per run + 30 s pause) ≈ **4.7–4.8 h**, plus ~30 min setup (build, hashes, schedule). This is an estimate from the 2026-10-28 native smoke (12 runs, scenario `5c05f6c`, monitor `1d967e0`, default phases), replacing the provisional 72 × ~4.1 min ≈ 4.9 h; it is checked again against the next smoke |
| Blocks | 6 blocks of 4 triplets (one per cell), 12 runs ≈ 47–48 min each; a block may be split across sessions only between triplets |

Why 6, not 5:
- **Order balance.** With 6 triplets per cell, each cell can use each of the
  six permutations of (A, B, C) exactly once. Then every arm takes every
  position exactly twice in every cell, so the CPU outcome, which is more
  exposed to warm-up and order effects than a memory plateau, is not
  confounded with position inside a cell. This needs a per-cell order in the
  scheduler. The #36 scheduler at `d0b2893` balanced orders over the whole
  run only, which gave 4 of the 6 permutations per cell. #36 `9d78ad6` now
  orders per cell: for every seed, 6 triplets per cell give each
  permutation once per cell and each arm in each position twice per cell
  (8 times overall). For the confirmatory sizes 11, 14, 20 and 28, a
  cell's permutations differ by at most one use. Tests in
  `Test-CatalogScripts.ps1` check all of this (passing on the hosted Windows
runner at #36 `fe31123`, which fixed a return-value bug in the check). `schedule.csv` is read back
  and checked for completeness before the first run. If Q8 is decided
  differently, the scheduler and tests follow that decision.
- **Spread estimate for two outcomes.** The confirmatory `n` (§8b) uses an
  upper confidence bound on each outcome's spread. With `k` triplets, the
  80 % upper bound of a standard deviation is `s·√((k−1)/χ²₀.₂,ₖ₋₁)`. That
  factor is 1.55 for 5 triplets and 1.46 for 6, so the bound is about 6 %
  tighter for the extra 0.8 h.

Reported, per cell and arm and for both co-primary outcomes: validity rate
and reasons; sampling quality (coverage, median and max interval, unreadable
CPU samples); spread of each arm and of `d_CA`, `d_CB`, `d_BA`; the
correlation of `d^R` and `d^C` inside a triplet; the position effect (each difference grouped by which arm ran
first); actual retained sizes (§4); host vs WebView2 split; JS heap per
window; the break-even terms; guardrails (§8d). Marked "pilot: descriptive,
no conclusion" and never pooled with confirmatory data.

### 8b. Confirmatory proposal (frozen only after the pilot review)

Values below are decided now (Q6, Q7) so that they are fixed before data exists;
the pilot may change only the items marked *(from pilot)*, with the reason
written down before the freeze. The old N = 16 pairs and the old sign-test
cut-offs are **not** carried over.

**Family P: primary claim, C vs A** (6 hypotheses: 2 outcomes × 3 cells,
one Holm procedure over all six, α = 0.05 one-sided):

- Cells N2·D16, N2·D64, N4·D64; outcomes RAM (`LoadPrivateMBAvg`) and CPU
  (`RunCpuSeconds`).
- For each cell `c` and outcome `o`, H0: median `d_CA` ≥ −δ_{c,o}; H1:
  median `d_CA` < −δ_{c,o} ("C uses at least δ less than A"). Sign test on
  `d_CA + δ_{c,o}`. δ_{c,o} is a **constant** from the frozen thresholds
  table (see "Threshold reference" below), known before the first
  confirmatory run. It is never computed from confirmatory data.
- Threshold forms (the reference `Ref` is defined below):
  - RAM δ_R = max(10 MiB, 5 % of Ref_A) (form unchanged from revision 2);
  - CPU δ_C = max(1 s, 10 % of Ref_A) *(Q7)*.
- One family over both outcomes, because a "saves RAM or CPU" statement must
  control the chance of any false saving. With Holm, the first test runs at
  α/6 = 0.0083.

**Non-inferiority of the other outcome** (6 tests: 2 outcomes × 3 cells; Holm
over the 3 cells within each outcome, α = 0.05 one-sided):

- For each cell and outcome, H0: median `d_CA` ≥ +η_{c,o}; H1: median
  `d_CA` < +η_{c,o} ("C is not worse than A by η or more"). Sign test on
  `d_CA − η_{c,o}`, with η_{c,o} a constant from the frozen table.
- Margin forms:
  - RAM η_R = max(10 MiB, 5 % of Ref_A) *(Q7)*;
  - CPU η_C = 1 s + 10 % of Ref_A. This is the revision 2 CPU guardrail (C
    above 1.10 × A + 1 s) turned into a test *(Q7)*.
- These tests only qualify a saving on the other outcome (below). They never
  support a saving claim on their own. They need no further multiplicity
  adjustment, because a combined statement requires both of its tests
  (intersection–union).

**Reading the two outcomes** (per cell, fixed in advance; any guardrail
breach (§8d) overrides the whole row with "no saving statement"):

| RAM: saving shown (P) | CPU: saving shown (P) | Not-worse shown for the other outcome | Statement for C vs A in that cell |
|---|---|---|---|
| yes | yes | (implied) | **saves RAM and CPU** |
| yes | no | CPU not worse by η_C | **saves RAM; CPU not worse** |
| yes | no | CPU not shown not worse | **trade-off: saves RAM, possible CPU cost**, with the CPU interval; no overall "better" statement |
| no | yes | RAM not worse by η_R | **saves CPU; RAM not worse** |
| no | yes | RAM not shown not worse | **trade-off: saves CPU, possible RAM cost**, with the RAM interval; no overall "better" statement |
| no | no | — | **no saving shown**, both intervals reported |

The headline product statement ("the framework reduces memory and CPU")
needs the first row in at least one cell. Which cells qualify is reported as
it is; nothing is pooled across cells.

**Family F: framework cost, C vs B** (estimation, not a claim; 2 outcomes ×
4 cells = 8 intervals, Holm-adjusted):

- All four cells including N2·D0.
- For each outcome, a distribution-free order-statistic interval for the
  median `d_CB` at the Holm-adjusted level. If the whole interval lies within
  ±ε, report "framework cost within ε of a hand-written service in this cell"
  for that outcome; otherwise report the interval as the framework's cost or
  saving.
- RAM ε_R = max(5 MiB, 2 % of Ref_B) (form unchanged); CPU
  ε_C = max(0.5 s, 5 % of Ref_B) *(Q7)*. ε_{c,o} is a constant from
  the frozen table, like δ and η.
- Family F never supports a product-benefit statement, and family P never
  supports a statement about the framework against hand-written code.

**Threshold reference** *(Q7, decided; values from the pilot)*. The form of each
threshold (floor and percentage) is fixed in this revision. The value the
percentage applies to is fixed separately, before any confirmatory data:

- `Ref_A(c, o)` and `Ref_B(c, o)` are the medians of arm A and arm B over
  the **valid pilot runs** of cell `c` for outcome `o` (`LoadPrivateMBAvg` in
  MiB, `RunCpuSeconds` in s), rounded to 0.1 MiB and 0.01 s.
- A reference needs at least 4 valid pilot runs of that arm in that cell
  (of 6). Otherwise the cell has no threshold for that outcome: it leaves
  family P (and family F for a missing `Ref_B`) for that outcome, the family
  size and cut-offs are recomputed, and this is written down before the
  freeze. The floor alone is never used as a fallback, because that would
  change the test after seeing the pilot.
- From the references, every δ_{c,o}, η_{c,o} and ε_{c,o} is computed once
  and written to `thresholds.csv` (cell, outcome, reference arm, reference
  value, valid pilot runs, form, threshold). That file is committed with the
  confirmatory protocol at the freeze SHA, before the first confirmatory
  run. The confirmatory analysis reads thresholds only from that file.
- After the freeze, the thresholds are never changed, whatever the
  confirmatory A or B medians turn out to be. The confirmatory medians are
  reported next to the references; a large difference is reported as a
  limitation, not corrected for.
- The pilot both gives the references and estimates `p` for the sample size
  (below). Both use pilot data only, so neither reads confirmatory data.

Exact formulas (MiB for RAM, s for CPU; `Ref` rounded as above, the
threshold itself not rounded):

| Threshold | Comparison | Outcome | Reference | Formula | Used in |
|---|---|---|---|---|---|
| δ_R | C − A | RAM | `Ref_A` | max(10, 0.05 × Ref_A) | family P, H0: median `d_CA` ≥ −δ_R |
| δ_C | C − A | CPU | `Ref_A` | max(1, 0.10 × Ref_A) | family P, H0: median `d_CA` ≥ −δ_C |
| η_R | C − A | RAM | `Ref_A` | max(10, 0.05 × Ref_A) | non-inferiority, H0: median `d_CA` ≥ +η_R |
| η_C | C − A | CPU | `Ref_A` | 1 + 0.10 × Ref_A | non-inferiority, H0: median `d_CA` ≥ +η_C |
| ε_R | C − B | RAM | `Ref_B` | max(5, 0.02 × Ref_B) | family F, interval within ±ε_R |
| ε_C | C − B | CPU | `Ref_B` | max(0.5, 0.05 × Ref_B) | family F, interval within ±ε_C |

The implementation is `CatalogThresholds.ps1` in #36 (`5be3846`), which
refuses any phase but `Pilot`; its synthetic tests cover each row at and
around the floor crossover.

The guardrails in §8d are relative to the confirmatory A and B medians of
the same run by design. They are not test margins, and they can only block
a statement, never support one.

**Descriptive only:** `d_BA` (the benefit of sharing as such) for both
outcomes, and N2·D0 for C vs A (the fixed cost against the baseline,
interval reported, ±10 MiB and ±1 s equivalence noted).

**Number of triplets per cell** *(from pilot)*. The same `n` is used in
every cell. It is the smallest `n` in 10–28 such that, for **both**
outcomes, the worst family-P test (the Holm first step, α = 0.05/6,
one-sided) has ≥ 80 % power. The power uses a conservative pilot estimate
of p = P(`d_CA` < −δ_{c,o}) per outcome, with δ_{c,o} from the
thresholds table computed from the same pilot: the lower of (a) the observed share and
(b) Φ((−δ − mean)/s₈₀), where s₈₀ is the 80 % upper bound of the
standard deviation (§8a). The cell and outcome with the smallest p decide
`n`.

Sign test, one-sided: `X` = the number of triplets with `d_CA + δ_{c,o}`
strictly below 0. A difference exactly at the threshold (`d_CA = −δ`)
counts against H1, and `n` stays the number of valid triplets, so ties make
the test more conservative, never less. Critical count `k` = the smallest
count with P(X ≥ k | n, ½) ≤ α. The power is P(X ≥ k | n, p). The cut-offs
depend only on `n` and α, not on the thresholds, so they do not change with
the reference:

| p (conservative) | Revision 2, α = 0.05/3 | Revision 3, α = 0.05/6 | `n` triplets (rev. 3) | reject when at least | power | exact size |
|---|---|---|---|---|---|---|
| 0.95 | 10 | **11** | 11 | 10 of 11 | 0.90 | 0.0059 |
| 0.90 | 13 | **14** | 14 | 12 of 14 | 0.84 | 0.0065 |
| 0.85 | 18 | **20** | 20 | 16 of 20 | 0.83 | 0.0059 |
| 0.80 | 24 | **28** | 28 | 21 of 28 | 0.82 | 0.0063 |

For the non-inferiority tests (α = 0.05/3 at Holm's first step), the
revision 2 column applies to p = P(`d_CA` < +η). It never needs more
triplets than the family-P row for the same p, because η ≥ −δ.

Calculation: `crit(n, α)` and `power(n, k, p)` are binomial tails, with
`n` increased from 10 until the power reaches 0.80. The script is in the
pilot report. The cut-offs, the sign counting at the threshold and the
threshold forms are checked by synthetic tests in #36
(`CatalogThresholds.ps1`).

Stopping rules:
- If the pilot gives p < 0.80 for an outcome in a cell, that cell and outcome
  are reported as "no practical saving expected at this size". They are
  either dropped from family P or replaced by a larger `D`/`N`, decided and
  written down before the freeze. Dropping changes the family size and is
  then recomputed, never relaxed afterwards.
- A cell with fewer than 10 valid triplets at the end is reported as
  "insufficient valid triplets" (p = 1 in family P, interval not reported in
  family F).

Duration at `n` triplets: 4 cells × `n` × 3 arms × 4.1 min:

| `n` | 11 | 14 | 20 | 28 |
|---|---|---|---|---|
| hours | 9.0 | 11.5 | 16.4 | 23.0 |

A confirmatory run above about 12 h is split into sessions only between
blocks, with the session breaks recorded.

**Order.** Position in the triplet is a recorded factor. Primary tests use
the within-triplet differences as above; as a pre-planned sensitivity check,
each family-P and family-F result is repeated within each "who ran first"
group, for both outcomes, and a difference in sign between groups is
reported as an order effect that qualifies the result.

### 8c. Memory and CPU reporting

The RAM claim uses only the mean Σ Private Bytes over the process tree
during the load phase. The CPU claim uses only `RunCpuSeconds` over the
process tree, with its split into start and load phases and per process. Working Set is shown per process as a diagnostic and never
summed into a claim. Each report includes: host and every WebView2 process
(browser, GPU, utility, each renderer) separately; actual `RustDataBytes`;
renderer JS heap per window; sampling quality per run; all failed runs with
reasons.

### 8d. Guardrails (defined in advance)

Per cell, medians over valid runs. A breach blocks any saving statement
(RAM or CPU) for C in that cell, whatever family P says, and is reported
next to the results. CPU is no longer a guardrail; it is a co-primary
outcome (§8b).

| Guardrail | Breach for C |
|---|---|
| Errors | any request error or checksum mismatch in a C run |
| Completed steps | fewer completed workload steps than scheduled in any C run |
| p95 step latency | above max(1.5 × A p95, A p95 + 20 ms) or above 100 ms absolute; and above 1.2 × B p95 + 5 ms (framework vs hand-written) |
| Time to first page | above 1.5 × A + 200 ms |

A has no IPC per step, so its step latency is lower by construction; the
100 ms absolute bound keeps the comparison about user-visible
responsiveness. The same guardrails are reported for B for reference.

## 9. Outputs kept

`configuration.json`, `schedule.csv`, `thresholds.csv` (confirmatory),
`protocol.md` (this file as run), every
app report, every monitor CSV, diagnostics CSV, logs, `runs.csv`, `triplets.csv`,
`summary.csv`, `summary.md`, the pilot report. Nothing is deleted, including
failed runs.

## 10. Decisions

Decided in the review on #33 (2026-10-26):

- **Q1 Baseline**: three arms A, B, C (§4a); C vs A is the product question,
  C vs B the framework cost.
- **Q2 Sizes**: D0 kept as fixed-cost control; D16/D64 and N = 2/4 are
  preliminary and confirmed or changed after the pilot (§4).
- **Q3 Machine**: pilot on the native Windows 10 Home 22H2 (19045) machine
  only; results limited to it.
- **Q4 Implementation**: a separate Draft PR on top of the #23 harness; no
  change to Runtime Lab or the public `runtime_*` contract.

Decided in the second review on #33 (2026-10-26):

- **Q5 Source of arm C.** A scenario Draft PR on #23 implements arms A and
  B first. Arm C is merged in from the #35 branch only after #35 is
  reviewed, CI is green at its exact head and the needed API is checked;
  the exact base, head and merge commit are recorded in that PR. No
  existing PR base is changed and nothing is merged into `main`.
- **Q6 Thresholds.** δ = max(10 MiB, 5 % of A) for C vs A,
  ε = max(5 MiB, 2 % of B) for C vs B, and the guardrails in §8d are fixed
  now, before any result. (Revision 3 keeps these RAM values. The CPU
  guardrail became the CPU non-inferiority margin η_C.) Q6 fixed the
  **form** of the RAM thresholds only. It did not fix which A or B value the
  percentage applies to; earlier wording ("the confirmatory A median") made
  the margin depend on the data it tests. The reference value is part of Q7
  (#33 comment 6443413608). After the pilot they may change only through a
  documented protocol change made before the first confirmatory run, never
  to fit an observed effect.

Decided after the review (#33 comment 6429162749, 2026-10-26):

- **RAM and CPU are co-primary**, replacing "RAM primary, CPU guardrail".
  Latency, throughput (completed steps), errors and time to first page stay
  guardrails.

Decided by Group 1 (#33 comment 6443417793, 2026-10-27):

- **Q8 Pilot matrix.** 6 matched triplets in each of the 4 cells (72 runs),
  each permutation of A, B, C once per cell. Descriptive pilot only; it does
  not set a confirmatory sample size by itself. The ≈ 4.9 h estimate is
  provisional: before any run it is replaced by the duration measured in the
  native smoke, and `schedule.csv` and `configuration.json` are kept from
  before the first run. The scheduler is in #36 (`9d78ad6`, fixed in
  `fe31123`). This decision does not open the pilot gate.
- **Q7 CPU and harm thresholds** (direction in 6443417793, accepted in
  6446125172):
  - RAM and CPU co-primary, CPU as `RunCpuSeconds` over the whole run;
  - separate C−A and C−B comparisons;
  - one Holm family for the six superiority hypotheses, Holm over 3 cells
    per outcome for non-inferiority, Holm over 8 intervals in family F;
  - the reading of discordant outcomes in §8b;
  - the thresholds in the §8b formula table: δ_R, δ_C, η_R, η_C for C−A and
    ε_R, ε_C for C−B;
  - reference only from the valid pilot runs of each cell, at least 4 of 6,
    rounded to 0.1 MiB and 0.01 s, no floor fallback;
  - `thresholds.csv` committed at the freeze SHA before any confirmatory
    data, and the analysis reads thresholds only from that file;
  - a difference exactly at the threshold counts against H1 and stays in
    `n`;
  - synthetic checks in #36 `CatalogThresholds.ps1` / `Test-CatalogScripts.ps1`.

No decision is open in this revision.

**Pilot gate.** Q7 and Q8 do not open the pilot by themselves. The pilot
runs only after:
- written approval to launch the scripts with PowerShell on the measurement
  machine (given for the smoke, 2026-10-27);
- a valid native smoke of scenario M with all three arms at the exact #36
  SHA that will run the pilot;
- the duration from that smoke replaces the estimate in §8a;
- the pilot freeze below, and a final pre-pilot review by Group 1 (§10b).

The pilot stays descriptive and is never used for confirmatory conclusions.

**Gate status (2026-11-06).** Not passed; the pilot is blocked.
- Smoke 1, scenario `0055c78`, monitor `6952886` (2026-10-27): 12/12 runs
  passed, 8/12 valid (startup unit check, PID reuse, a transient child).
  Report: #36 comment 6453085356.
- Smoke 2, scenario `5c05f6c`, monitor `1d967e0` (2026-10-28): 12/12 runs
  passed, **11/12 valid**. The invalid run, `N4D64-t01-p3-C`, lost the CPU
  time of a WebView2 child that exited between the monitor's snapshot and
  its read. Report: #36 comment 6481259913.
- Decision (#36 comment 6687069270): the smoke stays 11/12 and the gate
  stays open. The exit explains the gap, but independence from the arm and
  the load is not shown. Missing CPU is never counted as zero, and the old
  results are kept.
- Next: monitor #43 follow-up (separate exit, access-denied and identity
  reasons; final CPU through a held handle; unit check on a WebView2
  child), then ONE new full A/B/C smoke on the final scenario/monitor pair.
  It uses the same four cells and seeds, a new output directory, and a
  schedule written before the run (#36 `plans/smoke-abc-3`). The plan and
  the #43 evidence are reviewed before it runs. A C-only repeat or a
  recount of old data does not replace it.
- Duration: the §8a estimate now comes from smoke 2.

### 10a. Two freezes (#33 comment 6452488540)

The protocol is frozen twice. Each freeze is a commit whose SHA is written
in the PR and in the run's `configuration.json`.

1. **Pilot freeze**, before the first pilot run. It fixes:
   - this document, at a CI-tested SHA;
   - the #36 scenario SHA and the monitor SHA;
   - the pilot `configuration.json` (build hashes, cells, phase lengths,
     sampling interval);
   - the pilot `schedule.csv` (seed, per-cell permutations).

   Nothing in it changes during the pilot. A change means a new freeze and
   a pilot started again; the runs before it are kept and reported, never
   pooled.
2. **Confirmatory freeze**, after the descriptive pilot report and before
   any confirmatory run. It fixes:
   - `Ref_A`, `Ref_B` and `thresholds.csv` (§8b), computed once from the
     valid pilot runs;
   - which hypotheses stay in each family after the ≥ 4 valid-run rule, and
     the family sizes;
   - the triplet count `n` per cell and the sign-test cut-offs;
   - the confirmatory `schedule.csv` and `configuration.json`.

   The confirmatory run also needs separate written approval after this
   freeze.

The two freezes are separate commits, reviewed separately; neither implies
the other. The pilot freeze holds no thresholds: `thresholds.csv` exists
only from the confirmatory freeze, computed from the pilot's valid runs.

Checks tied to the freezes:
- `thresholds.csv` is built only from pilot runs marked valid by §7.
  `New-CatalogThresholds` refuses any phase but Pilot, and
  `Get-CatalogReference` skips runs that are not valid (#36 `5be3846`).
- After the confirmatory freeze, `thresholds.csv` is not changed. The
  confirmatory analysis reads it only from the freeze commit and records
  its SHA-256 next to the results. A hash mismatch stops the analysis.
  The check is prepared in #36 `51d5b19` (`Import-CatalogThresholds`,
  pending review). It hashes the file before parsing it. It stops on a
  mismatch, a missing file, a malformed frozen hash, a missing, unexpected
  or duplicated cell/kind/outcome row, or a non-numeric threshold, and it
  returns the verified hash for the results. Synthetic tests in
  `Test-CatalogScripts.ps1` cover each case. The confirmatory analysis
  script that calls it is written and reviewed before the confirmatory
  freeze.
- Pilot and confirmatory data are never pooled. They are kept in separate
  results directories with their own `phase` in `configuration.json`, and
  each analysis reads one phase only.

After each freeze, §10 status, the PR description and the ROADMAP evidence
are updated with the exact SHAs and the CI and native results they rest on.

### 10b. Pre-pilot review package (draft, 72 runs)

What Group 1 receives before deciding on the pilot (§10, pilot gate). It is
assembled only after a passed smoke; nothing here opens the pilot.

1. **SHAs.** This protocol at the pilot-freeze commit; the #36 scenario
   SHA; the #43 monitor SHA. All the same as in the passed smoke, or the
   difference stated and re-smoked.
2. **CI.** Hosted runs at each exact SHA: Rust, frontend and Windows release
   for #36; PowerShell 5.1 and 7 for #43. Links and conclusions.
3. **Native evidence (Windows 10 22H2, 19045).** The #43 targeted tests at
   the monitor SHA. The passed smoke: `configuration.json`, `schedule.csv`,
   `runs.csv`, every invalid reason, retained sizes, process counts per
   `N`, CPU reason columns, run durations. Earlier smokes listed with their
   results, unchanged.
4. **Pilot plan.**
   - 4 cells × 6 triplets × 3 arms = 72 runs;
   - `schedule.csv` written and checked before the run (each permutation
     once per cell, each arm in each position twice per cell);
   - the exact runner command with `-ExpectedSchedule`, the phases and
     seeds, and a new output directory;
   - the time from §8a (≈ 4.7–4.8 h + setup) and how blocks may be split.
5. **Measures and validity.**
   - RAM (`LoadPrivateMBAvg`) and CPU (`RunCpuSeconds`) co-primary, with
     the same weight (§3);
   - the guardrails (§8d);
   - the §7 filters as implemented at the scenario SHA. That includes
     missing CPU never counted as zero and the unit check on a WebView2
     child.
6. **What the pilot report will contain** (§8a), marked descriptive with no
   conclusion, and the statement that pilot and confirmatory data are
   never pooled.
7. **Freeze plan.**
   - the pilot freeze contents (§10a.1);
   - what can change only at the confirmatory freeze (§10a.2,
     *(from pilot)* items);
   - the `thresholds.csv` SHA-256 check (§10a).
8. **Risks and limits.**
   - one machine;
   - processes that start and exit between two samples are not seen;
   - WebView2 version drift;
   - background load;
   - what is not verified.
9. **The ask.** Approve the pilot freeze SHA and the start of the 72 runs.
   The confirmatory stage needs a separate decision after the pilot report.

## 11. Acceptance criteria for this phase

- Revision 3 reviewed; Q1–Q6 decided (done 2026-10-26); Q8 decided
  (2026-10-27); Q7 decided, including the threshold reference (2026-10-27).
- Scenario M implemented with unit tests for the generator, checksums,
  paging, aggregates and the size report; CI green; a native smoke run.
- Pilot run only from this revision, reported per §8a, with raw data and the
  pre-run `schedule.csv` kept.
- Pilot protocol frozen (§10a) at a CI-tested SHA before the first pilot
  run.
- Confirmatory protocol frozen (§10a) at a CI-tested SHA before the first
  confirmatory triplet, with separate written approval.
