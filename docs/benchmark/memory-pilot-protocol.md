# Memory benchmark: pilot protocol (draft for review)

Status: **revision 2, draft for review** (roadmap Phase 4, `docs/ROADMAP.md`
in #30). Revised after the review on #33 (2026-10-26): three arms, pilot of
5 matched triplets per cell, confirmatory comparisons and multiplicity
redone for three arms, guardrails defined in advance, platform limited to
the native Windows 10 machine. No run of this protocol has happened. The
pilot runs only from this revision after its review, is descriptive only
and is never pooled with confirmatory data; the confirmatory run starts only
after the pilot report and the frozen confirmatory protocol are reviewed.

**The #25 pilot must not be run with its current parameters** (S1–S4 with a
4 MB transient buffer, CPU and RAM as equal primaries, 0.2 s RAM sampling).
Those scenarios retain no data, so they cannot show the memory the product is
meant to save; they remain correctness and fixed-overhead controls only.

## 1. Question

Two separate questions, never substituted for each other:

1. **Product benefit (primary claim, C vs A).** Does an application built on
   the framework, which keeps a data set once in the Rust process and gives
   windows bounded pages and aggregates, use less **total memory of the whole
   application** than the same application where each window loads and keeps
   its own copy, once all runtime costs are included?
2. **Framework cost (estimate only, C vs B).** Compared with a good
   hand-written shared Rust service doing the same thing without the
   framework, how much memory does the framework add or save?

A result for question 1 says nothing about question 2, and the reverse.

RAM is the primary outcome. CPU time, latency, throughput and errors are
guardrails: they decide whether a memory result is usable, not whether the
framework "wins".

## 2. What this replaces

| PR | Role from now on |
|---|---|
| #9 → #18 → #24 | **Kept** as the measurement tool (process-tree monitor, `PrivatePageCount` unit check, fail-closed on unknown units, fractional intervals) |
| #20 → #23 | **Kept** as the harness: one source, one executable per arm (three for scenario M), same frontend and runner, fresh process per run, balanced order, schedule and hashes, invalid runs retained. S1–S4 stay as correctness and fixed-overhead controls |
| #25 | **Statistical plan replaced** by §8 (RAM primary). The validity rules, the sign test, the order-statistic interval, "no rounding before statistics" and "never replace invalid pairs" (now triplets) are kept |
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
| `LoadPrivateMBAvg` | time average over the load phase of Σ `PrivatePageCount` over the tree | **primary** |
| `SteadyPrivateMBAvg` | the same over the idle phase after the load | secondary |
| `LoadPrivateMBMaxSample` | largest sampled Σ Private (not a guaranteed peak) | secondary |
| `ExePrivateMB*`, `WebViewPrivateMB*` | Private split into host and WebView2 | explains the result |
| Working Set per process | resident pages including shared ones | diagnostic only; any sum is labelled "upper bound, shared pages counted per process" |
| `RustDataBytes` | size of the Rust-held data set reported by the generator (records, string capacities, index), checked against measured host Private (§4) | explains `Dr` |
| `JsHeapUsedMB` per window | `performance.memory.usedJSHeapSize` sampled by each window (Chromium extension, diagnostic) | explains `Dw` |
| `LoadCpuSeconds`, p50/p95 request latency, completed requests, errors | over the load phase | guardrails |

Private Bytes counts each committed private page once, in the process that
owns it, so the sum over processes is not inflated by shared pages. Working
Set includes shared pages (DLLs, mapped sections) in every process that maps
them, which is why it is never summed for a claim.

Sampling: **1 s** for every profile. The data set in scenario M is retained
for the whole load phase, so the primary outcome is a plateau, not a short
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
cells give the terms directly:

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
a triplet follows a balanced schedule: the six permutations of (A, B, C) are
cycled so that, over the 20 pilot triplets, every arm appears in every
position 6–7 times and every permutation 3–4 times; the cycle starts at a
different permutation in each cell. Cells are interleaved block by block
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
count for `N`; the primary measure is finite. A triplet is valid for a comparison only if
both runs in that comparison are valid (a triplet with an invalid B run still
gives a valid C vs A difference). Invalid runs and triplets stay in the
tables with the reason and are never replaced or re-run in place. The thresholds are checked against the pilot before they are
frozen.

## 8. Statistical plan

Outcome per run: `LoadPrivateMBAvg` (time average over the load phase of
Σ Private Bytes over the host and all WebView2 processes). Differences are
taken inside a triplet: `d_CA = C − A`, `d_CB = C − B`, `d_BA = B − A`.

### 8a. Pilot (descriptive only)

5 matched triplets in each of four cells: N2·D0, N2·D16, N2·D64, N4·D64.

| | |
|---|---|
| Runs | 4 cells × 5 triplets × 3 arms = **60** |
| Time | 60 × ~4.1 min ≈ **4.1 h**, plus ~30 min setup (build, hashes, schedule, smoke run) |
| Blocks | 5 blocks of 4 triplets (one per cell), ~50 min each; a block may be split across sessions only between triplets |

Reported, per cell and arm: validity rate and reasons; sampling quality
(coverage, median and max interval); spread of each arm and of `d_CA`,
`d_CB`, `d_BA`; the position effect (each difference grouped by which arm ran
first); actual retained sizes (§4); host vs WebView2 split; JS heap per
window; the break-even terms; guardrails (§8d). Marked "pilot: descriptive,
no conclusion" and never pooled with confirmatory data.

### 8b. Confirmatory proposal (frozen only after the pilot review)

Values below are proposed now so that they are fixed before data exists;
the pilot may change only the items marked *(from pilot)*, with the reason
written down before the freeze. The old N = 16 pairs and the old sign-test
cut-offs are **not** carried over.

**Family P: primary claim, C vs A** (3 hypotheses, Holm, α = 0.05 one-sided):

- Cells N2·D16, N2·D64, N4·D64.
- H0: median `d_CA` ≥ −δ; H1: median `d_CA` < −δ ("C uses at least δ less
  than A"). Sign test on `d_CA + δ`.
- Practical threshold δ = max(10 MiB, 5 % of the A median in that cell). A
  saving smaller than that is not a user-visible benefit even if it is
  statistically clear. *(δ itself is fixed now; only its 5 % base comes from
  the confirmatory A median.)*

**Family F: framework cost, C vs B** (estimation, not a claim; 4 cells,
Holm-adjusted intervals):

- All four cells including N2·D0.
- Distribution-free order-statistic interval for median `d_CB` at the
  Holm-adjusted level. If the whole interval lies within ±ε, report
  "framework cost within ε of a hand-written service in this cell";
  otherwise report the interval as the framework's cost or saving.
- ε = max(5 MiB, 2 % of the B median).
- Family F never supports a product-benefit statement, and family P never
  supports a statement about the framework against hand-written code.

**Descriptive only:** `d_BA` (the benefit of sharing as such), N2·D0 for
C vs A (fixed cost against the baseline, interval reported, ±10 MiB
equivalence noted).

**Number of triplets per cell** *(from pilot)*: the smallest `n` in 10–24
that gives ≥ 80 % power for the worst family-P test at the Holm worst case
(α = 0.05/3, one-sided), using the pilot's lower estimate of
p = P(`d_CA` < −δ). For reference:

| p (pilot, conservative) | `n` triplets | reject when at least |
|---|---|---|
| 0.95 | 10 | 9 of 10 |
| 0.90 | 13 | 11 of 13 |
| 0.85 | 18 | 14 of 18 |
| 0.80 | 24 | 18 of 24 |

If the pilot gives p < 0.80, the cell is reported as "no practical saving
expected at this size" and either dropped from family P or replaced by a
larger `D`/`N`, decided before the freeze. A cell with fewer than 10 valid
triplets at the end is "insufficient valid triplets" (p = 1 in family P,
interval not reported in family F). Duration at `n` triplets:
4 cells × `n` × 3 × 4.1 min (e.g. `n` = 13: ≈ 10.7 h).

**Order.** Position in the triplet is a recorded factor. Primary tests use
the within-triplet differences as above; as a pre-planned sensitivity check,
each family-P and family-F result is repeated within each "who ran first"
group, and a difference in sign between groups is reported as an order
effect that qualifies the result.

### 8c. Memory reporting

The claim uses only the mean Σ Private Bytes over the process tree during
the load phase. Working Set is shown per process as a diagnostic and never
summed into a claim. Each report includes: host and every WebView2 process
(browser, GPU, utility, each renderer) separately; actual `RustDataBytes`;
renderer JS heap per window; sampling quality per run; all failed runs with
reasons.

### 8d. Guardrails (defined in advance)

Per cell, medians over valid runs. A breach blocks any "saves memory"
statement for C in that cell, whatever family P says, and is reported next
to the memory result.

| Guardrail | Breach for C |
|---|---|
| Errors | any request error or checksum mismatch in a C run |
| Completed steps | fewer completed workload steps than scheduled in any C run |
| p95 step latency | above max(1.5 × A p95, A p95 + 20 ms) or above 100 ms absolute; and above 1.2 × B p95 + 5 ms (framework vs hand-written) |
| Load-phase CPU | `LoadCpuSeconds` above 1.10 × A + 1 s, or above 1.10 × B + 1 s |
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
  now, before any result. After the pilot they may change only through a
  documented protocol change made before the first confirmatory run, never
  to fit an observed effect.

The pilot stays descriptive, is never used for confirmatory conclusions,
and runs only after this revision's review is complete and the scenario
build has been checked.

## 11. Acceptance criteria for this phase

- This revision reviewed; Q1–Q6 decided (done 2026-10-26).
- Scenario M implemented with unit tests for the generator, checksums,
  paging, aggregates and the size report; CI green; a native smoke run.
- Pilot run only from this revision, reported per §8a, with raw data and the
  pre-run `schedule.csv` kept.
- Confirmatory protocol frozen at a CI-tested SHA before the first
  confirmatory triplet.
