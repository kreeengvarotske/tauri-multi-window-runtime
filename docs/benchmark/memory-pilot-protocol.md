# Memory benchmark: pilot protocol (draft for review)

Status: **draft for review** (roadmap Phase 4, `docs/ROADMAP.md` in #30). No
run of this protocol has happened. The pilot starts only after this document
is reviewed; the confirmatory run starts only after the pilot report and the
frozen confirmatory protocol are reviewed.

## 1. Question

Does keeping a shared data set once in the Rust process, with windows reading
pages and aggregates, lower the **total memory of the whole application**
compared with a plain Tauri application where each window loads and keeps its
own copy, once the runtime's own costs are included?

RAM is the primary outcome. CPU time, latency, throughput and errors are
guardrails: they decide whether a memory result is usable, not whether the
framework "wins".

## 2. What this replaces

| PR | Role from now on |
|---|---|
| #9 → #18 → #24 | **Kept** as the measurement tool (process-tree monitor, `PrivatePageCount` unit check, fail-closed on unknown units, fractional intervals) |
| #20 → #23 | **Kept** as the harness: one source, two executables, same frontend and runner, fresh process per run, alternating order, schedule and hashes, invalid runs retained. S1–S4 stay as correctness and fixed-overhead controls |
| #25 | **Statistical plan replaced** by §8 (RAM primary). The validity rules, the sign test, the order-statistic interval, "no rounding before statistics" and "never replace invalid pairs" are kept |
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
| `RustDataBytes` | declared size of the Rust-held data set (sum of record sizes, from the app) | explains `Dr` |
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
fixed in **bytes of the Rust representation** and reported by the app:

| Level | `D` (Rust) | Records (approx.) |
|---|---|---|
| D0 | 0 (control: no data set) | 0 |
| D16 | 16 MiB | ~100 k |
| D64 | 64 MiB | ~400 k |

Windows `N`: 2 (main + secondary) and 4.

Every window runs the **same logical workload** at a fixed cadence (one step
every 500 ms during the load phase): open page 1 of 100 rows sorted by name;
page forward 10 times; change the sort to price; apply a category filter and
read the count and price sum for each category; read 20 records by id. Every
response is checked against a checksum computed independently before the load.

| Arm | Where the data lives | What crosses IPC |
|---|---|---|
| `plain` | each window calls `catalog_load`, receives the full catalog as JSON and keeps it in its JS heap; sorting, filtering, paging and aggregates are done in JS | the whole catalog once per window, then nothing |
| `runtime` | the catalog is built once in Rust (`CachedService`, `Forever`) and held as `Arc`; windows call `catalog_page`, `catalog_aggregate`, `catalog_get` | one page, aggregate or record per step |

Both arms render the same 100-row table from the same frontend code; only the
data source differs. The plain arm is the common way to write this in a
Tauri app, but it is a choice: see decision Q1 in §10.

## 5. Break-even model to fit

From `docs/ROADMAP.md` §3:

```
Saving(N) = N·(Dw + Ww − Tw) − (Δrt + Dr + Wr + I)
```

The cells give the terms directly:

- D0 cells estimate the fixed difference `Δrt` (runtime layer, tokio pool,
  extra commands) and check that UI cost is equal between arms;
- D16 and D64 at N = 2 give the slope per MiB of data, i.e. `Dw − Tw` per window
  against `Dr` once;
- N = 4 at D64 checks that the saving grows with windows as the model says.

The pilot report states each fitted term with its spread, and the smallest
`N` and `D` where the saving is above the run-to-run spread, or that there is
none.

## 6. Run procedure

Kept from #20/#25: Release builds from one CI-tested SHA, byte-identical
frontend, `--locked`, SHA256 of both executables and the monitor recorded in
`configuration.json`, `schedule.csv` written before the first run, fresh
process per run, alternating order within a pair (odd pairs plain first, even
pairs runtime first), a pause between runs (30 s), nothing else running.

Per run: start → wait for all windows → compute expected checksums →
idle 20 s → warm-up 30 s (the workload runs, not measured) → load 120 s →
idle after 30 s → report → exit. About 4 minutes per run with the pause.

Recorded per run: OS edition, version and build; CPU; RAM; power plan;
WebView2 version; rustc; app and monitor hashes; window count; data set size;
all monitor rows; the app report; exit codes. Failed and aborted runs are
kept with their reason.

## 7. Validity filters

A run is valid only if: the report exists and passed (every checksum right,
no error, no abort); exit codes are 0; the monitor covers ≥ 80 % of expected
load samples; the median load interval is within ±20 % of 1 s and none is
longer than 5 s; the WebView2 process count during load equals the expected
count for `N`; the primary measure is finite. A pair is valid only if both
runs are. Invalid runs and pairs stay in the tables with the reason and are
never replaced. The thresholds are checked against the pilot before they are
frozen.

## 8. Statistical plan

Unit of analysis: one pair (plain run, runtime run) on the same machine,
adjacent in time. Outcome: `d = runtime − plain` of `LoadPrivateMBAvg`.

**Pilot (descriptive only).** 5 pairs in each of four cells: N2·D0, N2·D16,
N2·D64, N4·D64. 40 runs, about 2.7 h. Reported: validity rate, interval
quality, spread of `d` and of each arm, the break-even terms, guardrails.
Marked "pilot: no conclusion" and never pooled with confirmatory data.

**Confirmatory (draft, frozen after the pilot review).**

- Primary family, 3 hypotheses: in N2·D16, N2·D64 and N4·D64, "the median of
  `d` is 0". Two-sided sign test, Holm at α = 0.05 over the 3.
- Planned pairs: 16 per cell. Worst-case Holm threshold is 0.05/3 ≈ 0.0167;
  14 or more of 16 in one direction gives p ≤ 0.0042. Fewer than 10 valid pairs
  in a cell: "insufficient valid pairs", p = 1 in the family.
- Practical threshold: a rejected test counts as "runtime lower/higher" only
  if |median `d`| ≥ max(5 MiB, 2 % of the plain median).
- N2·D0 (fixed cost) is an equivalence check, not in the family: the 95 %
  order-statistic interval of `d` must lie within ±10 MiB to state "fixed
  overhead below 10 MiB". Otherwise the overhead is reported with its interval.
- Guardrails, per cell, descriptive with intervals: `LoadCpuSeconds`, p95
  latency, completed requests. A guardrail breach (runtime p95 > 1.5 × plain
  p95 + 20 ms, any error, or fewer completed steps) is reported next to the
  memory result and blocks a "saves memory" headline for that cell.
- Missing data: no imputation; invalid pairs stay in the tables.
- Duration: 4 cells × 16 pairs × 2 runs = 128 runs, about 8.5 h, run in
  blocks of whole pairs.
- The number of pairs and the thresholds may change only between the pilot
  and the freeze, with the reason written down.

## 9. Outputs kept

`configuration.json`, `schedule.csv`, `protocol.md` (this file as run), every
app report, every monitor CSV, diagnostics CSV, logs, `runs.csv`, `pairs.csv`,
`summary.csv`, `summary.md`, the pilot report. Nothing is deleted, including
failed runs.

## 10. Decisions needed before the pilot

- **Q1 Plain baseline.** Proposed: each window loads and keeps the full
  catalog in JS (common Tauri pattern). Alternative: a plain app that already
  keeps one Rust copy and serves pages, which by construction has no
  duplication and would only measure runtime overhead (that is the D0/S1–S4
  role). The result depends on this choice, so it must be agreed.
- **Q2 Data set sizes** 16 and 64 MiB, and windows 2 and 4.
- **Q3 Machine.** Windows 10 Home 22H2 (19045) on Maxim's PC is the only
  native machine so far; Windows 11 results need another machine.
- **Q4 Implementation scope.** Scenario M is added to `benchmarks/symmetric`
  on top of #23 as a new Draft PR; no change to Runtime Lab or the
  `runtime_*` contract.

## 11. Acceptance criteria for this phase

- This protocol reviewed; Q1–Q4 decided.
- Scenario M implemented with unit tests for the generator, checksums,
  paging, aggregates and the size report; CI green; a native smoke run.
- Pilot run and reported per §8, with raw data kept.
- Confirmatory protocol frozen at a CI-tested SHA before the first
  confirmatory pair.
