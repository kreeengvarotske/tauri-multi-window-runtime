# Windows developer preview 0.1.0-preview.1

> Current release: [v0.1.0-preview.1 completion record](windows-preview-release-record.md).
> The pending actions and candidate statuses below are a historical pre-publication
> snapshot; the completion record holds the final SHA, tag, CI and release receipts.

Draft, updated November 16, 2026. Candidate `e0c09b0` is qualified under the
adopted build/runtime policy. Dependency-ordered integration, tag
`v0.1.0-preview.1` and GitHub prerelease publication are authorized and pending
execution. The [release packet](windows-preview-release-packet.md) tracks the
final integrated/tagged identity and completed release receipts. No published
release is asserted here.

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

The fresh consumer at `e0c09b0db5788a83bc89881b0df3682f36dac1fa` passed anonymous
source access, independent installation, the Release build in 5m59s and native
assertions. The unchanged executable and lock passed a separate strict
application Job: 9 NEW / 9 EXIT / active-zero 1, with no timeout, leftovers or
forced cleanup. The combined build/application cleanup remains **FAIL**:
553 NEW / 552 EXIT, one VCTIP leftover and forced owned-Job cleanup.

The release policy adopted November 16 accepts this measured build-toolchain
exception and requires strict application cleanup to pass. Earlier empty Rust
compilation reproduced the MSVC VCTIP helper without Cargo, Tauri or the SDK.
The final run retained process name/creation/parent, not a new image hash. Raw
failed results and attribution limits remain unchanged; this exception adds
no SDK workaround and permits no application leftover.

The `NoStore` and overweight-result key-drop P2 is fixed in
[PR #74](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/74)
at `0267a775679f4f554151ca4997520d55dfb74082` and qualified in the #75 candidate.
Both regressions failed before the fix; 82 core tests and one doctest passed
after it. Debug and Release each passed 171 workspace unit/integration tests
and four doctests. Both Clippy profiles, formatting and Rustdoc with warnings
denied passed, along with 12 JS tests, strict TypeScript, demo-sync, offline
packed installation/import/call and all three recipes. Exact-head
[Windows/Ubuntu CI](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/43967276469)
passed. The [#75 evidence receipt](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/75#issuecomment-6931159120)
records these checks; final main/tag identities and release-action receipts
remain pending execution.

After final-main CI passes, an immutable annotated tag will identify that exact
source. One anonymous tag consumer with a matching SHA will qualify both final
main source and the remote tag. Prerelease publication follows tag CI and the
tag consumer's strict application cleanup pass.
