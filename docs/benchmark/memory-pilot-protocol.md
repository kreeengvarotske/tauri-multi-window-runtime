# Memory and CPU benchmark: pilot protocol (draft for review)

Status: **revision 3, draft for review** (roadmap Phase 4, `docs/ROADMAP.md`
in #30). Revision 3 (2026-10-26, after #33 comment 6429162749) makes **RAM
and CPU co-primary outcomes**: hypotheses, multiplicity family, success
criteria, the reading of discordant results, triplet counts, thresholds,
duration and the pilot matrix are recomputed (§1, §3, §8, §10 Q7–Q8). Revision 3 also
removes every "RAM primary" statement. Revision 2 (three arms, guardrails
in advance, native Windows 10 only) is otherwise kept. The values new in
revision 3 (§10 Q7) are proposals until reviewed. No run of this protocol
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
| `RunCpuSeconds` | Σ CPU time (user + kernel) over the tree from process start to the end of the idle-after phase: for each process its last observed cumulative CPU time, summed | **co-primary (CPU)** |
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
every arm. Cumulative CPU time does not depend on the sampling cadence; a
process that exits before the end contributes its last observed value, so
up to 1 s of its CPU can be missed (reported as `CpuExitedProcesses`). CPU
is never "shown" by adding sleeps or idle time: the workload is fixed and
every step is checked.

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
idle after 30 s → report → exit. About 4.1 minutes per run with the pause.

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
longer than 5 s; the WebView2 process count during load equals the expected
count for `N`; both co-primary measures are finite, and no load-phase CPU sample is unreadable. A triplet is valid for a comparison only if
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
| Time | 72 × ~4.1 min ≈ **4.9 h**, plus ~30 min setup (build, hashes, schedule, smoke run) |
| Blocks | 6 blocks of 4 triplets (one per cell), ~50 min each; a block may be split across sessions only between triplets |

Why 6, not 5:
- **Order balance.** With 6 triplets per cell, each cell can use each of the
  six permutations of (A, B, C) exactly once. Then every arm takes every
  position exactly twice in every cell, so the CPU outcome, which is more
  exposed to warm-up and order effects than a memory plateau, is not
  confounded with position inside a cell. This needs a per-cell order in the
  scheduler: the #36 scheduler at `d0b2893` balances orders over the whole
  run, which gives only 4 of the 6 permutations per cell. That change goes
  into #36 after this revision is reviewed.
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

Values below are proposed now so that they are fixed before data exists;
the pilot may change only the items marked *(from pilot)*, with the reason
written down before the freeze. The old N = 16 pairs and the old sign-test
cut-offs are **not** carried over.

**Family P: primary claim, C vs A** (6 hypotheses: 2 outcomes × 3 cells,
one Holm procedure over all six, α = 0.05 one-sided):

- Cells N2·D16, N2·D64, N4·D64; outcomes RAM (`LoadPrivateMBAvg`) and CPU
  (`RunCpuSeconds`).
- For each cell and outcome, H0: median `d_CA` ≥ −δ; H1: median
  `d_CA` < −δ ("C uses at least δ less than A"). Sign test on `d_CA + δ`.
- Practical thresholds, fixed now (the percentage base is the confirmatory
  A median in that cell):
  - RAM δ_R = max(10 MiB, 5 % of A) (unchanged from revision 2);
  - CPU δ_C = max(1 s, 10 % of A) *(proposed, Q7)*.
- One family over both outcomes, because a "saves RAM or CPU" statement must
  control the chance of any false saving. With Holm, the first test runs at
  α/6 = 0.0083.

**Non-inferiority of the other outcome** (6 tests: 2 outcomes × 3 cells; Holm
over the 3 cells within each outcome, α = 0.05 one-sided):

- For each cell and outcome, H0: median `d_CA` ≥ +η; H1: median
  `d_CA` < +η ("C is not worse than A by η or more"). Sign test on `d_CA − η`.
- Margins, fixed now:
  - RAM η_R = max(10 MiB, 5 % of A) *(proposed, Q7)*;
  - CPU η_C = 1 s + 10 % of A. This is the revision 2 CPU guardrail (C above
    1.10 × A + 1 s) turned into a test *(proposed, Q7)*.
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
- RAM ε_R = max(5 MiB, 2 % of B) (unchanged); CPU ε_C = max(0.5 s, 5 % of B)
  *(proposed, Q7)*.
- Family F never supports a product-benefit statement, and family P never
  supports a statement about the framework against hand-written code.

**Descriptive only:** `d_BA` (the benefit of sharing as such) for both
outcomes, and N2·D0 for C vs A (the fixed cost against the baseline,
interval reported, ±10 MiB and ±1 s equivalence noted).

**Number of triplets per cell** *(from pilot)*. The same `n` is used in
every cell. It is the smallest `n` in 10–28 such that, for **both**
outcomes, the worst family-P test (the Holm first step, α = 0.05/6,
one-sided) has ≥ 80 % power. The power uses a conservative pilot estimate
of p = P(`d_CA` < −δ) per outcome: the lower of (a) the observed share and
(b) Φ((−δ − mean)/s₈₀), where s₈₀ is the 80 % upper bound of the
standard deviation (§8a). The cell and outcome with the smallest p decide
`n`.

Sign test, one-sided, critical count `k` = the smallest count with
P(X ≥ k | n, ½) ≤ α. The power is P(X ≥ k | n, p):

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
pilot report.

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

`configuration.json`, `schedule.csv`, `protocol.md` (this file as run), every
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
  guardrail became the CPU non-inferiority margin η_C.) After the pilot they may change only through a
  documented protocol change made before the first confirmatory run, never
  to fit an observed effect.

Decided after the review (#33 comment 6429162749, 2026-10-26):

- **RAM and CPU are co-primary**, replacing "RAM primary, CPU guardrail".
  Latency, throughput (completed steps), errors and time to first page stay
  guardrails.

Open in revision 3 (proposals, for review before the pilot):

- **Q7 CPU and harm thresholds:**
  - CPU outcome `RunCpuSeconds`, whole run, not load phase only (§3);
  - δ_C = max(1 s, 10 % of A);
  - η_R = max(10 MiB, 5 % of A);
  - η_C = 1 s + 10 % of A;
  - ε_C = max(0.5 s, 5 % of B);
  - one Holm family of six over both outcomes;
  - the reading table in §8b.
- **Q8 Pilot matrix:** 6 triplets per cell (72 runs, ≈ 4.9 h), with each
  permutation once per cell. This needs the per-cell scheduler change in #36.

The pilot stays descriptive, is never used for confirmatory conclusions,
and runs only after this revision's review is complete and the scenario
build has been checked.

## 11. Acceptance criteria for this phase

- Revision 3 reviewed; Q1–Q6 decided (done 2026-10-26); Q7–Q8 decided.
- Scenario M implemented with unit tests for the generator, checksums,
  paging, aggregates and the size report; CI green; a native smoke run.
- Pilot run only from this revision, reported per §8a, with raw data and the
  pre-run `schedule.csv` kept.
- Confirmatory protocol frozen at a CI-tested SHA before the first
  confirmatory triplet.
