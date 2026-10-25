# 01. Current state, dependencies and open gates

**Snapshot:** 2026-10-25, about 20:10–20:20 UTC. Read-only GitHub audit (PR list, exact-head check runs, branches, Issue #13 comments). The live repository supersedes this file. Nothing was merged, retargeted, rebased or commented on.

`main` = `4bf7da3baabbd764991104ac285c419b535ecc67` (only #3, #4, #5 are merged).

## 1. Pull requests (#1–#26)

| # | Title (short) | State | Head branch @ SHA | Base branch @ SHA (GitHub) | Base == parent head? | Checks on exact head SHA |
|---|---|---|---|---|---|---|
| 1 | docs: Tauri IPC contract proposal | open, draft | claude/project-thread-n7gxu6 @ `1d8d44c91f34065b03e5d36ecafbda0b3d6a780b` | main @ `90666788ae6c5084d58126bd8d494ecc03a95586` | **NO** — main is now `4bf7da3b…` (stale base) | no checks |
| 2 | feat(tauri): integrate runtime IPC into Runtime Lab | open | feat/frontend-integration @ `37d82d5821189df2dda058e496f6e57700d885b0` | main @ `4bf7da3baabbd764991104ac285c419b535ecc67` | yes (main) | **no checks** |
| 3 | Feat/runtime core | closed, merged 2026-10-23T16:48:22Z | feat/runtime-core @ `5e616a881b1cee0ef8252f93fd16417ae10c318a` | main @ `90666788ae6c5084d58126bd8d494ecc03a95586` | n/a | n/a |
| 4 | build: add root Cargo workspace | closed, merged 2026-10-23T17:25:28Z | feat/workspace-root @ `0b37ba3d14dc45f5c5573991bebdc6d1ab369536` | main @ `f7999644e49a15575de57b4cc67cd97d0d142315` | n/a | n/a |
| 5 | feat(runtime-ipc): demo service and stats | closed, merged 2026-10-23T18:15:44Z | feat/runtime-ipc @ `cddc750925c7bf9ddc9ad8dcc1c97b67760d0795` | main @ `3201645327d467c6b4844abc39011e53bf0d08a8` | n/a | n/a |
| 6 | Add TypeScript SDK and Tauri frontend | closed, not merged | claude/project-thread-0wd0no @ `a0ee86533a96329f215dcf0cc94338fc55a1292b` | main @ `4bf7da3baabbd764991104ac285c419b535ecc67` | n/a (branch reused by #7) | n/a |
| 7 | Runtime Lab: cache events, live stats, TTL, export, CI | open | claude/project-thread-0wd0no @ `1bbbc4a728f3b205c3b1630c97ef3b9803b2cbd5` | feat/frontend-integration @ `37d82d5821189df2dda058e496f6e57700d885b0` | yes (#2) | frontend success, rust success — run [40016728038](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/40016728038) |
| 8 | fix(runtime-core): key-scoped cache invalidation | open, draft | fix/key-scoped-cache-invalidation @ `1434e31c6a74dde697aa67b91c184a9ed0c63c1b` | claude/project-thread-0wd0no @ `1bbbc4a728f3b205c3b1630c97ef3b9803b2cbd5` | yes (#7) | rust success, frontend success — run [40018036550](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/40018036550) |
| 9 | feat(benchmarks): Windows process monitor | open, draft | benchmarks/windows-process-monitor @ `1f71b840a920cde4aa92bb25a87060bae85742da` | feat/frontend-integration @ `37d82d5821189df2dda058e496f6e57700d885b0` | yes (#2) | **no checks** |
| 10 | feat(benchmarks): vanilla Tauri baseline | open, draft | benchmarks/vanilla-tauri-baseline @ `f73fe04335ebbccca4daf3d569637a51a6d97e94` | benchmarks/windows-process-monitor @ `1f71b840a920cde4aa92bb25a87060bae85742da` | yes (#9) | windows-release success x2 — runs [40127662239](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/40127662239), [40127659087](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/40127659087) (no rust/frontend) |
| 11 | feat(benchmarks): automate paired-window checks | open, draft | benchmarks/automated-runtime-suite @ `ee5f47555287b6af8d7a6015a25d8f52d8148d7c` | fix/key-scoped-cache-invalidation @ `1434e31c6a74dde697aa67b91c184a9ed0c63c1b` | yes (#8) | frontend success, rust success — run [40124635438](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/40124635438) |
| 12 | test(runtime-core): stage 1 concurrency tests (PR A) | open | claude/project-thread-7esmen @ `c7285381a908d0380acaf25e883f90ba3c0f723a` | fix/key-scoped-cache-invalidation @ `1434e31c6a74dde697aa67b91c184a9ed0c63c1b` | yes (#8) | rust success, frontend success — run [40190883397](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/40190883397) |
| 14 | fix(runtime-core): coalescer completed-op fix (PR B) | open, draft | claude/project-thread-qzzw0x @ `772155def9f4baf232f43864a80add7cd3c5192c` | claude/project-thread-7esmen @ `c7285381a908d0380acaf25e883f90ba3c0f723a` | yes (#12) | rust success, frontend success — run [40193472340](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/40193472340) |
| 16 | Runtime Lab: handshake + safe round end (6.1, 7) | open, draft | claude/lab-bench-protocol @ `ea8014b91f53bb89b71a79d91885b3e0ddc45cc7` | benchmarks/automated-runtime-suite @ `ee5f47555287b6af8d7a6015a25d8f52d8148d7c` | yes (#11) | frontend success, rust success — run [40203656477](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/40203656477) |
| 17 | Vanilla baseline: handshake, release profile, Cargo.lock | open, draft | claude/baseline-handshake @ `1cb4bc0b278dff1df71e31b94830ac35e7c4135d` | benchmarks/vanilla-tauri-baseline @ `f73fe04335ebbccca4daf3d569637a51a6d97e94` | yes (#10) | windows-release success — run [40204930981](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/40204930981) (no rust/frontend) |
| 18 | Process monitor: PrivatePageCount unit check, -Diagnostics | open, draft | claude/monitor-units @ `1d57f6f68eb745ab86f16e3e6e23d137808a300a` | benchmarks/windows-process-monitor @ `1f71b840a920cde4aa92bb25a87060bae85742da` | yes (#9) | **no checks** |
| 19 | fix(monitor): sub-second sampling, fail closed | closed, draft, not merged | review/monitor-guardrails-20261025 @ `591302bdadf5655bfab33d5acd4f235ef8023701` | claude/monitor-units @ `c88951333e90c1458fe5fa8eff1a67f971ac99a9` | (was stale; superseded by #24) | n/a |
| 20 | Symmetric plain/runtime benchmark S1–S4 (stage 9) | open, draft | claude/symmetric-bench @ `9c40dd562849bf0883e7377b31200967e19e0277` | claude/project-thread-qzzw0x @ `772155def9f4baf232f43864a80add7cd3c5192c` | yes (#14) | frontend success, rust success — run [40218090430](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/40218090430); windows-release success — run [40218090495](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/40218090495) |
| 21 | fix(benchmark): preserve failed runs, validate samples | closed, draft, not merged | review/symmetric-summarizer-guards-20261025 @ `370083e3df537531bc2ed5a07d9817ec2798841b` | claude/symmetric-bench @ `4b0c62f76cb61356641c55c8e2bbc1f88a731816` | (was stale) | n/a |
| 22 | fix(benchmark): per-metric monitor quality | closed, draft, not merged | review/symmetric-quality-guards-20261025 @ `dce3d354e08cf970f959be6ae3f30532d0e9d196` | claude/symmetric-bench @ `9c40dd562849bf0883e7377b31200967e19e0277` | n/a | n/a |
| 23 | fix(benchmark): isolate secondary metric quality | open, draft | review/symmetric-metric-quality-20261025 @ `3f70b7d63628db7cec78a5fd927d0ac136992266` | claude/symmetric-bench @ `9c40dd562849bf0883e7377b31200967e19e0277` | yes (#20) | rust success, frontend success — run [40219219157](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/40219219157); windows-release success — run [40219219142](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/40219219142) |
| 24 | fix(monitor): fail closed on unknown private-memory units | open, draft | review/monitor-guardrails-refresh-20261025 @ `6952886fa938795dcf85a8de0c2b2c55d1ac86ba` | claude/monitor-units @ `1d57f6f68eb745ab86f16e3e6e23d137808a300a` | yes (#18) | powershell-smoke success — run [40220356939](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/40220356939) (only check) |
| 25 | fix(benchmark): fixed-N confirmatory protocol | open, draft | review/fixed-n-protocol-clean-20261025 @ `ed756a826688f754ef0a2aed63dc738c2fb12eb0` | review/symmetric-metric-quality-20261025 @ `3f70b7d63628db7cec78a5fd927d0ac136992266` | yes (#23) | frontend success, rust success — run [40224027381](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/40224027381); windows-release success — run [40224027347](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/40224027347) |
| 26 | docs: coordinated GPT Codex handoff | open, draft | codex/handoff-20261025 @ `83bd2fb5219616d5a6e6100d51aa77bda632230c` | main @ `4bf7da3baabbd764991104ac285c419b535ecc67` | yes (main) | **no checks** |

All check runs observed on exact heads are `completed / success`. None is red or pending. **No checks at all:** #1, #2, #9, #18, #26. **Partial:** #10 and #17 (windows-release only) and #24 (powershell-smoke only).

## 2. Stacks

```
main ─ #2 ─ #7 ─ #8 ─ #12 ─ #14 ─ #20 ─ #23 ─ #25        Runtime/Core → symmetric benchmark
        │          └─ #11 ─ #16                           Runtime Lab paired benchmark
        └─ #9 ─ #10 ─ #17                                 monitor → vanilla baseline
             └─ #18 ─ #24                                 Windows monitor
main ─ #26 (Codex handoff docs)      main@90666788 ─ #1 (stale base, docs)
```

Each base SHA equals the current head of its parent branch, except #1. Closed and unmerged: #6, #19 (replaced by #24), #21 and #22 (stale review duplicates; fixes ported selectively into #20/#23/#25). Two branches have no PR: `docs/performance-benchmark-plan` @ `b092df2`, `review/fixed-n-stat-protocol-20261025` @ `8277535`.

"The #20–#25 benchmark stack" is really **#20 → #23 → #25**. #24 belongs to the monitor stack, and #21/#22 are closed.

## 3. Issues

- **#13** (open, 25 comments). This is the coordination log. The latest comment is 6402306556 (owner, 19:44 UTC), *"Proposed north star and roadmap update"*. It proposes an opt-in cross-app broker as the product goal, memory as the first optimisation target with CPU descriptive only, and an ADR plus threat model before any cross-app code. It says that a synthetic PoC comes **only after ADR approval**. The comment is explicitly "a proposal for Group 1 review, not approval".
- **#15** (open, 0 comments). The Stage 5 Shared/Private risk report. It is the starting point for the threat model in [03](03-threat-model.md).

## 4. What is fixed, what is open, what is not a decision

| Item | Status | Evidence |
|---|---|---|
| Key-scoped invalidation | **Fixed in an open PR** (#8), not on `main` | CI 40018036550 |
| Coalescer reused a completed operation (В1) | **Fixed in an open PR** (#14 `772155d`). Red-then-green tests are in #12/#14 | CI 40193472340; native Windows 10 run recorded in #13 |
| Concurrency regression tests T1–T12 | In #12, open | CI 40190883397 |
| Access context is not part of the cache/coalescer key (В6) | **Open by design**: documented limit, nothing enforces it | `service.rs` rustdoc; #15 F1 |
| Window label as the only authority; `core:event:default` allows emit/emit-to from any window | **Open**. Stage 10 is memo-only | #15 F2/F3; stage 10 memo v2 |
| No protocol/SDK version | **Open** | #15 F5 |
| Symmetric benchmark protocol (#25, fixed N=20, one Holm family of 8) | **Proposal**. CI green on `ed756a8`, not approved by Group 1 | runs 40224027381 / 40224027347 |
| CPU as a confirmatory outcome | **Undecided**. The task prompt says RAM and CPU are equal; the north-star proposal says CPU is descriptive | #13 comment 6402306556 |
| Native pilot on final runner/monitor SHAs | **Not run** | none |
| Windows 11 coverage | **None**. Every native result is Windows 10 (19045 on Maxim's PC; one Codex smoke on 26200) | #13 |
| Cross-app runtime | **Not a decision.** Old standing rules put a daemon and cross-app auth out of scope; the north star proposes it; `AGENTS.md` (#26) still says "not a daemon" | this package |

## 5. Gates that block measurements

1. Group 1 approves the protocol (#25 or an amended memory-first version).
2. CI is green on the exact head of the runner and the monitor.
3. A native pilot on the final SHAs passes the predefined quality thresholds (sample coverage, interval distribution, monitor overhead).
4. The time budget is acknowledged (#25 estimates 9–10 h).

None of these has been met for the in-app benchmark. The cross-app methodology in [05](05-memory-methodology.md) adds its own gates (G-X1…G-X5). **No measurement was run for this package.**
