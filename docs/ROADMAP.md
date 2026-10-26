# Roadmap

Snapshot: 2026-10-26, about 23:00 UTC (live refs read at that time; see the
change log in §11). This file is the single current plan. It replaces the
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
| E | Packaging and release | sample app, crate publishing, versioning, CI matrix for supported platforms | none yet |
| T | Testing (cross-cutting) | regression test for every defect, shown red on the original code; fmt, clippy `-D warnings`, workspace tests at exact SHAs; native Windows runs recorded separately from hosted CI | `docs/VERIFICATION.md` |
| Doc | Documentation (cross-cutting) | integration guide, API reference, contract and limits, verification record; all in English | this file, `docs/VERIFICATION.md`, `docs/design/` |

## 5. Phases

Status values: **done**, **review** (code and evidence exist, waiting for
review or merge), **in progress**, **blocked** (needs a decision), **not
started**, **conditional**.

| Phase | Workstream | Status | Evidence | Next step | Acceptance criteria |
|---|---|---|---|---|---|
| 0. Plan and product boundary | all | review | this file; `docs/VERIFICATION.md`; mapping of earlier decisions (§9) | Review and agree this roadmap | Roadmap agreed; items in §8 and §9 accepted |
| 1. Core correctness | A | review (complete, waiting for merge) | #8 `1434e31`, #12 `c728538` (approved), #14 `772155d`: CI green and native Windows 10 on 2026-10-26 (`docs/VERIFICATION.md`); no new correctness defect found | Merge in order #8 → #12 → #14 (owner) | Every defect has a regression test shown red on the original code; fmt, clippy `-D warnings`, workspace tests green at exact SHAs; native Windows run recorded with OS build |
| 2. Lab and window contract | B | review | #2 `37d82d5`, #7 `1bbbc4a`, #28 `85f2937` (CI green; native incl. manual two-window run); #31 `29adfed` fixes repeated and malformed window events (CI green, native two-window and forged-event run) | Closed-secondary scenario; C-2 decision; #2 has no CI at its head | Window events treated as untrusted and validated; admin commands main-only, enforced in Rust; stats meaning with in-flight requests documented; closed-secondary behaviour tested; manual two-window scenario recorded |
| 3. Stable Rust API | A, B | in progress | #32 `bfe8399` (shape and decisions recorded at `357e253`; `bfe8399` adds the exact view-limit and shutdown wording). R1 #34 `d8106fa`: cache budget, overflow-safe LRU; CI 40390472644 green; native Windows 10 pass (stress 0/200). R2 #35: at `4d2b5ce` (runtime-wide cache budget, view item/byte/projection limits, window lifecycle) CI 40391728968 green and native Windows 10 pass (stress 0/200); new head `b65177d` (view budget, shutdown during views) CI running, no native run; overlaps #38 `353bba5` (owner's fix of the same review), decision pending. R3 #37 `9e8c4eb` (adapter + demo): tests pass on Linux; the adapter workflow failed at `fd124c1` (see §7) | Owner decides #35 vs #38; then review #34/#35/#37; R4 only if an additive stats DTO is needed; R5 demo migration | Contract agreed before code; tests per PR; WebView never sees runtime internals; current IPC unchanged until a migration is agreed; the R3/R5 criteria below met |
| 4. Memory benchmark | C | in progress (protocol Draft, scenario Draft; no measurements) | #33 `e79aca1`: three arms A per-window / B hand-written shared / C framework; Q1–Q6 decided (δ, ε, guardrails fixed in advance); protocol still Draft/review. Scenario M #36 `d0b2893` (arms A and B, runner, schedule, descriptive summarizer): CI 40395314459, 40395314302, 40395314370 green; native Windows 10 smoke requested, no result yet | Native smoke of #36 and its review; arm C only after the R2 review and green exact-head checks; pilot only after the protocol review and the native smoke; confirmatory only after the pilot report and a frozen protocol; **do not run the #25 pilot with its old parameters** | Pilot protocol reviewed before any run; confirmatory only after the pilot report and a frozen protocol; RAM primary, CPU/latency/errors guardrails; all processes summed with Private Bytes; configs, hashes, raw data and failed runs kept |
| 5. Cross-app broker | D | conditional research | #27 `491486b`, #29 `4e6d19b` (CI green incl. hosted Windows; native Windows 10: 12/12 cross-process tests in 6/6 runs; two-user check not run) | None until Phase 4 reports. Then a written decision whether a cross-app stage is needed, with the measurement and the open identity, manifest, rights, timeout and same-user questions | Stays in `experiments/`; production work only after that decision |
| 6. Release path | E | not started | none | Starts after Phases 1–4 pass | Sample app and guide; versioning and error/disabled-runtime behaviour defined; crate publishable; CI for supported platforms; framework used from a fresh Tauri app without Runtime Lab |

### Status by category (snapshot 2026-10-26)

No open PR is merged. Only `main` @ `4bf7da3` (#3, #4, #5) is integrated.

| Category | Items |
|---|---|
| **Integrated** | #3, #4, #5 on `main` |
| **Implementation complete, awaiting review or merge** (CI green and native Windows 10 at the exact head) | Core: #8 `1434e31`, #12 `c728538` (approved), #14 `772155d`. Lab: #28 `85f2937`, #31 `29adfed`. API: R1 #34 `d8106fa`. Monitor: #24 `6952886` |
| **In progress** | API proposal #32 `bfe8399` (doc, Draft). R2 #35 `b65177d` (CI running, native not run; overlap with #38 to resolve). R3 #37 `9e8c4eb` (adapter workflow red at `fd124c1`; a fix is prepared and not pushed until #35 is decided). Protocol #33 `e79aca1` (Draft). Scenario M #36 `d0b2893` (arms A and B, native smoke pending) |
| **Not started** | R4 stats DTO (only if needed), R5 demo migration, arm C of scenario M, pilot, confirmatory runs, Phase 6 |
| **Conditional research** | #27 `491486b`, #29 `4e6d19b` |

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

Known limits of R2 that the adapter and migration must close or keep
visible; none of them may be described as solved by `max_items` alone,
which bounds a count, not bytes.

- **IPC bytes.** Each command bounds the raw request payload
  (`max_request_bytes`) before deserializing and the serialized response
  (`max_response_bytes`) before sending it to the WebView. Test: an
  oversized request and an oversized serialized response are refused.
- **Projection concurrency.** View responses are built and serialized
  inside `ViewHandle::get_with`, so `max_concurrent_projections` bounds
  transient response memory. Test: several windows request large
  responses at once; peak concurrent projections and host Private Bytes
  stay within the configured bound.
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
- **Contract.** Existing command names, payloads, capabilities and error
  envelope unchanged (contract tests); any DTO change is additive and
  reviewed separately (R4).

### Phase 4 scenario requirements

- One reproducible scenario replacing the separate paths in #9–#25. Same windows, data, load length, warm-up, build settings and a control run in both arms.
- Arms (decided on #33): A, a per-window baseline where each window loads and keeps its own data in JS; B, a hand-written shared Rust service with the same bounded views; C, the framework runtime. Same UI, workload and runner (the #20 approach). C vs A answers the product question; C vs B estimates the framework's own cost; neither is used for the other's conclusion.
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

Phase 3 and 4 chains (open Draft PRs; the base is the branch of the PR on
the left):

```
#14 ─ #34 (R1) ─ #35 (R2) ─┬─ #37 (R3) ─ R4 (only if an additive stats DTO is needed) ─ R5 (demo migration)
                           └─ #38 (owner's alternative fix of the same review)
#23 ─ #36 (scenario M, arms A and B) ─ arm C (after the R2 review and checks)
#33 (protocol) ─ review ─┐
#36 native smoke ────────┴─ pilot ─ pilot report ─ frozen protocol ─ confirmatory
```

Proposed merge order (the repository owner merges; nothing here merges or
retargets a PR): #2 → #7 → #8 → #12 → #14 → #28; then #9 → #18 → #24 and
#9 → #10 → #17; #20 → #23 → #25 after the Phase 4 protocol decision. #27 → #29
stay Draft as research. #11 → #16 are superseded by the #20 path for
measurement (see §8) and are kept for history.

## 7. Current blockers

Only conditions that are still open. Decided and removed since the previous
snapshot: the statistical protocol and the plain-arm baseline (decided in
#33, Q1–Q6), the realistic workload (scenario M in #36), and the API
questions D4, D5, D8, C-1, C-3 (decided in #32 §10).

| Blocker | Blocks | Owner |
|---|---|---|
| No review yet on #8 and #14; #12 approved but must follow #8 | Phase 1 merge | Repository owner |
| #2 has no CI run at its head (CI is added in #7) | Phase 2 merge | Repository owner |
| #35 and #38 fix the same review comments (6428297151) in two ways; one must be chosen | R2 review, #37, arm C | Repository owner |
| #37's adapter workflow failed at `fd124c1`: Windows test binary did not start (`STATUS_ENTRYPOINT_NOT_FOUND`, missing Common Controls manifest), and the "no Tauri dependency" check matched the checkout path on every runner. Fix `cfe6b65` exists locally, not pushed | R3 review | Group 2 (after the #35 decision) |
| No native Windows run at `b65177d` (#35) or at any #37 head | R2/R3 review | Group 2 |
| Native smoke of #36 not reported | Pilot | Group 2 |
| #33 protocol still Draft | Pilot | Group 1 review |
| C-2: window events carry no sender identity; `allow-emit*` on secondary | Phase 2 | Group 1 decision |
| C-4: protocol info command | Phase 3, after the stack merges | Group 1 agreement |
| Client identity for the broker (D2/D3) | Phase 5 only | Group 1 |
| Two-user Windows check for #29 needs a second local account | Phase 5 only | Maxim |
| No Windows 11 machine; native evidence so far is Windows 10 Home 22H2 (19045.6466) only | release gate for Windows 11 | Group 1 |

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
| D10 | Criteria to keep the broker | **Replaced**: RAM-primary break-even, CPU and latency as guardrails | §2, Phase 5 |
| S-1 | Fixed N = 20, Holm over 8 (4 CPU + 4 RAM) | **Replaced**: RAM-primary family on the realistic scenario | Phase 4 protocol |
| S-2 | 0.2 s RAM sampling | **Replaced**: 1 s sampling of a retained data set (plateau) | Phase 4 protocol |
| S-3 | Minimum valid pairs | **Kept** as a rule, recomputed for the new family | Phase 4 protocol |
| S-4 | Memory columns in the CPU profile | Optional (no CPU profile as a primary) | — |
| S-5 | Equivalence rule for S1/S3 | **Kept** as the fixed-overhead check (D0 cell) | Phase 4 protocol |
| S-6 | Time budget (2.6 h + 10.2 h) | **Replaced** by the new pilot and confirmatory estimate | Phase 4 protocol |
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

## 11. Change log

| Snapshot | Changes |
|---|---|
| 2026-10-26 ~18:00 UTC (`2dbe7bb`…`15e3ef2`) | First roadmap: product goal, RAM primary, phases, §9 mapping |
| 2026-10-26 ~20:40 UTC (`44d0b06`) | Phase 3 progress; mandatory R3/R5 criteria; Phase 4 three arms |
| 2026-10-26 ~23:00 UTC (this commit) | Live heads for #32–#38; status by category; Phase 3/4 dependency chains; blockers reduced to open conditions (protocol, baseline, workload, API decisions removed as decided); #35/#38 overlap and #37 CI failure recorded. No pilot run, no IPC/API contract change |
