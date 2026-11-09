# Windows developer preview review

The preview lets windows in one Tauri v2 application read bounded views of shared Rust data. The demo uses one catalog and exposes pages through typed commands with per-window Tauri capabilities.

This review branch evaluates the selective integration on `main` at `4bf7da3`. It preserves the existing `runtime-ipc` source and adds the preview libraries, demo and adapter CI without importing Runtime Lab. The stacked PRs below record the source history and remain available as an alternative integration path.

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

- [ ] Review and integrate the runtime and adapter stack, including the [IPC error fix](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/42).
- [ ] Agree on a repository license and apply it to the distributed crates. Proposed: MIT OR Apache-2.0, with `LICENSE-MIT`, `LICENSE-APACHE` and `license` metadata in every workspace crate. The repository owner decides.
- [ ] Choose the preview version and source revision. Proposed: crate version `0.1.0-preview.1`, Git tag `v0.1.0-preview.1` on the commit on `main` that CI tested. `publish = false` until a crates.io release is decided. Verify that an account with the intended access can fetch the tag and that all examples pin it.
- [ ] Repeat the standalone Release build and native self-test on the selected release revision. Record the tested Windows and Rust versions. Document an MSRV only after validating it.
- [ ] Review installation instructions, the scope of the preview, and the [draft release notes](windows-preview-release-notes.md). The preview covers sharing within a single app. The cross-app broker is a separate experiment.

## Integration and release verification

The preview branch is based on the reviewed adapter security revision. Integrate the prerequisite stack in dependency order, checking the base and required CI for each PR after its parent lands.

| Order | PR | Reviewed head |
| --- | --- | --- |
| 1 | [Core cache budget #34](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/34) | `d8106fa` |
| 2 | [Shared runtime #35](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/35) | `b65177d` |
| 3 | [Tauri adapter #37](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/37) | `ec21d7a` |
| 4 | [Operation error sanitization #39](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/39) | `d4314b4` |
| 5 | [Fixed adapter error envelopes #42](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/42) | `eabf336` |

Check #34's base against the intended integration branch before starting. After #42 lands, review the preview branch delta against the integrated stack and apply it without replaying the prerequisite PRs. Verify the final revision in a clean checkout with formatting, Clippy, Release tests and the native demo self-test. Repeat the external consumer check with the same final revision for the tracked demo and the Git dependencies. Retain `revisions.json`, `Cargo.lock` and `self-test.json` with the release evidence.

On November 8, 2026, all five PRs were open and their recorded head SHAs matched the table. GitHub Actions reported success on those heads. PRs #34, #35, #37 and #39 were drafts. PR #34 targeted `claude/project-thread-qzzw0x` at `772155d`, which was 21 commits ahead of `main` at `4bf7da3`. Review the Runtime Lab and core changes in that base before choosing which history to integrate. The local candidate `74ab576` already contains #42's head and the preceding stack in its history.

The incremental bundle for `74ab576` was imported into a new repository containing only its prerequisite history through `eabf336`. The imported ref matched `74ab576` and Git's connectivity check passed.

An isolated alternative was assembled from `main` at `4bf7da3`. It retains `main`'s `runtime-ipc` and overlays only `runtime-core`, the two shared runtime crates, the adapter demo and the generated-file line-ending rule from `74ab576`. The workspace manifest adds the three preview members and the Release profile, and Cargo updates the candidate lockfile for the resulting workspace. Runtime Lab, its frontend dependencies and its workflow changes are outside this prototype.

The prototype passed 140 Windows Release unit and integration tests, including seven tests from `main`'s existing `runtime-ipc`. Its native WebView2 self-test passed with one catalog execution and one cache entry. The extracted source archive resolved exactly five workspace members with locked offline Cargo metadata. If this base is selected, create a review branch from `main`, add the adapter CI and an IPC regression check, then verify the resulting commit through the distribution source.

The [A/B/C measurement track](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/36) validates memory and CPU separately from this integration test. Include numerical savings in release materials only after the measurement report supports them.

The scenario description in #36 identifies #35 as the framework source for arm C. At `64cae6a` (#47), the catalog manifest still resolves the framework through a path dependency on its own tree, and its README identifies the #35 revision. Before a run intended to validate the preview, pin the chosen preview revision and record it in the frozen manifest. Compare A, B and C with the same workload and keep the RAM validity rules when applying the Job Object CPU changes from #45 and #46. The dry-run tooling in #47 prepares the schedule and manifest without starting the workload.

## crates.io readiness

The Git preview can use workspace paths. For a registry release, the dependency order is `runtime-core`, `shared-runtime`, then `shared-runtime-tauri`. The local dependency declarations now include matching `0.1.0` version requirements. Running `cargo package --offline --allow-dirty --no-verify -p runtime-core -p shared-runtime -p shared-runtime-tauri` produced all three archives.

Cargo 1.99.1's built-in package verification compiled the unpacked `runtime-core` archive, then stopped at `shared-runtime` because its temporary registry reported no hash for `runtime-core v0.1.0`. The same failure reproduced with a fresh target directory.

As a separate check, all three archives were extracted outside the repository. An offline Release `cargo check` of the extracted adapter passed with Cargo patches pointing its two internal dependencies to the other extracted archives. This checks the packaged source and manifest dependency chain. Built-in package verification and crates.io availability remain open.
