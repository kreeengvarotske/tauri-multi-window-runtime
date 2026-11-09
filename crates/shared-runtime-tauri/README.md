# shared-runtime-tauri

The Tauri v2 adapter for `shared-runtime` (stage R3 of the runtime API proposal, PR #32). `shared-runtime` and `runtime-core` have no Tauri dependency; this crate is the only place where the two meet. `examples/runtime-adapter-demo` is a minimal app that uses it.

## Using it

Follow the [Windows demo quick start](../../examples/runtime-adapter-demo/README.md) to build the example and run its native self-test.

```rust
// One runtime for the whole application, built and registered in Rust.
let runtime = Runtime::builder(config)?
    .register(Catalog { .. }, OperationConfig { cache_budget_bytes: 8 << 20 })?
    .view::<Catalog, _>(CatalogPage)?
    .build();

tauri::Builder::default()
    .plugin(shared_runtime_tauri::init(runtime, AdapterConfig { abort_wait: Duration::from_secs(1) }))
    .invoke_handler(tauri::generate_handler![catalog_page])

// One hand-written command per operation or view, granted by a capability.
#[tauri::command]
async fn catalog_page<R: tauri::Runtime>(
    window: WebviewWindow<R>,
    request: Request<'_>,
    shared: State<'_, SharedRuntime>,
) -> Result<JsonBytes, AdapterError> {
    let page: PageRequest = decode(&request, 256)?;                 // bytes checked before parsing
    shared
        .view::<Catalog, CatalogPage>(&caller(&window), page, 64 << 10, CallOptions::default())
        .await                                                     // serialized inside the projection slot
}
```

The frontend sends the request as UTF-8 JSON bytes and decodes the bytes it gets back (`examples/runtime-adapter-demo/ui/main.js`):

```js
const bytes = await invoke("catalog_page", new TextEncoder().encode(JSON.stringify({ offset: 0, limit: 100 })));
const page = JSON.parse(new TextDecoder().decode(bytes));
// errors: { code: "REQUEST_TOO_LARGE" | …, message }
```

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
- **Cache budgets account for the weights reported by operations.** The budget tracks values retained by the cache. Values still held by callers, allocator overhead, Tauri, and WebView memory contribute separately to process memory.
- **Shutdown uses a cooperative timeout.** At exit the adapter waits with a `shutdown_grace + abort_wait` timeout. Keep runtime work cooperative so the timeout can be observed. Synchronous code already running may continue until the process exits.
- **Response memory is bounded only for views that charge their budget.** The runtime refuses an over-limit response either way, but a view that builds before charging has already allocated it.
- **Measured memory effect: none claimed.** This PR adds the adapter; memory comes from the reviewed scenario runs.

## Tests

- `cargo test -p shared-runtime-tauri`: decoding, encoding, error envelopes, the projection limit during serialization, and shutdown.
- `cargo test -p runtime-adapter-demo`: the demo's commands through Tauri's IPC with the mock runtime, including the ACL from its `capabilities/` (8 tests).
- `runtime-adapter-demo --self-test report.json`: on a real window system, w1's page calls the commands over the real IPC (raw bytes in and out, capabilities, CSP), then the test destroys and reopens w1 and exits; the report lists every check and `passed`.
