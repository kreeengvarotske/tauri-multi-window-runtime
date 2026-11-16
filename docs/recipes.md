# Shared runtime recipes

These small Rust examples exercise the runtime without starting Tauri or a WebView.
Run each command from the repository root. They use the existing dependencies and
lockfile, print their results, and assert the behavior described below.

```powershell
cargo run -p shared-runtime --locked --example recipes -- shared
cargo run -p shared-runtime --locked --example recipes -- window
cargo run -p shared-runtime --locked --example recipes -- io
```

Read the [complete example](../crates/shared-runtime/examples/recipes.rs) alongside
the [real two-window Tauri demo](../examples/runtime-adapter-demo/README.md), its
[Rust commands](../examples/runtime-adapter-demo/src/lib.rs), and the
[JavaScript/TypeScript command client](../packages/runtime-client/README.md).

## Shared cached source and bounded pages

The `shared` mode registers one `Catalog` operation and one `CatalogPage` view.
Two trusted callers read the same cached source: `Arc::ptr_eq` confirms that the
Rust output is shared, and counters confirm one execution and one cache entry.
Each caller then requests its own two-item page. The example checks both pages
and rejects a request for three items.

The recipe reserves 4,096 estimated cache bytes for the catalog. A page has at
most two items and 128 charged bytes. `CatalogPage::project` charges each string's
storage before cloning it; the byte measurement includes the string record and
its contents. The fixed response container and IPC serialization need separate
accounting. Projection work visits only the requested page. Cache hits still
build a fresh bounded response for each caller.

The direct source calls illustrate Rust ownership and pointer equality. In a
Tauri app, expose the bounded view through a command so the WebView receives a
page instead of the entire source.

## Per-window state and reopening a label

The `window` mode registers a `PerWindow` operation with a 128-byte cache budget.
Calls from `main` reuse one value; `inspector` gets a different value. The CLI
simulates window destruction by calling `runtime.forget_window(&main)`, checks
that only one cache entry remains, and reopens the same label. The reopened
window gets a fresh generation while `inspector` keeps its existing value.
Forgetting both windows leaves no cached entries.

The application must connect cleanup to actual window destruction. The Tauri
adapter's plugin does this in the real demo. Window scope separates cached
state; capabilities and command validation determine access. Cleanup removes
the runtime's cache ownership: an `Arc` already held by application code can
keep the old output alive until that holder drops it.

## Concurrent file IO without retaining a cache

The `io` mode creates a tiny fixture in the operating system's temporary
directory with `create_new`. Its filename has a recipe-specific prefix, process
ID, timestamp, and collision suffix. It accepts no file paths from the CLI. The
guard owns only that newly created file and removes only that file, including a
best-effort fallback on early return. No directory is removed.

Fixture creation, reads, and normal removal use `tokio::task::spawn_blocking` so
filesystem calls run away from the async executor. Two concurrent same-key
calls run in a biased `tokio::join!`; an explicit `yield_now` in the operation
lets both register before the read starts. Assertions check one actual read,
one executed call, one coalesced call, and a shared output pointer. No sleeps or
network are used.

`ReadFixture` uses `CachePolicy::NoStore` and reserves zero cache bytes. A later
call performs a second read, proving that concurrent coalescing works without
retaining a completed cache entry. The fixture path is owned by the operation;
its unit parameters mean both callers request the same validated resource.
Production file commands should validate paths and access before constructing
operation parameters and bound input size before loading data. This recipe's
input is bounded by the tiny file it creates itself.

## What the application supplies

All operation, request, response, and view types are manually declared in Rust.
These examples use one runtime per mode and explicit sample limits: two active
operations, two queued operations, two active projections, two queued
projections, a five-second call deadline, and a one-second shutdown grace. Each
mode calls `shutdown` when its work finishes. These are local sample choices;
measure and set limits for your application's data and workload.

| Application responsibility | Runtime behavior |
| --- | --- |
| Declare typed operations, validated keys, policy, scope, and estimated output weights | Reuse cached outputs and coalesce concurrent calls for matching keys and scope |
| Reserve per-operation cache budgets within the runtime's total budget | Evict to those estimated weight budgets; keep operation reservations separate |
| Write cheap bounded views and charge before allocating each item | Admit a bounded number of views, limit their queue, and check response counts and bytes |
| Choose execution limits, queue sizes, deadlines, and shutdown grace | Apply those limits and report overload, deadlines, and shutdown outcomes |
| Derive trusted caller identity and configure command capabilities | Separate per-window state and forget that state when cleanup is invoked |
| Bound IPC request bytes and serialized response bytes in the adapter | Keep source outputs in Rust while views return bounded response values |

`Caller::window("main")` and `Caller::window("inspector")` are trusted CLI
illustrations. A production Tauri command must derive the caller from the
injected window with `shared_runtime_tauri::caller(&window)`, and grant commands
through Tauri capabilities. Never accept a frontend-provided window label or
caller identity as authority. Include any other result-affecting access context
in validated operation keys; a window label alone is not an authorization check.
See the [adapter guide](../crates/shared-runtime-tauri/README.md).

Cache weights and bounded responses describe runtime-owned work and data. They
are not an operating-system RAM cap or a measurement of whole-application
savings. The examples do not deduplicate WebView processes or share resources
between separate applications. Generated bindings and cross-application sharing
are outside these recipes.
