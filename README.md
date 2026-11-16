# tauri-multi-window-runtime

Windows developer preview: [v0.1.0-preview.1](https://github.com/kreeengvarotske/tauri-multi-window-runtime/releases/tag/v0.1.0-preview.1).

Build Tauri v2 applications with shared Rust data, cached/coalesced operations,
bounded responses and window lifecycle cleanup. The runtime provides explicit
cache budgets, queue limits, deadlines and shutdown handling so applications
can reuse that infrastructure.

Start with the [two-window demo and backend quick start](examples/runtime-adapter-demo/README.md).
The optional [JavaScript/TypeScript command client](packages/runtime-client/README.md)
handles the adapter's JSON-byte IPC protocol without frontend framework bindings.
The [runnable recipes](docs/recipes.md) cover shared data, window isolation and
coalesced file IO. The [published preview completion record](docs/windows-preview-release-record.md)
records the immutable tag, final source, verification and release receipts.
The [release packet](docs/windows-preview-release-packet.md) preserves the earlier review.

The first developer preview targets Windows. General RAM/CPU savings are not
claimed or required to ship this preview. Chromium-process deduplication and
cross-application sharing are separate research. The current release scope is
recorded in the [completion plan](docs/plans/2026-11-15-developer-preview-focus.md).
