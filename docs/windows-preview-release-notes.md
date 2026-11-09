# Windows developer preview 0.1.0-preview.1

Draft release notes for the Git tag `v0.1.0-preview.1`. The GitHub Release text states the tag's commit SHA. Check that it equals `git rev-parse v0.1.0-preview.1^{commit}`. This file names only the tag, because adding the SHA here would change the tagged commit. The crates are licensed under MIT or Apache-2.0, at your option. They are distributed through Git only and are not published to crates.io.

This preview adds a Rust runtime for sharing application data and work between windows in one Tauri v2 application. For example, two catalog windows can read bounded pages from one Rust catalog. The application decides which views to expose and which windows may call them.

In the included two-window demo, both windows read their pages from one catalog load. The demo's self-test checks this on every CI run: one catalog execution and one cached catalog entry for two WebView windows. This is a count of operations in the demo. It is not a measurement of application memory.

## What is included

- Shared and per-window operation scopes with configurable cache and concurrency limits.
- Typed Tauri commands for bounded responses, using caller identity supplied by the window. Command access is controlled through Tauri capabilities.
- Window-state cleanup on close, runtime shutdown on exit, and fixed IPC error messages that avoid sending internal error details to the WebView.
- A runnable two-window example and a [Windows quick start](../examples/runtime-adapter-demo/README.md) with instructions for a separate Tauri project.

## Preview scope

The verified setup is Windows with Tauri v2 and WebView2. The quick start pins the Git source revision for both runtime crates. The build environment needs read access to that repository. The [preview review record](windows-preview-review.md) tracks the tested toolchain and the checks required for the final revision.

This release covers sharing inside a single application. Cross-application sharing is a separate experiment. This preview makes no claim about total application memory or CPU savings. Those results will be reported only after the A/B/C benchmark protocol has been completed and its report approved.

Minimum Rust versions found by building: 1.88 for `runtime-core` and `shared-runtime`, and 1.90 for the adapter with Tauri 2.12 from the repository lockfile. No MSRV is guaranteed yet.
