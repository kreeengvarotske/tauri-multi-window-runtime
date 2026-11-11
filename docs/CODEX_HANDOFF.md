# Codex handoff — tauri-multi-window-runtime

**Snapshot date:** 2026-10-25  
**Repository:** https://github.com/kreeengvarotske/tauri-multi-window-runtime (private)  
**Default branch at snapshot:** `main` @ `4bf7da3baabbd764991104ac285c419b535ecc67`  
**Handoff branch:** `codex/handoff-20261025` (this document is a dated guide; refresh all live refs before acting)

> Important: this is not a transfer of ownership or approval to merge. The live GitHub repository, CI, and exact head/base SHAs supersede this snapshot.

## Project in one page

The project is a Tauri + Rust runtime that shares services/cache/coalescing between multiple WebView windows in a **single application process**. It is not a global runtime daemon for unrelated applications.

The runtime core and its frontend/IPC demo, baseline benchmark, Runtime Lab benchmark, Windows process monitor, and symmetric plain/runtime benchmark are currently spread across multiple unmerged, sometimes stacked pull requests. `main` is intentionally not the complete working tree of all open PRs. For example, at the snapshot `main` has the root Cargo workspace and runtime-core/runtime-ipc crates; it does not yet contain the active symmetric benchmark or the frontend integration in its PR branch.

## Team operating model

- **Group 1:** project owner + independent architecture/review decisions.
- **Group 2:** Maxik + Claude Code, implementation and testing.
- **Codex:** additional independent auditor/implementer/coordinator. Preserve work already performed by both groups; do not treat a fresh Codex workspace as the only source of truth.
- Use Issue [#13](https://github.com/kreeengvarotske/tauri-multi-window-runtime/issues/13) as the project coordination log. Post concise factual updates only for substantive milestones, with the exact SHA and CI/native evidence. Do not duplicate an update already recorded.

## PR map at snapshot

Always refresh these links, refs, and statuses before changing anything.

### Runtime / frontend stack

`main → PR #2 → PR #7 → PR #8 → PR #12 → PR #14`

- [PR #2](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/2): head `feat/frontend-integration` @ `37d82d5821189df2dda058e496f6e57700d885b0`; base `main` @ `4bf7da3baabbd764991104ac285c419b535ecc67`.
- [PR #7](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/7): frontend events/stats/TTL/two-window integration; base PR #2 head `37d82d5...`.
- [PR #8](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/8): key-scoped cache invalidation; stacked on #7.
- [PR #12](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/12): concurrency regression tests; stacked on #8.
- [PR #14](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/14): TaskCoalescer completed-operation race fix; head `772155def9f4baf232f43864a80add7cd3c5192c`, stacked on #12. This is the current Core base chosen for symmetric benchmark PR #20.

Do not flatten or retarget this stack. Do not merge any PR without explicit approval.

### Benchmark and Windows monitor work

- [PR #16](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/16): Runtime Lab handshake/drain baseline; branch `claude/lab-bench-protocol` @ `ea8014b91f53bb89b71a79d91885b3e0ddc45cc7`, base `benchmarks/automated-runtime-suite` @ `ee5f47555287b6af8d7a6015a25d8f52d8148d7c`.
- [PR #17](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/17): vanilla baseline handshake/release profile/Cargo.lock; branch `claude/baseline-handshake` @ `1cb4bc0b278dff1df71e31b94830ac35e7c4135d`, base `benchmarks/vanilla-tauri-baseline` @ `f73fe04335ebbccca4daf3d569637a51a6d97e94`.
- [PR #18](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/18): current monitor branch `claude/monitor-units` @ `1d57f6f68eb745ab86f16e3e6e23d137808a300a`, base `benchmarks/windows-process-monitor` @ `1f71b840a920cde4aa92bb25a87060bae85742da`. Includes the fix that unreadable CPU must remain blank, not zero.
- [PR #24](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/24): clean-base monitor follow-up based directly on #18 @ `1d57f6f...`; head `6952886fa938795dcf85a8de0c2b2c55d1ac86ba`. Windows PowerShell hosted workflow [#40220356939](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/40220356939) passed: deterministic empty/non-finite/wrong-unit tests plus 0.2 s sampling smoke. This is **not** a native run on the developer's machine and does not establish Windows 11 coverage.
- [PR #19](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/19): stale-base duplicate, now closed/unmerged; preserve its branch/history but do not revive it instead of #24.
- [PR #20](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/20): symmetric benchmark S1–S4; head `claude/symmetric-bench` @ `9c40dd562849bf0883e7377b31200967e19e0277`; base `claude/project-thread-qzzw0x` = PR #14 head `772155def9f4baf232f43864a80add7cd3c5192c`. Full CI at this SHA passed: general run [#40218090430](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/40218090430), Windows Release [#40218090495](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/40218090495). Do not infer resource savings from CI or the short S2 smoke.
- [PR #23](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/23): metric-quality follow-up; head `review/symmetric-metric-quality-20261025` @ `3f70b7d63628db7cec78a5fd927d0ac136992266`; base #20 exact head `9c40dd5...`. General CI and the full symmetric Windows Release workflow passed at this exact head: [general #40219219157](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/40219219157), [symmetric #40219219142](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/40219219142). It adds finite numeric parsing and metric-specific completeness handling; review the tests and exact diff before integrating.
- [PR #25](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/25): fixed-N confirmatory protocol proposal; at snapshot head `review/fixed-n-protocol-clean-20261025` @ `ed756a826688f754ef0a2aed63dc738c2fb12eb0`, base PR #23 @ `3f70b7d63628db7cec78a5fd927d0ac136992266`. General CI [#40224027381](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/40224027381) passed; symmetric Windows Release [#40224027347](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/40224027347) was still running at the release-build step. **Refresh current head/status before acting.** PR #25 proposes one predeclared analysis at N=20 pairs per scenario/profile, without adaptive interim looks.

PRs #21 and #22 are closed, unmerged, stale-base review duplicates. They must not be treated as merged; their useful findings have been addressed/ported selectively into #20/#23/#25. Do not delete branches.

## Evidence and limitations

- Native reports available in this project snapshot concern **Windows 10 Home 22H2 (build 19045)** and Windows PowerShell 5.1, unless a report explicitly says otherwise. Do not call these Windows 11 results.
- The monitor's 0.2 s WMI sampling profile has measurable observer CPU overhead. Keep CPU and RAM profiles separate and report the actual interval and monitor CPU seconds.
- Memory peak metrics are maxima of captured samples, not guaranteed physical peaks.
- A green hosted workflow validates that workflow on its SHA; it is not a substitute for the full native paired measurements on a developer machine.
- The pilot pairs are exploratory; do not make a performance-winner claim from them.

## Blocking decisions / next work

1. **Audit live state first.** Re-fetch PR #20/#23/#24/#25, issue #13, exact head/base SHAs, changed files and CI status. This snapshot may be stale.
2. **Finish and review PR #25.** Require the entire Windows Release workflow (PowerShell 7 + Windows PowerShell 5.1, Clippy, Rust tests, Release builds, short S2 smoke) and general CI green at the *current exact head*. Review schedule completeness, metadata equality across Cpu/Ram, invalid pairs, and fixed-N behavior. The fixed-N design is a proposal until Group 1 approves it.
3. **Resolve #23/#20 integration without conflict.** Compare the exact three-file diff and regression test from #23 with #25/#20; avoid copying the same change twice. Keep the existing stack intact. Verify `MetricExcludedPairs`, full diagnostics coverage, and no averaging of partial secondary samples.
4. **Native monitor verification.** Run PR #24's exact current head on the available Windows machine using Windows PowerShell 5.1; record `git rev-parse HEAD`, OS build, PowerShell version, stdout/stderr, 0.2 s and default 1 s row counts, min/median/max intervals, missing counters, and unit-check output. Windows 11 must be tested separately if claimed.
5. **Benchmark pilots only until approval.** Do not start the fixed-N confirmatory series until Group 1 explicitly approves the protocol, exact-head CI is green, the native pilot and metadata checks pass, and the time budget is acknowledged (PR #25 estimates a long multi-hour run).
6. **Stage 10 remains memo-only.** No changes to `RuntimeDebugStats`, `computedAtMs`, capabilities, Rust IPC, admin cache commands/events, private-data event security, or authorization scope without a separate architecture decision.

## Useful verification commands

Read the actual target ref's manifests/workflows first, then run the commands that exist at that ref. Likely workspace checks at the complete workspace branch include:

- `cargo fmt --all -- --check`
- `cargo clippy --workspace --all-targets --locked -- -D warnings`
- `cargo test --workspace --locked`
- In symmetric benchmark branch: `cargo test -p symmetric-bench --locked`, also `cargo test -p symmetric-bench --locked --features runtime`; frontend `npm ci`, `npm run typecheck`, `npm test`, `npm run build`; run both PowerShell 7 and Windows PowerShell 5.1 synthetic scripts specified in `.github/workflows/symmetric-bench.yml`.

Do not run commands guessed from this list if they do not exist on the selected ref.

## Required completion report

After each step, report:
- what changed and why;
- exact head/base SHA and PR stack;
- CI link(s) and final job status;
- native OS/build/shell and report links, or explicitly “not run”;
- tests and command exit codes actually observed;
- unresolved risks and whether the next phase remains blocked.

No merges, direct edits to another group's branch, force-pushes, history rewrites, branch deletions, or PR base changes without separate explicit permission.
