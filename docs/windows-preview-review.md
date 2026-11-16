# Windows developer preview review

The preview lets windows in one Tauri v2 application read bounded views of shared Rust data. The demo uses one catalog and exposes pages through typed commands with per-window Tauri capabilities.

The selective preview integration landed on `main` through [#48](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/48) and [#49](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/49). The resulting commit is `089effeaa47099459d7f86954f526a6bb135f7d5`. The earlier stacked PRs below record the implementation history.

Version `0.1.0-preview.1` and license `MIT OR Apache-2.0` are selected.
The repository is private, so the Git preview requires repository read access.
The release tag and GitHub Release are pending.

## Current release evidence

- Hosted Windows and Ubuntu checks passed on the exact merge SHA `089effe` in [push run 42701484542](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/42701484542). They also passed on current main `7244a5cbccbe37a96ac67c69f374d9de383eb2d5` in [push run 43090268756](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/43090268756). Both matrix jobs were checked directly; a PR-only run listing must not be used to infer that push CI is absent.
- A clean external consumer built in Release mode from Git revision `089effe` on Windows build 26200 with Rust 1.99.1 and Tauri 2.12.5. The self-test verified one catalog execution, one cache entry, refusal after shutdown and empty caches. [Recorded evidence](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/49#issuecomment-6751799764).
- The tag-aware consumer script at `0db99ac` passed missing-tag and mismatched-tag refusals in PowerShell 5.1 and 7. An isolated local annotated test tag resolved all three runtime packages to the same commit and passed the native Release self-test. This validates the tag installation path before testing the final remote release tag.
- Main `7244a5c` passed 140 Windows Release unit/integration tests and three doctests, workspace formatting and Release Clippy with warnings denied. A clean external consumer also passed the native Release self-test on that SHA. [Exact-SHA evidence and hashes](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/56#issuecomment-6806361909). These results do not validate later source changes.

## Remaining gates for the Git preview

The queued-view lifecycle bug was reproduced after the checks above. [Fix #66](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/66) is a separate candidate based on `7244a5c`; the fix has not landed on main. Its [review record](window-view-lifecycle-review.md) documents the failed pre-fix regression, behavior, compatibility notes and local checks. Treat it as a release issue requiring review and verification rather than reusing earlier main results.

| Gate | State / required evidence |
|---|---|
| Shared data, bounded views, adapter and typed capabilities | Implemented on main; earlier exact-SHA integration evidence above |
| Queued-window cleanup | #66 in review; local core/runtime tests pass; inspect generation separation and `View::source` timing |
| Final candidate verification | After review, record the chosen SHA and run full Release workspace tests/Clippy, native close/reopen with queued views, and a clean external consumer on that SHA |
| Hosted CI for final candidate | Must actually pass. #66 run 43507493106 never started job steps; its Windows annotation reports account payment/spending-limit problems |
| Tag and GitHub Release | Pending a separate publication decision after candidate checks; then verify remote peeled SHA, tag consumer and tag CI |
| Distribution access | Repository remains private; Git consumers need read access. Changing visibility is a separate decision |
| Memory/CPU claims | No general saving claim. The descriptive pilot is in #64; new daytime diagnostics were under competing game load and cannot validate a performance effect |
| Registry and cross-app work | Separate later tracks; neither is required to finish this Git developer preview |

Initial #66 checks were limited to library tests while the operator was gaming. After CS2 was confirmed closed, the expanded Debug native queued close/reopen self-test passed on `11f2a31`; see the linked lifecycle record for exact evidence and the retained Chromium teardown diagnostic. This is functional evidence, not a performance comparison. The full Release and clean Git-consumer gates still require their own candidate evidence. Do not repeatedly dispatch CI while the known account restriction prevents jobs from starting.

## Verification

- Source revision: `eabf33639ead8544dbd78fc0fd8fa0b7342ece9f` ([adapter security follow-up](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/42)).
- Windows Release build with Rust and Cargo 1.99.1 succeeded. The native demo self-test passed with real WebViews and checked typed IPC, capability denial, invalid and oversized input, window state cleanup, and shutdown.
- The same demo built in a separate Cargo workspace with both runtime dependencies pinned to the Git revision and an independently generated lockfile. Its native self-test reported `passed: true`, `refusedAfterExit: true`, and `cachesEmptyAfterExit: true`.
- [Quick start and Git dependency example](../examples/runtime-adapter-demo/README.md).
- The [external consumer check script](../examples/runtime-adapter-demo/Test-GitConsumer.ps1) reproduced the Windows Release build and native self-test from a fresh temporary project and target directory using cached Git and registry dependencies.
- Workspace formatting passed. On Windows, Release Clippy passed with warnings denied for all targets of the three preview crates. At preview commit `dca9464`, the three crates passed 106 Release tests together: `runtime-core` (59), `shared-runtime` (28 integration tests), and `shared-runtime-tauri` (19 unit tests). The adapter's three doctests passed in an earlier run.
- The Windows Release IPC suite for the demo passed all nine tests. It covers a catalog shared across windows, per-window state, capability checks, request validation, fixed error envelopes, and shutdown.
- At `b337ac4`, the view deadline regression reproduced on the previous implementation. After the fix, the runtime and adapter passed all 47 Release tests, formatting and Clippy. A fresh Windows Release build of the demo passed the native WebView self-test, including refusal of calls and cache cleanup after exit. The checkout remained clean.
- With the call and cache fixes in `0d453d9`, the three libraries and demo passed 126 Release tests and three doctests on Windows build 26200 with Rust and Cargo 1.99.1. The expanded native demo passed three consecutive runs: both WebViews requested different pages over IPC, the catalog executed once and kept one cached entry, and shutdown refused later calls and cleared the caches.
- At `660bd5b`, 132 Windows Release tests passed. The two concurrency stress tests covered 256,000 requests and invalidations across four seeds without reporting a violation. Three native demo runs passed, and an offline Release check passed for the three extracted crate archives using local Cargo patches for the two internal dependencies.
- At `74ab576db1d04a6bae8e47c2f488e5208d9969a0`, the external consumer script extracted the demo and built it in a fresh workspace with a newly generated lockfile. All three runtime crates resolved to that exact Git SHA. The native report showed one catalog execution, one cached catalog entry, window cache entries dropping from two to one, refusal after exit and empty caches after exit. A temporary Git URL rewrite supplied the candidate from the local repository. Repeat against the intended distribution source before publishing.
- The same candidate passed 133 Windows Release unit and integration tests, formatting and Clippy for all targets of the three preview libraries and demo.
- At `71953ac`, the stricter consumer check rejected mismatched revisions before building. A fresh matching-revision build passed the lockfile and native checks with a temporary local Git URL rewrite.

The cache expiry optimization in `be2ad3b` was checked with an isolated Windows microbenchmark against `3604548`. The benchmark filled a cache with 20,000 entries and called `PolicyCache::stats` 10,000 times per sample, keeping all entries live. Across three samples, median time was about 297 ms before and 0.32 ms after for `Forever`, and about 822 ms before and 0.79 ms after for a 120-second TTL. Both variants used the same driver and Rust 1.99.1 with `rustc -O`. These timings isolate the cache statistics path.

## Before publishing

- [x] Integrate the runtime and adapter stack, including the IPC error fix, through #48.
- [x] Apply `MIT OR Apache-2.0`, license files and crate metadata through #49.
- [x] Select version `0.1.0-preview.1` and Git tag `v0.1.0-preview.1`, with `publish = false`.
- [ ] Select the final source revision after release-check changes, verify CI at that revision, and check that the remote tag resolves to it.
- [ ] Verify that an account with the intended access can install through the tag.
- [ ] Repeat the standalone Release build and native self-test on the selected release revision. Record the tested Windows and Rust versions. Document an MSRV only after validating it.
- [ ] Review installation instructions, the scope of the preview, and the [draft release notes](windows-preview-release-notes.md). The preview covers sharing within a single app. The cross-app broker is a separate experiment.

## Earlier integration review

The following table records the earlier stacked integration proposal. The selected integration is #48.

| Order | PR | Reviewed head |
| --- | --- | --- |
| 1 | [Core cache budget #34](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/34) | `d8106fa` |
| 2 | [Shared runtime #35](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/35) | `b65177d` |
| 3 | [Tauri adapter #37](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/37) | `ec21d7a` |
| 4 | [Operation error sanitization #39](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/39) | `d4314b4` |
| 5 | [Fixed adapter error envelopes #42](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/42) | `eabf336` |

For the final release revision, retain `revisions.json`, `Cargo.lock` and `self-test.json` from the external consumer check alongside the CI evidence.

On November 8, 2026, all five PRs were open and their recorded head SHAs matched the table. GitHub Actions reported success on those heads. PRs #34, #35, #37 and #39 were drafts. PR #34 targeted `claude/project-thread-qzzw0x` at `772155d`, which was 21 commits ahead of `main` at `4bf7da3`. Review the Runtime Lab and core changes in that base before choosing which history to integrate. The local candidate `74ab576` already contains #42's head and the preceding stack in its history.

The incremental bundle for `74ab576` was imported into a new repository containing only its prerequisite history through `eabf336`. The imported ref matched `74ab576` and Git's connectivity check passed.

An isolated alternative was assembled from `main` at `4bf7da3`. It retains `main`'s `runtime-ipc` and overlays only `runtime-core`, the two shared runtime crates, the adapter demo and the generated-file line-ending rule from `74ab576`. The workspace manifest adds the three preview members and the Release profile, and Cargo updates the candidate lockfile for the resulting workspace. Runtime Lab, its frontend dependencies and its workflow changes are outside this prototype.

The prototype passed 140 Windows Release unit and integration tests, including seven tests from `main`'s existing `runtime-ipc`. Its native WebView2 self-test passed with one catalog execution and one cache entry. The extracted source archive resolved exactly five workspace members with locked offline Cargo metadata. If this base is selected, create a review branch from `main`, add the adapter CI and an IPC regression check, then verify the resulting commit through the distribution source.

The [A/B/C measurement track](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/36) validates memory and CPU separately from this integration test. Include numerical savings in release materials only after the measurement report supports them.

The scenario description in #36 identifies #35 as the framework source for arm C. At `64cae6a` (#47), the catalog manifest still resolves the framework through a path dependency on its own tree, and its README identifies the #35 revision. Before a run intended to validate the preview, pin the chosen preview revision and record it in the frozen manifest. Compare A, B and C with the same workload and keep the RAM validity rules when applying the Job Object CPU changes from #45 and #46. The dry-run tooling in #47 prepares the schedule and manifest without starting the workload.

## crates.io readiness

The Git preview uses workspace paths internally and exact `0.1.0-preview.1` requirements between runtime crates. A registry release requires a separate decision. The earlier packaging checks below used version `0.1.0`. For a registry release, the dependency order is `runtime-core`, `shared-runtime`, then `shared-runtime-tauri`. Running `cargo package --offline --allow-dirty --no-verify -p runtime-core -p shared-runtime -p shared-runtime-tauri` produced all three archives in that earlier check.

Cargo 1.99.1's built-in package verification compiled the unpacked `runtime-core` archive, then stopped at `shared-runtime` because its temporary registry reported no hash for `runtime-core v0.1.0`. The same failure reproduced with a fresh target directory.

As a separate check, all three archives were extracted outside the repository. An offline Release `cargo check` of the extracted adapter passed with Cargo patches pointing its two internal dependencies to the other extracted archives. This checks the packaged source and manifest dependency chain. Built-in package verification and crates.io availability remain open.
