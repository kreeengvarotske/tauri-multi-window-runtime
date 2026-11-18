# Stable 0.1.0 guide

This guide defines the 0.1 API and support policy, not publication status.
Use only a [verified published release](https://github.com/kreeengvarotske/tauri-multi-window-runtime/releases/tag/v0.1.0).
The existing preview tag stays unchanged. Publication requires
[exact-source qualification](stable-release-qualification.md).

## Installation and compatibility

After verified `v0.1.0` publication, use the same tag for both dependencies and
retain the application's resolved Cargo.lock:

```toml
shared-runtime = { git = "https://github.com/kreeengvarotske/tauri-multi-window-runtime.git", tag = "v0.1.0" }
shared-runtime-tauri = { git = "https://github.com/kreeengvarotske/tauri-multi-window-runtime.git", tag = "v0.1.0" }
```

| Component | Support/qualification baseline |
| --- | --- |
| Rust | 1.99.1, the conservative declared minimum, pinned in CI. Older compilers are not qualified |
| Native target | Windows x64/MSVC, locally checked on build 26200 with WebView2 157.0.4341.46 |
| Tauri | Repository-pinned 2.12.5 and independent 2.12.6; final receipts record resolved versions |
| Frontend client | Browser JavaScript and optional TypeScript declarations; Node 22/TypeScript 6.0.3 are verification tools, not runtime dependencies |
| Additional CI | Ubuntu checks supplement Windows qualification; no Linux/macOS/mobile production support claim |
| Distribution | Public Git and local client directory/tarball; MIT OR Apache-2.0; no registry publication or installer |

The compiler minimum is a tested support policy, not proof that every line needs
Rust 1.99.1. Lowering it requires compiler/dependency CI. Unlisted configurations
must not be described as qualified.

## Compatibility contract

`0.1.x` patches preserve public Rust signatures, required config fields,
exhaustive enum matching, documented error codes and JSON-byte command behavior.
Changes requiring source edits or raising the supported Rust baseline require
`0.2.0`. Security migrations are documented. Check error codes rather than
diagnostic wording; applications own their command schemas.

The runtime manages application-owned shared/per-window data, coalesced work,
weighted caches, admission, deadlines and cleanup. Register typed operations and
views, expose commands through capabilities, and derive caller identity from
the injected window. See the [integration guide](../examples/runtime-adapter-demo/README.md),
[adapter guide](../crates/shared-runtime-tauri/README.md) and [recipes](recipes.md).

Weights do not cap process RAM; Arc holders can retain evicted values.
Synchronous work is cooperative; views must charge before allocating and remain
bounded. Scope isolation is not authorization. The optional client validates
wire JSON/bytes, not application response schemas; it adds no retry, frontend
cache, cancellation layer or generated types.

## Qualification observations

Public-API churn covers 1,000 reopen cycles, 1,000 distinct temporary window
labels and 256 cancelled initializers with retries. Weak references check release
of outputs/labels, alongside balanced counters and reusable capacity. These are
repetition checks, not an OS-memory benefit benchmark.

Independent fixtures exercise notes backends and a second real Tauri desktop
app alongside the catalog demo. Desktop checks include invalid/forged requests,
worst-case JSON escaping, cache reuse and shutdown. The bounded elapsed-time
IPC soak records actual duration/calls and strict Job accounting in its receipt.

Chromium unregister-class diagnostic 1412 appeared with successful Debug and
Release exits and no leftover processes; async exit also emitted it. Cause is
unconfirmed, no fix is claimed and raw logs are retained. The older
[Tauri discussion](https://github.com/orgs/tauri-apps/discussions/3555) is context,
not proof about this run. Functional/cleanup failures still block release.

The adopted MSVC VCTIP build-only exception stays narrow: raw combined FAIL
remains FAIL; installation/build identity and strict same-artifact application
cleanup must pass. No tools are killed by SDK code or system settings changed.
General RAM/CPU gains, Chromium deduplication, production cross-app sharing and
generated bindings remain deferred.
