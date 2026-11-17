# Stable 0.1 release qualification

The published `v0.1.0-preview.1` remains unchanged. Stable `0.1.0` requires its
own source revision, evidence and release tag; the preview is not relabelled.

## Supported contract

The first stable release covers one application on Windows, typed Rust
operations/views and the Tauri adapter, with the optional JSON command client.
Applications choose explicit limits, validate access and requests, and report
honest cache weights. Scope isolation is not authorization. Budgets cover
reported cache weights and charged responses, not total process RAM. Synchronous
work and externally held Arc values retain the limitations in the API docs.

Within `0.1.x`, patch releases preserve public Rust signatures, required config
fields, documented error codes and command-client request/response behavior.
Changes requiring consumer source edits, including new exhaustive enum variants
or required config fields, require `0.2.0`. Security fixes must state any required
migration explicitly. TypeScript declarations do not perform schema validation.

Compatibility evidence is version-specific. The preview verified Windows build
26200, Rust 1.99.1, WebView2 157.0.4341.46, repository-pinned Tauri 2.12.5 and an
independent Tauri 2.12.6 consumer. These are observations, not a claim that every
Windows, Rust, Tauri or WebView2 version works. Stable release notes must give
their actual tested matrix and identify unqualified platforms. No lower MSRV
is established by the preview's newer compiler.

## Required evidence

| Gate | Acceptance |
| --- | --- |
| Regression and churn | Workspace tests, strict Clippy/docs and client checks pass; repeated reopen and cancellation tests preserve ownership, capacity and balanced outcomes |
| Native lifecycle | Real WebView commands, capabilities, old/new window isolation, overload and shutdown pass; owned application process accounting reconciles with zero leftovers and no forced cleanup |
| Independent catalog consumer | Fresh non-workspace project and lock resolve all runtime crates to the selected source; bounded catalog requests and window state pass |
| Independent second consumer | A different application model integrates operations, bounded responses, error handling and lifecycle without workspace path dependencies; own lock and build evidence |
| Compatibility and install | Record actual toolchain/platform/dependency versions; exercise documented Git installation anonymously |
| Final source and tag | Green exact-source main and tag CI; immutable annotated stable tag; matching-SHA external consumer and strict native cleanup |
| Distribution | Review release text, publish the stable release with verified downloadable evidence and checksums, then record completion |

The two churn tests run through the public API. One performs 1,000 reopen cycles,
checks that Weak references to removed outputs expire, preserves another window's
cached source, and verifies cache/counter bounds. Another cancels and retries
256 initializers with deterministic gates, checking capacity reuse, released
outputs and exact outcomes. They run in normal wall-clock time with a bounded
cancellation test. These are repetition tests, not hours of uptime or an OS RAM
benchmark; do not describe their duration as a long-running soak.

The adopted MSVC VCTIP build-only exception remains explicit: raw combined-job
FAIL stays FAIL; source/build identity and strict same-artifact application
cleanup must pass. A different or application leftover is not covered.

RAM/CPU benefit research, Chromium deduplication, a production cross-app broker,
generated bindings and registry publication are not stable-release gates.

## Current execution record

- Reopen/cancellation churn: both tests passed locally against the preview
  runtime source (no production-code change).
- The independent notes backend consumer passed from a fresh temporary project,
  target and lock at `bf6b66c2241a10fa92f402b07d4ab86b1f3dede9`. Both Git package
  identities were checked. CI repeats it at the actual PR/push source revision.
  It is not a second native Tauri application and does not close that coverage gap.
- Remaining stable gates are pending; this document does not declare `0.1.0`
  qualified or published. Exact receipts replace pending status as work finishes.
