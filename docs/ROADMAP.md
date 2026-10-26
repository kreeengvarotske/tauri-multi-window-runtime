# Roadmap

Status as of 2026-10-26. This file is the single current plan. It replaces the
stage lists scattered across Issue #13, Issue #15 and the PR descriptions for
planning purposes; those remain as history and are not edited or deleted.

## 1. Product goal

A framework for Tauri v2 applications that **reduces duplicated memory and
duplicated work between the windows of one application**.

The value comes from keeping data, caches and operations **in the Rust process,
once**, instead of once per window:

- one Rust-owned cache or working set serves every window;
- identical concurrent operations from several windows run once (coalescing);
- windows receive only what they render (a page, an aggregate, a summary), not
  their own full copy of the data set.

What the framework does **not** do: it does not merge, share or shrink
WebView2/Chromium processes. Every window keeps its own renderer. Those
processes are measured (they are most of an application's memory) so that a
result is honest, but they are never presented as the thing being shared.

### Main path and conditional path

| Path | Status | Rule |
|---|---|---|
| In-process runtime inside one Tauri application | **Main path** | All product work targets this |
| Broker shared by separate applications (#27, #29) | **Conditional, experimental** | Continues only after (a) a measured memory break-even on a realistic workload and (b) closed identity and security questions. Code stays in `experiments/` until an architecture decision |

### Out of scope

Network access, own cryptography, a plugin platform, cross-application
authentication, and any generic mechanism for copying large objects between
windows.

## 2. Metrics

**RAM is the primary outcome.** CPU time, latency, throughput and error counts
are diagnostics and guardrails: a change may not make them materially worse,
but they are not equal savings targets. (This supersedes the 2026-10-26
morning record "RAM and CPU are equal confirmatory metrics" in
`docs/cross-app/01`, `05` and `06` on #29.)

The headline number is the **total memory of the whole application**: the
Tauri host process plus every WebView2 process it owns (browser, GPU, utility,
one renderer per window), and in the broker experiment the broker process.

| Measure | What it shows | How it is used |
|---|---|---|
| **Private Bytes** (Windows `PrivatePageCount` / commit charge) | Memory committed for one process alone. Summing it over processes does not double-count shared pages | Primary measure of what the application costs |
| **Working Set** | Physical pages currently resident for a process, **including shared pages** (DLLs, shared sections). Summing it over processes counts shared pages once per process | Reported per process for diagnosis. A sum is labelled as an upper bound and never used for a saving claim |
| Rust heap (allocator counters, optional) | Bytes the Rust process holds for the cache or working set | Explains where a difference comes from; not a substitute for OS counters |
| CPU time, p50/p95 latency, requests/s, errors | Cost of the work | Guardrails and diagnostics |

Runtime counters (`executions`, `coalesced`, `cacheHits`) prove that work was
deduplicated. They are not evidence of a memory saving.

## 3. Where memory lives

Every API decision and every benchmark result states where the data is held and
how many times it is copied:

| Location | One per | Notes |
|---|---|---|
| Rust process heap (cache, working set) | application | What the framework shares |
| WebView renderer (JS heap, DOM) | window | Each window pays for whatever it keeps. JS objects are usually larger than the Rust representation |
| IPC buffers | call | The serialized request and response exist transiently in both processes |
| Deserialized result in JS | window × call | Persists if the window keeps it |

### Break-even model (in-process)

For `N` windows that need the same data set:

```
Plain(N)     = H + N·(R + Dw + Ww)
Framework(N) = H + Δrt + Dr + Wr + N·(R + Tw) + I

Saving(N)    = N·(Dw + Ww − Tw) − (Δrt + Dr + Wr + I)
```

- `H`: host process without the data; `R`: one window's renderer without the data
- `Dw`: the data set as one window holds it in plain Tauri (JS objects, or a per-window Rust copy)
- `Ww`: transient working memory of one window's own computation
- `Dr`, `Wr`: the same data and working memory, once, in Rust
- `Tw`: what a window keeps in the framework arm (a page or aggregate)
- `Δrt`: fixed runtime overhead (registry, coalescer, tokio pool, diagnostics)
- `I`: average in-flight IPC and serialization buffers

If a window keeps a full copy (`Tw ≈ Dw`), the framework only saves working
memory and the fixed cost can make it a loss. If windows keep pages
(`Tw ≪ Dw`), the saving grows by about `Dw` per extra window. The Stage 4
demo operation has `Dw ≈ Ww ≈ 0`, which is why it showed no saving: the Rust
process was about 8–9 MB Private of 280–315 MB total, and the rest was WebView2
(Issue #15, §6). The memory benchmark therefore needs a realistic data set
(Phase 4).

## 4. Workstreams

| ID | Workstream | Contents | Existing PRs |
|---|---|---|---|
| A | In-process runtime (Core) | `runtime-core`: cache policies (TTL, NoStore), invalidation, clear, coalescing, cancellation, counters; then the stable Rust API | merged #3, #4, #5; open #8, #12, #14 |
| B | Tauri integration and multiple windows | `runtime-ipc`, `src-tauri` commands and capabilities, TS SDK, Runtime Lab, window events | #2, #7, #28 |
| C | Memory measurement | process monitor, symmetric harness, statistical protocol, realistic workload | #9, #10, #11, #16, #17, #18, #20, #23, #24, #25 |
| D | Cross-application architecture (conditional) | ADR, threat model, broker spike | #27, #29 (Issue #15 for the in-app access model) |
| E | Packaging and release | sample app, integration guide, crate publishing, CI matrix | none yet |

## 5. Phases

Status values: **done**, **review** (code and evidence exist, waiting for
review or merge), **in progress**, **blocked** (needs a decision), **not
started**, **conditional**.

| Phase | Workstream | Status | Evidence | Next step | Acceptance criteria |
|---|---|---|---|---|---|
| 0. Plan and product boundary | all | in progress | this file | Review and agree this roadmap | Roadmap agreed; stale items in §8 accepted as removed |
| 1. Core correctness | A | review | #8 `1434e31`; #12 `c728538` (approved, CI green, native Windows 10); #14 `772155d` (CI green, native Windows 10) | Re-verify #8/#12/#14 together at exact SHAs (Phase 1 checklist below); merge in order #8 → #12 → #14 | Every defect has a regression test shown red on the original code; fmt, clippy `-D warnings`, workspace tests green at exact SHAs; native Windows run recorded with OS build |
| 2. Lab and window contract | B | review | #2 `37d82d5`, #7 `1bbbc4a`, #28 `85f2937` (CI green; native Windows 10 22H2 19045 incl. manual two-window run) | Joint check of #2 + #7 + #28 (Phase 2 checklist); #2 has no CI at its head | Window events treated as untrusted and validated; admin commands main-only, enforced in Rust; stats meaning with in-flight requests documented; closed-secondary behaviour tested; manual two-window scenario recorded |
| 3. Stable Rust API | A, B | not started | Issue #15 (A1–A5), decision memo in #13 | Written API proposal: config, typed operation registry, shared cache access, cancellation/deadlines/limits/shutdown, safe diagnostics, Tauri adapter; memory location stated per API | Proposal agreed; implementation with tests; WebView never sees runtime internals; no public IPC/SDK change without agreement |
| 4. Memory benchmark | C | blocked | #20 `9c40dd5` → #23 `3f70b7d` → #25 `ed756a8` (CI green, protocol not approved); monitor #18 `1d57f6f` → #24 `6952886` (native Windows 10: 0.2 s median 0.214 s) | Consolidate #9–#25 into one scenario; recompute #25 with RAM primary; add a realistic Rust-owned data set; write the pilot protocol | Pilot protocol reviewed before any confirmatory run; RAM primary, CPU/latency/errors guardrails; all processes summed with Private Bytes; configs, hashes, raw data and failed runs kept |
| 5. Cross-app broker | D | conditional | #27 `491486b`, #29 `4e6d19b` (CI green incl. hosted Windows; native Windows 10: 12/12 cross-process tests 6/6 runs; two-user check not run) | Independent re-check of #27 and #29; list checks that need a second local user | Stays experimental until identity is decided and Phase 4 shows break-even on a realistic workload |
| 6. Release path | E | not started | none | Starts after Phases 1–4 pass | Sample app and guide; versioning and error/disabled-runtime behaviour defined; crate publishable; CI for supported platforms; framework used from a fresh Tauri app without Runtime Lab |

### Phase 1 checklist (Core)

- cache policies, TTL, NoStore, invalidation, clear;
- concurrent requests, coalescing, and the point at which an operation counts as complete;
- errors, client cancellation and disappearing waiters (errors are never cached or shared to later callers);
- independence of keys;
- counter values while requests are in flight.

### Phase 2 checklist (Lab and window contract)

- shared Rust state between windows;
- access to admin operations;
- validation of project ID and series size;
- malformed, repeated and forged frontend events (the payload limit bounds load from one request; it does not identify the sender);
- statistics while requests are unfinished;
- behaviour when the secondary window is closed;
- a manual scenario with two real Tauri windows.

### Phase 4 scenario requirements

- One reproducible scenario replacing the separate paths in #9–#25. Same windows, data, load length, warm-up, build settings and a control run in both arms.
- Arms: a plain Tauri application where each window loads and keeps its own data, and the same application with the framework holding the data once in Rust and windows requesting pages. Both arms share one frontend and one runner (the #20 approach).
- A realistic operation with an explicitly measured size of the reused Rust-owned cache or working set, at several sizes including a zero-size control, so the break-even model in §3 can be fitted. A small synthetic operation alone is not enough.
- Statistical plan (recomputed from #25 with RAM primary): hypothesis, unit of analysis, number of pairs, handling of missing runs, quality filters, comparisons, duration. Pilot and confirmatory runs are separate.

## 6. Dependencies

```
main ─ #2 ─ #7 ─ #8 ─ #12 ─ #14 ─┬─ #28                       (A, B)
                                 ├─ #20 ─ #23 ─ #25           (C)
                                 └─ #27 ─ #29                 (D)
       #2 ─ #9 ─┬─ #18 ─ #24                                  (C, monitor)
                └─ #10 ─ #17                                  (C, baseline)
       #8 ─ #11 ─ #16                                         (C, old paired Lab)
main ─ #26 (agent handoff docs)
```

Proposed merge order (the repository owner merges; nothing here merges or
retargets a PR): #2 → #7 → #8 → #12 → #14 → #28; then #9 → #18 → #24 and
#9 → #10 → #17; #20 → #23 → #25 after the Phase 4 protocol decision. #27 → #29
stay Draft as research. #11 → #16 are superseded by the #20 path for
measurement (see §8) and are kept for history.

## 7. Current blockers

| Blocker | Blocks | Owner |
|---|---|---|
| No review yet on #8 and #14; #12 approved but must follow #8 | Phase 1 merge | Repository owner |
| #2 has no CI run at its head (CI is added in #7) | Phase 2 merge | Repository owner |
| Statistical protocol (#25) not approved; must be recomputed with RAM primary | Phase 4 pilot and confirmatory runs | Group 1 |
| No realistic workload with a measurable Rust-owned data set | Phase 4 | Group 2 proposal, Group 1 agreement |
| Choice of the plain-arm baseline (what a plain window keeps) | Phase 4 | Group 1 |
| Group 1 decisions D1–D10, S-1…S-7, C-1…C-4 (#13 comment 6414461497) still open | Phases 3–5 | Group 1 |
| Client identity for the broker (D2/D3, Q1) | Phase 5 | Group 1 |
| Two-user Windows check for #29 needs a second local account | Phase 5 | Maxim |
| No Windows 11 machine; native evidence so far is Windows 10 Home 22H2 (19045) only | release gate for Windows 11 | Group 1 |

## 8. Removed from the current plan

These items are dropped from the plan because they repeat other items, are
out of date, or do not serve the product goal. PRs, branches, comments and
measurement results stay as history.

| Item | Where it came from | Reason |
|---|---|---|
| RAM and CPU as equal confirmatory metrics | 2026-10-26 assignment, `docs/cross-app/05` on #29 | Replaced by RAM primary, CPU guardrail |
| CPU-profile primary hypotheses in the fixed-N protocol | #25 | CPU is a guardrail; the family is recomputed for RAM |
| Paired Runtime Lab vs vanilla baseline comparison as evidence of Core cost | #10, #11, #16, #17, Issue #13 stage 4 | The two apps differ in UI and harness; the symmetric path (#20) replaces it |
| Cross-app broker as the north star | #13 comment 6402306556 | The in-process runtime is the product; the broker is conditional |
| Measuring savings from sharing WebView2/Chromium processes | early drafts | Not possible and not the product claim |
| Separate stage lists in #13 (stages 0–10), Issue #15 order, `docs/cross-app/06` phases P0–P6 | issue and PR comments | Merged into §5; those documents stay as history |
| A daemon shared across applications as part of the core product | 2026-10-25 stage list | Kept only as the conditional Phase 5 |

## 9. Reporting

After each phase: what was done and what remains; PR links and exact SHAs;
commands, platforms and actual results (hosted CI and native runs reported
separately; CI is not native verification); defects and limits found; memory
impact, including where data is stored and copied; the next phase and the
questions that need a decision. A phase is complete only with verifiable
results against its acceptance criteria.
