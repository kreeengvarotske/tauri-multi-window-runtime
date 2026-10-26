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
| Broker shared by separate applications (#27, #29) | **Conditional research branch** | Considered for production only if the in-process runtime and the realistic benchmark show that sharing within one application is not enough, a cross-application measurement then shows a memory break-even, and identity and security questions are closed. Code stays in `experiments/` until that decision |

### Out of scope

Network access, own cryptography, a plugin platform, cross-application
authentication, and any generic mechanism for copying large objects between
windows.

## 2. Metrics

**RAM and CPU are co-primary outcomes.** The framework must demonstrate its
memory effect and its CPU cost/benefit as equally important results. A positive
result on one cannot hide a materially negative result on the other. Latency,
throughput and errors remain guardrails and diagnostics. The current #33
revision 2 was written for a RAM-primary design and is being revised before
any pilot; no measurement may use its old statistical parameters.

The headline number is the **total memory of the whole application**: the
Tauri host process plus every WebView2 process it owns (browser, GPU, utility,
one renderer per window), and in the broker experiment the broker process.

| Measure | What it shows | How it is used |
|---|---|---|
| **Private Bytes** (Windows `PrivatePageCount` / commit charge) | Memory committed for one process alone. Summing it over processes does not double-count shared pages | Co-primary measure of what the application costs |
| **Working Set** | Physical pages currently resident for a process, **including shared pages** (DLLs, shared sections). Summing it over processes counts shared pages once per process | Reported per process for diagnosis. A sum is labelled as an upper bound and never used for a saving claim |
| Rust heap (allocator counters, optional) | Bytes the Rust process holds for the cache or working set | Explains where a difference comes from; not a substitute for OS counters |
| CPU time | Cost of the work | Co-primary outcome, measured for the same workload and compared under the revised protocol |
| p50/p95 latency, requests/s, errors | Runtime responsiveness and reliability | Guardrails and diagnostics |

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
| A | In-process runtime (Core) | `runtime-core`: cache policies (TTL, NoStore), invalidation, clear, coalescing, cancellation, counters; shared Rust runtime, explicit cache/response budgets and typed views | merged #3, #4, #5; open #8, #12, #14, #34, #35 |
| B | Tauri integration and multiple windows | `runtime-ipc`, `src-tauri` commands and capabilities, TS SDK, Runtime Lab, window events, separate Tauri adapter and sample | #2, #7, #28, #31, #37, #39 |
| C | Memory and CPU measurement | process monitor, symmetric harness, revised co-primary statistical protocol, realistic workload | #9, #10, #11, #16, #17, #18, #20, #23, #24, #25, #33, #36 |
| D | Cross-application architecture (conditional) | ADR, threat model, broker spike | #27, #29 (Issue #15 for the in-app access model) |
| E | Packaging and release | sample app, crate publishing, versioning, CI matrix for supported platforms | none yet |
| T | Testing (cross-cutting) | regression test for every defect, shown red on the original code; fmt, clippy `-D warnings`, workspace tests at exact SHAs; native Windows runs recorded separately from hosted CI | `docs/VERIFICATION.md` |
| Doc | Documentation (cross-cutting) | integration guide, API reference, contract and limits, verification record; all in English | this file, `docs/VERIFICATION.md`, `docs/design/` |

## 5. Phases

Status values: **done**, **review** (code and evidence exist, waiting for
review or merge), **in progress**, **blocked** (needs a decision), **not
started**, **conditional**.

| Phase | Workstream | Status | Evidence | Next step | Acceptance criteria |
|---|---|---|---|---|---|
| 0. Plan and product boundary | all | review | this file; `docs/VERIFICATION.md`; mapping of earlier decisions (§9) | Review this refreshed snapshot and settle the co-primary benchmark protocol in #33 | In-process, one-application framework remains the product; memory and CPU are co-primary; decision trail and acceptance criteria are current |
| 1. Core correctness | A | review (complete, waiting for merge) | #8 `1434e31`, #12 `c728538` (approved), #14 `772155d`: CI green and native Windows 10 on 2026-10-26 (`docs/VERIFICATION.md`); no new correctness defect found | Merge in order #8 → #12 → #14 (repository owner) | Every defect has a regression test shown red on the original code; fmt, clippy `-D warnings`, workspace tests green at exact SHAs; native Windows run recorded with OS build |
| 2. Lab and window contract | B | review | #2 `37d82d5`, #7 `1bbbc4a`, #28 `85f2937`; #31 `29adfed` validates repeated and malformed events. Hosted CI and reported native Windows checks are recorded in `docs/VERIFICATION.md` | Review/merge in dependency order; decide whether closed-secondary scenario is still required; #2 has no CI at its head | Window events treated as untrusted and validated; admin commands main-only, enforced in Rust; stats meaning with in-flight requests documented; required close/reopen behaviour tested; two-window scenario recorded |
| 3. Stable Rust API and Tauri integration | A, B | in progress | #32 records the API shape; #34 R1 adds overflow-safe cache budgets; #35 R2 at `b65177d` adds shared runtime, scopes, runtime-wide cache budgets, operation/projection limits, `ResponseBudget`, view lifecycle shutdown tracking; #37 R3 at `9e8c4eb` adds the adapter and demo. #39 sanitizes operation errors, pending review/CI | Review/merge #34 → #35 → #37 and its security follow-up #39; then implement R4 stats DTO only if needed and R5 gradual Runtime Lab migration | One runtime per app; shared Rust-owned state; each view charges response budget before building; projection slots cover serialization and abort waiting calls; WebView gets only bounded responses and sanitized errors; existing IPC remains unchanged unless a separate contract is approved |
| 4. Memory and CPU benchmark | C | in progress; protocol revision required | #33 revision 2 has A/B/C and pilot/confirmatory separation but assumes RAM-primary; Group 1 corrected this to RAM and CPU co-primary. #36 A/B scenario is Draft on #23 with hosted CI green; native smoke report pending. Monitor #24 and harness #23 are available | Update #33 family, success rules, N, thresholds, and duration for co-primary outcomes; complete native smoke #36; add C only after R2 review and exact-head checks; no pilot before protocol and scenario reviews | Matched A/B/C runs with same UI/workload; C−A product comparison and C−B framework cost kept separate; co-primary RAM and CPU criteria fixed before confirmatory runs; latency/throughput/errors guardrails; raw/failed runs and hashes retained |
| 5. Cross-app broker | D | conditional research | #27 `491486b`, #29 `4e6d19b` are experiments; CI and Windows 10 results are recorded; two-user check not run | No product work until Phase 4 gives evidence and Group 1 makes a written decision; then close identity, manifest, rights, timeout and same-user questions | Code stays in `experiments/`; production work only if measured cross-app sharing clears break-even and security/identity review |
| 6. Release path | E | not started | none | Start after Phases 1–4 are accepted | Sample app and guide; versioning and error/disabled-runtime behaviour defined; crates publishable; supported-platform CI; framework usable from a fresh Tauri app without Runtime Lab |

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

### Phase 3: mandatory criteria for the adapter (R3) and demo migration (R5)

R2 and R3 limits that the adapter and migration must close or keep visible;
none of them may be described as solved by `max_items` alone, which bounds a
count, not bytes.

- **IPC bytes.** The adapter checks raw body length before deserialization
  where Tauri supplies raw bytes; a JSON body may already have been parsed by
  Tauri before the command. The adapter does not cap transport memory before
  the command runs. Serialized responses are bounded before sending. Test:
  oversized raw and JSON requests are rejected before typed deserialization;
  oversized serialized responses are refused.
- **Response construction and projection concurrency.** A view must charge
  each allocation to `ResponseBudget` before building/copying it. The
  post-construction byte check is a backstop, not a hard peak-memory cap for
  noncompliant views. The projection slot covers project + finish/serialization;
  waiters return `SHUTTING_DOWN` after abort. Test both budget-respecting and
  budget-ignoring views, slot concurrency, and shutdown lifecycle.
- **Cheap views.** Every exposed view does work proportional to its
  response; whole-output work lives in the cached operation. Reviewed per
  view.
- **Window lifecycle.** `Runtime::forget_window` is called on window
  destroy. Test: open, use and close a window; PerWindow entries and
  weight return to the previous value; a reopened label starts empty.
- **Total memory bound.** The application sets
  `RuntimeConfig::cache_budget_bytes`; stats show Σ cache weight within it.
  Weights are estimates; the #33 benchmark checks them against measured
  Private Bytes.
- **Scope.** A frontend argument cannot change scope or caller (test).
- **Security and contract.** Caller and scope come only from trusted Rust/Tauri
  context; capabilities authorize commands. Operation error details are
  sanitized to a generic `OPERATION_FAILED` message before IPC. Existing
  demo IPC/SDK contracts remain unchanged; any DTO change is additive and
  reviewed separately (R4).

### Phase 4 scenario requirements

- One reproducible scenario replacing the separate paths in #9–#25. Same windows, data, load length, warm-up, build settings and a control run in all three arms.
- Arms (decided on #33): A, a per-window baseline where each window loads and keeps its own data in JS; B, a hand-written shared Rust service with the same bounded views; C, the framework runtime. Same UI, workload and runner (the #20 approach). C vs A answers the product question; C vs B estimates the framework's own cost; neither is used for the other's conclusion.
- A realistic operation with an explicitly measured size of the reused Rust-owned cache or working set, at several sizes including a zero-size control, so the break-even model in §3 can be fitted. A small synthetic operation alone is not enough.
- Statistical plan: revise #33 because revision 2 assumes RAM-primary/CPU-guardrail, while the current Group 1 decision is RAM and CPU co-primary. Recompute hypotheses, multiplicity, success rules, N, thresholds and duration. Keep latency, throughput and errors as guardrails. Pilot and confirmatory runs stay separate; old #25 parameters must not run.

## 6. Dependencies

```
main ─ #8 ─ #12 ─ #14 ─ #34 ─ #35 ─ #37 ─ #39       (runtime → adapter/security)
main ─ #2 ─ #7 ─ #28 ─ #31                           (Tauri Lab/window contract)
main ─ #20 ─ #23 ─ #36                              (symmetric scenario A/B → C)
main ─ #33 (co-primary protocol; gates every measurement run)
main ─ #27 ─ #29                                     (conditional cross-app research)
```

Proposed dependency order (the repository owner reviews and merges; this
roadmap does not merge or retarget PRs): core chain #8 → #12 → #14 → #34 →
#35 → #37 (R3 error-sanitization follow-up #39); Tauri Lab chain #28 → #31;
benchmark chain #20 → #23 → #36, with the revised #33 protocol approved before
any pilot. The C arm depends on the reviewed runtime API from #35 and the
adapter contract from #37. #27 → #29 remain conditional research. #11 → #16
are superseded by the symmetric harness path and remain history.

## 7. Current blockers

| Blocker | Blocks | Owner |
|---|---|---|
| #8 → #12 → #14 dependency chain is still open; #12 is approved | Phase 1 integration | Repository owner review/merge |
| #2 has no CI at its own head; #31's native Windows run and closed-secondary case need exact scope confirmation | Phase 2 integration | Repository owner |
| #34/#35/#37 are open; #35's latest `b65177d` CI is still running; #37's latest `9e8c4eb` has no exact-head workflow result recorded | Phase 3 acceptance | Review and exact-head checks |
| #39 security follow-up CI is running; local demo IPC test process failed to start with `STATUS_ENTRYPOINT_NOT_FOUND` | R3 acceptance | Review and hosted/native verification |
| #33 revision 2 uses RAM-primary/CPU-guardrail, contrary to current co-primary decision; statistical family, N, thresholds and duration must be recalculated | Phase 4 pilot and confirmatory runs | Protocol authors; Group 1 review |
| #36 A/B is hosted-CI green; native Win10 smoke data and exact retained-size/process-count checks are pending | Add arm C and pilot readiness | Scenario authors; native machine owner |
| Cross-app client identity and two-user Windows checks for #29 remain open | Conditional Phase 5 only | Group 1; requires second local account for two-user check |
| Windows 11 native evidence is unavailable; Windows 10 Home 22H2 (19045) is the only current native environment | Release gate for Windows 11 | Machine availability |

## 8. Removed from the current plan

These items are dropped from the plan because they repeat other items, are
out of date, or do not serve the product goal. PRs, branches, comments and
measurement results stay as history.

| Item | Where it came from | Reason |
|---|---|---|
| RAM-only primary with CPU as guardrail (and the preceding equal-metric draft) | #33 revision 2, pending Group 1 correction | Replaced by the current co-primary decision: RAM and CPU are equally important; #33 must recalculate its family and sample size before any run |
| Old CPU-profile-specific hypotheses and fixed-N parameters | #25 | Recompute the statistical family for both co-primary outcomes; retain the old pilot only as history |
| Paired Runtime Lab vs vanilla baseline comparison as evidence of Core cost | #10, #11, #16, #17, Issue #13 stage 4 | The two apps differ in UI and harness; the symmetric path (#20) replaces it |
| Cross-app broker as the north star | #13 comment 6402306556 | The in-process runtime is the product; the broker is conditional |
| Measuring savings from sharing WebView2/Chromium processes | early drafts | Not possible and not the product claim |
| Separate stage lists in #13 (stages 0–10), Issue #15 order, `docs/cross-app/06` phases P0–P6 | issue and PR comments | Merged into §5; those documents stay as history |
| A daemon shared across applications as part of the core product | 2026-10-25 stage list | Kept only as the conditional Phase 5 |

## 9. Mapping of earlier decisions

Earlier open questions and recommendations (Issue #13 comment 6414461497,
Issue #15, `docs/cross-app/06` on #29) mapped to this plan. **Kept**: still
needed as is. **Replaced**: needed, but in a different form. **Optional**: no
longer required for the product path; revisit only if Phase 5 is opened.

| Item | Topic | Status | Where it goes now |
|---|---|---|---|
| D1 | Product boundary | **Kept, now decided by the owner**: in-process is the product, broker is research | §1 |
| D2 | Client identity for the broker | Optional | Phase 5 entry condition |
| D3 | Manifest location | Optional | Phase 5 |
| D4 | Data classes (Public / App, no secrets) | **Replaced** by in-process scopes (`Shared` / `PerWindow`) set in Rust; no secrets in shared scope | Phase 3 API |
| D5 | Who may read stats and invalidate | **Replaced**: admin commands main-only in Rust, stats without keys or values | Phase 3 API |
| D6 | Platforms | **Kept**: Windows 10 first, Windows 11 as a release gate, Linux for CI | Phase 6 |
| D7 | Broker absent → in-process fallback | Optional | Phase 5 |
| D8 | Panic policy | **Replaced**: decide for the in-process runtime (abort vs unwind with isolation) | Phase 3 API, decision |
| D9 | Broker protocol and versioning | Optional; in-process protocol version (C-4) is kept separately | Phase 5 |
| D10 | Criteria to keep the broker | **Replaced**: measured RAM and CPU co-primary evidence plus latency/error guardrails; broker remains conditional | §2, Phase 5 |
| S-1 | Fixed N = 20, Holm over 8 (4 CPU + 4 RAM) | **Replaced**: recalculated co-primary family for RAM and CPU on the realistic scenario | Phase 4 protocol |
| S-2 | 0.2 s RAM sampling | **Replaced**: 1 s sampling of a retained data set (plateau) | Phase 4 protocol |
| S-3 | Minimum valid pairs | **Kept** as a rule, recomputed for the new family | Phase 4 protocol |
| S-4 | CPU columns/profile from the old CPU-primary protocol | **Replaced**: CPU remains co-primary; use a workload-matched CPU measure defined in the revised #33 protocol | Phase 4 protocol |
| S-5 | Equivalence rule for S1/S3 | **Kept** as the fixed-overhead check (D0 cell) | Phase 4 protocol |
| S-6 | Time budget (2.6 h + 10.2 h) | **Replaced** by the new pilot and confirmatory estimate after co-primary recalculation | Phase 4 protocol |
| S-7 | Run the #25 pilot before freezing | **Dropped**: the #25 pilot must not run with its old parameters | — |
| C-1 | Counters counted on entry vs completion | **Kept**, extended: add `cancelled` and other outcomes so every request ends in one counter | Phase 3 API, decision |
| C-2 | Window events unauthenticated; remove `allow-emit*` from secondary | **Kept** | Phase 2; #31 validates payloads meanwhile |
| C-3 | Window label as admin authority | **Kept** for the demo; any private data needs a stronger identity first | Phase 3 |
| C-4 | `runtime_get_protocol_info` | **Kept**, separate agreed PR after the stack merges | Phase 3 |
| #13 stages 0–5 | Audit, PR A/B, Windows checks, first benchmark, architecture report | Done; results in `docs/VERIFICATION.md` | history |
| #13 stages 6–10 | Lab handshake, baseline, monitor units, symmetric design, decision memo | Monitor and symmetric harness **kept** (Phase 4); Lab vs vanilla comparison **optional** (superseded) | Phase 4 |
| #15 F1, A1–A3 | Access context not in keys; scope in Rust; operation registry | **Kept** as the core of the API | Phase 3 |
| #15 F3, A4 | Events are not authenticated; private data only in direct responses | **Kept** | Phases 2 and 3 |
| #15 A5 | Protocol versioning | **Kept** (same as C-4) | Phase 3 |
| #15 §6 | Shared Runtime saves at most the Core share unless it holds heavy data | **Kept**: the reason the benchmark needs a realistic data set | §3, Phase 4 |

## 10. Reporting

After each phase: what was done and what remains; PR links and exact SHAs;
commands, platforms and actual results (hosted CI and native runs reported
separately; CI is not native verification); defects and limits found; memory
impact, including where data is stored and copied; the next phase and the
questions that need a decision. A phase is complete only with verifiable
results against its acceptance criteria.
