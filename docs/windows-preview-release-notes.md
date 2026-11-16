# Windows developer preview 0.1.0-preview.1

Draft, updated November 16, 2026. Tag `v0.1.0-preview.1` does not exist yet.
The final source revision is pending integration of the runtime-core fix and
final verification. Merge, tag creation and GitHub Release publication require
separate decisions. The [release packet](windows-preview-release-packet.md)
tracks these gates.

The GitHub Release text must state the tag's commit SHA. Check that it equals
`git rev-parse --verify 'v0.1.0-preview.1^{commit}'`. Keep the quotes: without
them, PowerShell passes `{commit}` as a separate argument. The final tag SHA
belongs in the Release text: recording a commit's own SHA here would change
that commit. The crates
are licensed under MIT or Apache-2.0, at your option. Distribution is through
the public Git repository; crates.io and npm registry publication are outside
this preview.

This preview adds a Rust runtime for sharing application data and work between windows in one Tauri v2 application. For example, two catalog windows can read bounded pages from one Rust catalog. The application decides which views to expose and which windows may call them.

In the included two-window demo, both windows read their pages from one catalog
load. Its native self-test checks one catalog execution and one cached catalog
entry for two WebView windows. These operation counts do not measure whole-app
memory or CPU savings.

## What is included

- Shared and per-window operation scopes with configurable cache and concurrency limits.
- Typed Tauri commands for bounded responses, using caller identity supplied by the window. Command access is controlled through Tauri capabilities.
- Window-state cleanup on close, runtime shutdown on exit, and fixed IPC error messages that avoid sending internal error details to the WebView.
- Explicit projection admission and queue limits, with the existing `OVERLOADED` error envelope when capacity is exhausted. See the [configuration and migration notes](projection-queue-review.md).
- An optional, dependency-free [JavaScript/TypeScript command client](../packages/runtime-client/README.md). The application supplies Tauri `invoke` and its request/response types; Rust retains validation and capabilities. The client adds no retries, frontend cache or cancellation layer.
- [Three runnable Rust recipes](recipes.md): a shared source with bounded pages, per-window state and close/reopen cleanup, and coalesced file IO with bounded admission and no retained output cache.
- A runnable two-window example and a [Windows quick start](../examples/runtime-adapter-demo/README.md) with instructions for a separate Tauri project.

## Preview scope

The supported platform for this preview is Windows with Tauri v2 and WebView2.
The public repository permits anonymous Git installation. Use one reviewed Git
revision for all runtime dependencies, then use the verified release tag after
it is created. The optional client installs from a reviewed checkout or a local
package tarball. The [preview review record](windows-preview-review.md) tracks
the observed toolchain and required final checks.

This release covers sharing inside a single application. A production
cross-application broker and Rust-to-TypeScript code generation remain
deferred. Application code declares operations, access checks, limits and
response types. This preview makes no claim about total application memory or
CPU savings. The frozen pilot keeps its original protocol and findings;
further performance research is optional follow-up work.

Minimum Rust versions found by building: 1.88 for `runtime-core` and `shared-runtime`, and 1.90 for the adapter with Tauri 2.12 from the repository lockfile. No MSRV is guaranteed yet.

## Verification status before publication

The external consumer at superseded `3e132fa` passed anonymous source access,
Release compilation and native assertions. Its exact executable and lock also
passed a separate strict application Job with no leftovers or forced cleanup.
The combined build/application Job **failed** cleanup because one measured
MSVC VCTIP helper remained. Empty Rust compilation reproduced that helper
without Cargo, Tauri or the SDK. Acceptance of this toolchain cleanup exception
remains a separate release-policy decision; the failed result is preserved.

A newly confirmed P2 in `NoStore` and overweight-result key cleanup is fixed in
open [PR #74](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/74)
at `0267a775679f4f554151ca4997520d55dfb74082`, pending integration. Both
regressions failed before the fix; 82 core tests and one doctest passed after
it. Local checks also passed 171 default-profile (Debug) workspace
unit/integration tests and four doctests, 12 JS tests, strict TypeScript
checking and the demo-sync check. Final Release checks, required CI and a fresh
consumer including #74 remain pending. These draft notes do not declare the
preview ready.
