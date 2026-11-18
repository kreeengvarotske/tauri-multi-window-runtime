# shared-runtime-tauri

The Tauri v2 adapter for `shared-runtime`. It stores one runtime as application
state, connects window destruction and application exit to runtime cleanup, and
provides typed helpers for bounded command requests and responses.
`shared-runtime` and `runtime-core` have no Tauri dependency.

## Using it

Follow the [Windows demo quick start](../../examples/runtime-adapter-demo/README.md)
to build the real two-window example, run its native self-test with a fresh owned
WebView profile, and retain its evidence. The manual self-test checks functional
behavior; ordinary `Start-Process` does not prove ownership or cleanup of the
WebView process tree. Release process accounting requires a launcher that owns
that tree through a Windows Job Object.

For application use, prefer a verified published Git release. Once the
[Windows release](https://github.com/kreeengvarotske/tauri-multi-window-runtime/releases/tag/v0.1.0)
is published, verify its tag against the qualified full commit SHA stated in
the Release text. Then use the same tag for both backend dependencies:

```toml
shared-runtime = { git = "https://github.com/kreeengvarotske/tauri-multi-window-runtime.git", tag = "v0.1.0" }
shared-runtime-tauri = { git = "https://github.com/kreeengvarotske/tauri-multi-window-runtime.git", tag = "v0.1.0" }
```

Check the remote identity before installing:

```powershell
git ls-remote https://github.com/kreeengvarotske/tauri-multi-window-runtime.git 'refs/tags/v0.1.0' 'refs/tags/v0.1.0^{}'
```

For an annotated tag, its peeled `^{}` line must match the Release's qualified
commit SHA; for a lightweight tag, compare the tag line. If the release or tag
is missing, use reviewed source for evaluation instead. Verify that both
dependencies resolve to the qualified commit in your application's `Cargo.lock`.

For development, or evaluation before publication, use a reviewed Git commit
available from the repository. From that checkout, print the dependency entries
for its exact SHA:

```powershell
$sdkRevision = (& git rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $sdkRevision -notmatch '\A[0-9a-fA-F]{40}\z') { throw 'Could not resolve the reviewed SDK revision' }
@"
shared-runtime = { git = "https://github.com/kreeengvarotske/tauri-multi-window-runtime.git", rev = "$sdkRevision" }
shared-runtime-tauri = { git = "https://github.com/kreeengvarotske/tauri-multi-window-runtime.git", rev = "$sdkRevision" }
"@
```

Place both entries under `[dependencies]` in your Tauri backend's manifest. Keep
your application's existing Tauri v2 dependency and build setup. Both runtime
dependencies must use the same full SHA. Commit the application's resolved
`Cargo.lock`, verify the runtime Git sources point to that SHA, and use
`cargo build --locked` afterwards. A Git revision includes committed source;
local uncommitted changes are not part of the dependency.

### Register operations, a view, and a command

Declare your Rust operation, validated request, response, and view types first.
The [runnable runtime recipes](../../docs/recipes.md) cover shared caches,
per-window state, and concurrent IO. For a Tauri catalog command, use the
[demo's Catalog, CatalogPage, and PageRequest definitions](../../examples/runtime-adapter-demo/src/lib.rs)
as a starting point. The following startup code assumes those types are in scope
and runs inside your application's startup function:

```rust
use shared_runtime::{OperationConfig, Runtime, RuntimeConfig};
use shared_runtime_tauri::AdapterConfig;
use std::time::Duration;

// Sample application limits; measure and choose your own.
let runtime = Runtime::builder(RuntimeConfig {
    max_concurrent_operations: 4,
    max_queued_operations: 64,
    max_concurrent_projections: 4,
    max_queued_projections: 32,
    default_deadline: Duration::from_secs(10),
    shutdown_grace: Duration::from_secs(2),
    cache_budget_bytes: 16 << 20,
})?
    .register(Catalog { items: 10_000 }, OperationConfig { cache_budget_bytes: 8 << 20 })?
    .view::<Catalog, _>(CatalogPage)?
    .build();

tauri::Builder::default()
    .plugin(shared_runtime_tauri::init(runtime, AdapterConfig { abort_wait: Duration::from_secs(1) }))
    .invoke_handler(tauri::generate_handler![catalog_page])
    .run(tauri::generate_context!())?;
```

Write one command for each operation or view you expose. The demo request type
rejects unknown fields and validates the page size. The command derives identity
from Tauri's injected `WebviewWindow`, checks request bytes before typed decoding,
and caps the serialized response:

```rust
use shared_runtime::CallOptions;
use shared_runtime_tauri::{AdapterError, JsonBytes, SharedRuntime, caller, decode};
use tauri::{State, WebviewWindow, ipc::Request};

#[tauri::command]
async fn catalog_page<R: tauri::Runtime>(
    window: WebviewWindow<R>,
    request: Request<'_>,
    shared: State<'_, SharedRuntime>,
) -> Result<JsonBytes, AdapterError> {
    let page: PageRequest = decode(&request, 256)?;
    shared
        .view::<Catalog, CatalogPage>(&caller(&window), page, 64 << 10, CallOptions::default())
        .await
}
```

Never accept a frontend-supplied caller, window label, scope, or operation name
as authority. `PerWindow` separates data; capabilities authorize command access.
Set view item and byte limits, and charge `ResponseBudget` before cloning each
item. The demo's page limits are 100 items and 32 KiB of charged response data;
the command above separately allows 256 request bytes and 64 KiB of serialized
response bytes. Queue counts, cache weights, and IPC byte limits measure
different parts of the workload; none is a whole-application OS RAM cap.

### Register and grant the application command

In your Tauri backend's `build.rs`, include application commands in its existing
`tauri_build` setup so Tauri generates their permissions:

```rust
const COMMANDS: &[&str] = &["catalog_page"];

fn main() {
    let attributes = tauri_build::Attributes::new()
        .app_manifest(tauri_build::AppManifest::new().commands(COMMANDS));
    tauri_build::try_build(attributes).expect("build Tauri application manifest");
}
```

Grant that permission only to intended windows. For example,
`capabilities/catalog.json` can contain:

```json
{
  "$schema": "../gen/schemas/desktop-schema.json",
  "identifier": "catalog",
  "description": "Main window may read catalog pages",
  "windows": ["main"],
  "permissions": ["core:default", "allow-catalog-page"]
}
```

Include `"catalog"` in `app.security.capabilities` if your `tauri.conf.json`
explicitly selects capabilities. Keep other application commands and grants
in place. See the demo's [build script](../../examples/runtime-adapter-demo/build.rs),
[capabilities](../../examples/runtime-adapter-demo/capabilities/default.json), and
[configuration](../../examples/runtime-adapter-demo/tauri.conf.json).

### Optional JavaScript/TypeScript client

Install the private client directory from your reviewed checkout into your
frontend project, or install a tarball created by running `npm pack` in that
directory. Registry publication is not assumed:

```powershell
npm install 'C:/path/to/reviewed-checkout/packages/runtime-client'
```

The application supplies `invoke` and manually declares its TypeScript shapes:

```ts
import { invoke } from '@tauri-apps/api/core';
import { createCommand, RuntimeCommandError } from 'tmwr-runtime-client';

interface PageRequest { offset: number; limit: number }
interface Page { total: number; items: { id: number; name: string }[] }

const catalogPage = createCommand<PageRequest, Page>(invoke, 'catalog_page');
try {
  const page = await catalogPage({ offset: 0, limit: 10 });
  console.log(page.items);
} catch (error) {
  if (error instanceof RuntimeCommandError && error.code === 'OVERLOADED') {
    console.log('Catalog is busy; try again later.');
  } else {
    throw error;
  }
}
```

`createCommand` sends a JSON object and decodes the JSON-byte response. Object
requests work through custom-protocol IPC and the desktop `postMessage` fallback.
The client adds no automatic retries, cache, or cancellation layer. TypeScript
types are declarations, with no generated bindings or runtime response schema
validation. See the [client guide](../../packages/runtime-client/README.md).
The [real demo frontend](../../examples/runtime-adapter-demo/ui/main.js) imports
a distributed client copy and needs no npm installation or frontend bundler.

## What the adapter guarantees

| Requirement (R3 review) | How | Evidence |
|---|---|---|
| Separate adapter crate; core and `shared-runtime` do not depend on Tauri | this crate; `tauri` with `default-features = false`, so it does not pick a webview runtime | `cargo tree -p shared-runtime -e normal` and `-p runtime-core` list no `tauri` (checked in CI) |
| One `Runtime` as Tauri state | `init` stores it as `SharedRuntime` once, in plugin setup | `every_window_reads_the_same_shared_catalog` (one execution for two windows) |
| Shutdown on exit with the configured grace | `RunEvent::Exit` → `SharedRuntime::shutdown`: the runtime's `shutdown_grace`, then at most `abort_wait` more; a view call counts as in flight until serialization ends, and one still waiting for a projection slot after the grace gets `SHUTTING_DOWN` | `shutdown_ends_calls_in_flight_within_grace_and_refuses_new_ones`; `exit_shuts_the_runtime_down` (mock event loop); demo `--self-test` on a real window system (`refusedAfterExit`, `cachesEmptyAfterExit`) |
| Hand-written commands, no generic `call(op, params)`, no macros | the crate has no commands; `SharedRuntime::view::<O, V>` / `call::<O, _>` are typed in Rust | demo's three commands; the WebView never names an operation |
| `Caller` only from the injected window | `caller(&WebviewWindow)` is the only constructor the adapter uses; request types use `deny_unknown_fields` | `a_forged_window_or_scope_in_the_request_is_refused`, `per_window_data_follows_the_injected_window`, self-test `forged` |
| `PerWindow` is data isolation, not authorization | access is decided by Tauri capabilities before the command runs | `capabilities_decide_which_window_runs_a_command`; self-test `stats: denied to w1` |
| Raw request bytes limited before typed deserialization (not a bound on the transport, which already holds the body) | `decode`: raw body length checked, then parsed straight into `T`; a JSON body (object argument, `postMessage` fallback) has its serialized length counted without allocating before `T` is built | `oversized_raw_body_is_refused_before_deserialization`, `oversized_json_body_is_refused_before_typed_deserialization` (a counting `Deserialize` proves no attempt), `oversized_request_is_refused_with_a_stable_code`; self-test `oversized` |
| View responses built within a budget | the demo's `CatalogPage` charges each item to the `ResponseBudget` before copying it, as `View::project` requires; a view that builds first is only refused after the allocation (`shared-runtime` docs) | `shared-runtime`: `a_view_that_charges_first_stops_building_at_the_byte_limit`, `a_view_that_ignores_the_budget_is_refused_after_building` |
| Serialized response bytes checked | `encode_json` stops writes at the limit and caps requested buffer capacity at the same limit | `encode_stops_at_the_limit`, `response_buffer_growth_stays_within_a_non_power_of_two_limit`, `serialized_response_over_the_limit_is_refused` |
| Serialization inside `ViewHandle::get_with` | `SharedRuntime::view` serializes in the `finish` closure, under the projection slot | `serialization_is_inside_the_projection_limit` (one slot held mid-serialization; a second call reaches `DEADLINE_EXCEEDED`) |
| `forget_window` on window destroy; reopen starts empty | plugin: `RunEvent::WindowEvent { Destroyed }` → `forget_window(label)` | demo `--self-test` (`entriesAfterDestroy`, new note after reopen); the mock runtime emits no `Destroyed`, so this is not a mock test |
| `{ code, message }` envelope, stable codes | `AdapterError`, `AdapterErrorCode` | `codes_are_stable`, `envelope_is_code_and_message`, `runtime_outcomes_map_to_codes`, `invalid_requests_have_stable_codes` |
| No application text in the envelope | fields private (read with `code()`, `message()`); `AdapterError::new` is crate-private; the only public constructor, `invalid_argument()`, takes no message | `application_invalid_argument_does_not_carry_application_text`; `compile_fail` doctests on `AdapterError` (`new` and field assignment do not compile outside the crate) |
| Existing commands, capabilities and demo IPC unchanged | `src-tauri` and `runtime-ipc` are not touched; `IpcErrorCode` is not extended | diff of this PR |

Codes: `INVALID_ARGUMENT`, `REQUEST_TOO_LARGE`, `RESPONSE_TOO_LARGE`, `DEADLINE_EXCEEDED`, `OVERLOADED`, `SHUTTING_DOWN`, `OPERATION_FAILED`, `INTERNAL`. They are new codes of new commands, kept in this crate; the demo IPC's `IpcErrorCode` stays as it is (`INVALID_ARGUMENT`, `OPERATION_FAILED` and `INTERNAL` mean the same in both). Adding them to `IpcErrorCode` or the TypeScript SDK would be a contract change and a separate PR.

## What it does not guarantee

- **The transport has the bytes before the adapter does.** Tauri reads the whole request body (and, on the `postMessage` fallback, parses it as JSON) before any command runs. The adapter bounds what is deserialized into typed values and what it serializes back, not what the WebView may send to the IPC layer.
- **Who may call a command is up to the capabilities.** The adapter does not check permissions. A command granted to a window runs for it; `PerWindow` only keeps that window's data apart.
- **Window identity is the window label.** `Caller` is the label of the `WebviewWindow` Tauri injects; a window opened later under the same label is the same caller (it starts empty because the old one was forgotten on destroy). Commands work for `WebviewWindow`s; a webview embedded in a multi-webview window is not supported.
- **`call` responses are not under the projection limit.** `SharedRuntime::call` serializes what `respond` returns after the operation, without a projection slot; it is meant for small results. Anything that grows with the data belongs in a view.
- **Operation errors are sanitized at the IPC boundary.** The WebView receives the stable `OPERATION_FAILED` code and generic `operation failed` message; operation error details are not serialized into the response.
- **View deadlines cover admission and source lookup.** A view waits for a slot before fetching its source, so queued views do not keep source outputs alive. Slow sources hold a slot until the view finishes. Once synchronous projection or serialization starts, it cannot be interrupted by the deadline. Keep both proportional to the bounded response.
- **View admission has a separate queue limit.** Set `RuntimeConfig::max_queued_projections` explicitly. Zero means no waiting; a full queue returns the existing `OVERLOADED` envelope before source parameter derivation. Cancellation, deadlines and shutdown release queue positions. Runtime stats expose `active_projections`, `queued_projections` and `projection_overloads`; calls refused before source lookup do not increment operation requests. The count limit does not bound the bytes of incoming requests or IPC transport buffers. See the [configuration and migration note](../../docs/projection-queue-review.md).
- **Cache budgets account for the weights reported by operations.** The budget tracks values retained by the cache. Values still held by callers, allocator overhead, Tauri, and WebView memory contribute separately to process memory.
- **Shutdown uses a cooperative timeout.** At exit the adapter waits with a `shutdown_grace + abort_wait` timeout. Keep runtime work cooperative so the timeout can be observed. Synchronous code already running may continue until the process exits.
- **Response memory is bounded only for views that charge their budget.** The runtime refuses an over-limit response either way, but a view that builds before charging has already allocated it.
- **Whole-application memory or CPU savings are not claimed.** The adapter bounds specific work and data; workload benchmarks are needed to measure their application effect. WebView process deduplication and cross-application sharing are outside this release.

## Tests

- `cargo test -p shared-runtime-tauri`: decoding, encoding, error envelopes, the projection limit during serialization, and shutdown.
- `cargo test -p runtime-adapter-demo`: the demo's commands through Tauri's IPC with the mock runtime, including the ACL from its `capabilities/`.
- `runtime-adapter-demo --self-test report.json`: on a real window system, the pages call commands over real IPC (JSON-object requests, JSON-byte responses, capabilities, CSP), with a separate oversized raw-byte request to check rejection. The test destroys and reopens w1 and exits; the report lists every check and `passed`. Use the quick start's fresh profile, bounded wait, and retained evidence. This functional report alone does not establish process-tree cleanup.
