//! Minimal integration of `shared-runtime` through `shared-runtime-tauri`.
//!
//! - `Catalog`: a `Shared` operation, one list of items for every window,
//!   read through the bounded `CatalogPage` view;
//! - `WindowNote`: a `PerWindow` operation, one value per window, dropped
//!   when the window is destroyed;
//! - three hand-written commands, each granted by a capability
//!   (`capabilities/`): pages and notes for every window, stats for `main`.
//!
//! The frontend never names an operation, a scope or a window; the caller
//! is the window Tauri injects.

use serde::{Deserialize, Serialize};
use shared_runtime::{
    CachePolicy, CallOptions, OpContext, Operation, OperationConfig, RegistryError, ResponseBudget,
    Runtime, RuntimeConfig, ScopeRule, View, ViewError,
};
use shared_runtime_tauri::{AdapterConfig, AdapterError, JsonBytes, SharedRuntime, caller, decode};
use std::{
    convert::Infallible,
    sync::atomic::{AtomicU64, Ordering},
    time::Duration,
};
use tauri::{State, WebviewWindow, ipc::Request};

/// Request and response byte limits of each command.
pub const PAGE_MAX_REQUEST_BYTES: usize = 256;
pub const PAGE_MAX_RESPONSE_BYTES: usize = 64 << 10;
pub const NOTE_MAX_RESPONSE_BYTES: usize = 256;
pub const STATS_MAX_RESPONSE_BYTES: usize = 4 << 10;
const CATALOG_PAGE_MAX_ITEMS: u32 = 100;

/// The demo's limits. Sample values for this demo only.
#[derive(Debug, Clone)]
pub struct DemoConfig {
    pub items: u32,
    pub runtime: RuntimeConfig,
    pub adapter: AdapterConfig,
}

impl Default for DemoConfig {
    fn default() -> Self {
        Self {
            items: 10_000,
            runtime: RuntimeConfig {
                max_concurrent_operations: 4,
                max_queued_operations: 64,
                max_concurrent_projections: 4,
                default_deadline: Duration::from_secs(10),
                shutdown_grace: Duration::from_secs(2),
                cache_budget_bytes: 16 << 20,
            },
            adapter: AdapterConfig {
                abort_wait: Duration::from_secs(1),
            },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Item {
    pub id: u32,
    pub name: String,
}

/// Every window shares one catalog.
pub struct Catalog {
    pub items: u32,
}

impl Operation for Catalog {
    const NAME: &'static str = "demo.catalog";
    type Params = ();
    type Output = Vec<Item>;
    type Error = Infallible;

    fn policy(&self) -> CachePolicy {
        CachePolicy::Forever
    }

    fn weight(&self, output: &Self::Output) -> usize {
        output
            .iter()
            .map(|item| std::mem::size_of::<Item>() + item.name.capacity())
            .sum()
    }

    async fn run(&self, _ctx: OpContext, _params: ()) -> Result<Vec<Item>, Infallible> {
        Ok((0..self.items)
            .map(|id| Item {
                id,
                name: format!("item {id:05}"),
            })
            .collect())
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PageRequest {
    pub offset: u32,
    #[serde(deserialize_with = "decode_page_limit")]
    pub limit: u32,
}

fn decode_page_limit<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<u32, D::Error> {
    let limit = u32::deserialize(deserializer)?;
    if !(1..=CATALOG_PAGE_MAX_ITEMS).contains(&limit) {
        return Err(serde::de::Error::custom(
            "page size is outside the allowed range",
        ));
    }
    Ok(limit)
}

/// A page of the catalog: at most 100 items, at most 32 KiB.
pub struct CatalogPage;

#[derive(Debug, Serialize)]
pub struct OwnedPage {
    pub total: usize,
    pub items: Vec<Item>,
}

impl View<Catalog> for CatalogPage {
    const NAME: &'static str = "demo.catalog.page";
    type Request = PageRequest;
    type Response = OwnedPage;

    fn source(&self, _request: &PageRequest) {}

    fn max_items(&self) -> usize {
        CATALOG_PAGE_MAX_ITEMS as usize
    }

    fn max_response_bytes(&self) -> usize {
        32 << 10
    }

    fn project(
        &self,
        output: &Vec<Item>,
        request: PageRequest,
        budget: &mut ResponseBudget,
    ) -> Result<OwnedPage, ViewError> {
        let max_items = budget.max_items();
        if request.limit == 0 || request.limit as usize > max_items {
            return Err(ViewError::InvalidRequest(format!(
                "limit must be 1 to {max_items}"
            )));
        }
        let start = (request.offset as usize).min(output.len());
        let end = (start + request.limit as usize).min(output.len());
        let mut items = Vec::with_capacity(end - start);
        for item in &output[start..end] {
            // Charged before the copy, as `response_bytes` counts it.
            budget.take(std::mem::size_of::<Item>() + item.name.len())?;
            items.push(item.clone());
        }
        Ok(OwnedPage {
            total: output.len(),
            items,
        })
    }

    fn items(response: &OwnedPage) -> usize {
        response.items.len()
    }

    fn response_bytes(response: &OwnedPage) -> usize {
        response
            .items
            .iter()
            .map(|item| std::mem::size_of::<Item>() + item.name.len())
            .sum()
    }
}

/// One value per window: which execution of this operation produced it.
/// Two windows never see each other's value, and a window destroyed and
/// opened again gets a new one.
pub struct WindowNote {
    pub executions: AtomicU64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Note {
    pub execution: u64,
}

impl Operation for WindowNote {
    const NAME: &'static str = "demo.window-note";
    type Params = ();
    type Output = Note;
    type Error = Infallible;

    fn policy(&self) -> CachePolicy {
        CachePolicy::Forever
    }

    fn scope(&self) -> ScopeRule {
        ScopeRule::PerWindow
    }

    fn weight(&self, _output: &Note) -> usize {
        std::mem::size_of::<Note>()
    }

    async fn run(&self, _ctx: OpContext, _params: ()) -> Result<Note, Infallible> {
        Ok(Note {
            execution: self.executions.fetch_add(1, Ordering::SeqCst) + 1,
        })
    }
}

/// A bounded Rust-side note view used by the native lifecycle self-test.
/// It is not exposed as an additional IPC command.
struct NoteValue;

impl View<WindowNote> for NoteValue {
    const NAME: &'static str = "demo.window-note.value";
    type Request = ();
    type Response = Note;
    fn source(&self, _: &()) {}
    fn max_items(&self) -> usize {
        1
    }
    fn max_response_bytes(&self) -> usize {
        std::mem::size_of::<Note>()
    }
    fn project(&self, note: &Note, _: (), budget: &mut ResponseBudget) -> Result<Note, ViewError> {
        budget.take(std::mem::size_of::<Note>())?;
        Ok(*note)
    }
    fn items(_: &Note) -> usize {
        1
    }
    fn response_bytes(_: &Note) -> usize {
        std::mem::size_of::<Note>()
    }
}

/// Builds the runtime with both operations and bounded views.
pub fn runtime(config: DemoConfig) -> Result<Runtime, RegistryError> {
    Ok(Runtime::builder(config.runtime)?
        .register(
            Catalog {
                items: config.items,
            },
            OperationConfig {
                cache_budget_bytes: 8 << 20,
            },
        )?
        .register(
            WindowNote {
                executions: AtomicU64::new(0),
            },
            OperationConfig {
                cache_budget_bytes: 64 << 10,
            },
        )?
        .view::<Catalog, _>(CatalogPage)?
        .view::<WindowNote, _>(NoteValue)?
        .build())
}

/// Adds the adapter plugin and the demo's commands to `builder`.
pub fn app<R: tauri::Runtime>(builder: tauri::Builder<R>, runtime: Runtime) -> tauri::Builder<R> {
    builder
        .plugin(shared_runtime_tauri::init(
            runtime,
            DemoConfig::default().adapter,
        ))
        .invoke_handler(tauri::generate_handler![
            demo_catalog_page,
            demo_window_note,
            demo_stats
        ])
}

/// One page of the shared catalog. Body: `{ "offset": n, "limit": n }` as
/// UTF-8 JSON bytes.
#[tauri::command]
async fn demo_catalog_page<R: tauri::Runtime>(
    window: WebviewWindow<R>,
    request: Request<'_>,
    shared: State<'_, SharedRuntime>,
) -> Result<JsonBytes, AdapterError> {
    let page: PageRequest = decode(&request, PAGE_MAX_REQUEST_BYTES)?;
    shared
        .view::<Catalog, CatalogPage>(
            &caller(&window),
            page,
            PAGE_MAX_RESPONSE_BYTES,
            CallOptions::default(),
        )
        .await
}

/// This window's note. No request body; the window is the one Tauri injects.
#[tauri::command]
async fn demo_window_note<R: tauri::Runtime>(
    window: WebviewWindow<R>,
    shared: State<'_, SharedRuntime>,
) -> Result<JsonBytes, AdapterError> {
    shared
        .call::<WindowNote, _>(
            &caller(&window),
            (),
            NOTE_MAX_RESPONSE_BYTES,
            CallOptions::default(),
            |note| *note,
        )
        .await
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct OperationSummary {
    name: &'static str,
    requests: u64,
    executed: u64,
    cache_entries: usize,
    cache_weight_bytes: usize,
}

/// Counters only, no keys or values. Granted to `main` alone.
#[tauri::command]
fn demo_stats(shared: State<'_, SharedRuntime>) -> Result<JsonBytes, AdapterError> {
    let summary: Vec<OperationSummary> = shared
        .runtime()
        .stats()
        .operations
        .into_iter()
        .map(|op| OperationSummary {
            name: op.name,
            requests: op.requests,
            executed: op.executed,
            cache_entries: op.cache_entries,
            cache_weight_bytes: op.cache_weight_bytes,
        })
        .collect();
    shared_runtime_tauri::encode_json(&summary, STATS_MAX_RESPONSE_BYTES)
}

/// `--self-test <report.json>`: checks the plugin's window and exit hooks on
/// the real window system, where the mock runtime cannot (it emits no
/// `WindowEvent::Destroyed` and cannot exit on request). Opens `w1`, gives
/// `main` and `w1` a note, destroys `w1`, waits for the plugin to drop its
/// note, reopens `w1`, then exits; on `RunEvent::Exit` (after the plugin has
/// shut the runtime down) it checks that calls are refused and writes the
/// report.
pub mod self_test {
    use super::{Catalog, CatalogPage, NoteValue, PageRequest, WindowNote};
    use serde::Serialize;
    use shared_runtime::{CallError, CallOptions, Caller};
    use shared_runtime_tauri::SharedRuntime;
    use std::{
        path::PathBuf,
        sync::Mutex,
        time::{Duration, Instant},
    };
    use tauri::{AppHandle, Listener, Manager, WebviewUrl, WebviewWindowBuilder};

    #[derive(Debug, Default, Serialize)]
    #[serde(rename_all = "camelCase")]
    pub struct Report {
        pub main_note: u64,
        pub first_w1_note: u64,
        /// What w1's page sent back over the real IPC (see ui/main.js).
        pub ipc: Option<serde_json::Value>,
        pub ipc_checks: Vec<String>,
        pub main_ipc: Option<serde_json::Value>,
        pub catalog_executions: u64,
        pub catalog_cache_entries: usize,
        pub entries_before_destroy: usize,
        pub entries_after_destroy: Option<usize>,
        pub forget_ms: Option<u128>,
        pub reopened_w1_note: u64,
        pub queued_view_old_note: Option<u64>,
        pub queued_view_separated: bool,
        pub queued_view_cache_stable: bool,
        pub refused_after_exit: bool,
        pub caches_empty_after_exit: bool,
        pub error: Option<String>,
        pub passed: bool,
    }

    /// The report so far, written on exit.
    pub struct Progress(pub Mutex<Report>);

    fn note_entries(app: &AppHandle<impl tauri::Runtime>) -> usize {
        let shared = app.state::<SharedRuntime>();
        let stats = shared.runtime().stats();
        stats
            .operation("demo.window-note")
            .map_or(0, |op| op.cache_entries)
    }

    async fn note(app: &AppHandle<impl tauri::Runtime>, label: &str) -> Result<u64, String> {
        let shared = app.state::<SharedRuntime>();
        let handle = shared
            .runtime()
            .operation::<WindowNote>()
            .map_err(|e| e.to_string())?;
        // The caller a command would get from this window.
        let window = app
            .get_webview_window(label)
            .ok_or(format!("no window {label}"))?;
        let note = handle
            .get(
                &shared_runtime_tauri::caller(&window),
                (),
                CallOptions::default(),
            )
            .await
            .map_err(|e| format!("{e:?}"))?;
        Ok(note.execution)
    }

    /// Failed expectations about w1's IPC results; empty when all hold.
    fn check_ipc(results: &serde_json::Value) -> Vec<String> {
        let mut failed = Vec::new();
        let mut expect = |what: &str, ok: bool| {
            if !ok {
                failed.push(what.to_owned());
            }
        };
        expect("page: items 5 and 6", check_page(results, [5, 6]));
        expect(
            "invalid page size: INVALID_ARGUMENT",
            results["invalidSize"]["error"]["code"] == "INVALID_ARGUMENT",
        );
        expect(
            "oversized: REQUEST_TOO_LARGE",
            results["oversized"]["error"]["code"] == "REQUEST_TOO_LARGE",
        );
        expect(
            "forged: INVALID_ARGUMENT",
            results["forged"]["error"]["code"] == "INVALID_ARGUMENT",
        );
        expect(
            "note: a number",
            results["note"]["ok"]["execution"].is_u64(),
        );
        expect(
            "stats: denied to w1 by capabilities",
            results["stats"]["error"]
                .as_str()
                .is_some_and(|e| e.contains("not allowed")),
        );
        failed
    }

    fn check_page(ipc: &serde_json::Value, expected_ids: impl IntoIterator<Item = u64>) -> bool {
        let page = &ipc["page"]["ok"];
        page["total"] == 10_000
            && page["items"].as_array().is_some_and(|items| {
                items
                    .iter()
                    .map(|item| item["id"].as_u64())
                    .eq(expected_ids.into_iter().map(Some))
            })
    }

    async fn ipc_results<R: tauri::Runtime>(
        app: &AppHandle<R>,
        event: &str,
        start: impl FnOnce() -> Result<(), String>,
    ) -> Result<serde_json::Value, String> {
        let (tx, rx) = tokio::sync::oneshot::channel();
        let listener = app.once(event, move |event| {
            let _ = tx.send(event.payload().to_owned());
        });
        if let Err(error) = start() {
            app.unlisten(listener);
            return Err(error);
        }
        let payload = tokio::time::timeout(Duration::from_secs(30), rx).await;
        app.unlisten(listener);
        let payload = payload
            .map_err(|_| format!("no IPC result for {event} within 30 s"))?
            .map_err(|_| format!("IPC listener closed for {event}"))?;
        serde_json::from_str(&payload).map_err(|e| e.to_string())
    }

    async fn run<R: tauri::Runtime>(app: &AppHandle<R>) -> Result<(), String> {
        let open = |app: &AppHandle<R>, query: &str| {
            WebviewWindowBuilder::new(
                app,
                "w1",
                WebviewUrl::App(format!("index.html{query}").into()),
            )
            .title("Runtime adapter demo — w1")
            .build()
            .map_err(|e| e.to_string())
        };
        let results = ipc_results(app, "demo://self-test", || {
            open(app, "?self-test").map(|_| ())
        })
        .await?;
        let failed = check_ipc(&results);
        {
            let progress = app.state::<Progress>();
            let mut report = progress.0.lock().unwrap();
            report.ipc = Some(results.clone());
            report.ipc_checks = failed.clone();
        }
        if !failed.is_empty() {
            return Err(format!("IPC checks failed: {}", failed.join("; ")));
        }
        let main = app.get_webview_window("main").ok_or("no main window")?;
        let w1 = app.get_webview_window("w1").ok_or("no w1 window")?;
        let main_ipc = ipc_results(app, "demo://self-test-main", || {
            let mut url = w1.url().map_err(|e| e.to_string())?;
            url.set_query(Some("self-test=main"));
            main.navigate(url).map_err(|e| e.to_string())
        })
        .await?;
        let shared = app.state::<SharedRuntime>();
        let stats = shared.runtime().stats();
        let catalog = stats.operation("demo.catalog").ok_or("no catalog stats")?;
        let main_page_ok = check_page(&main_ipc, [15, 16, 17]);
        let main_stats_ok = main_ipc["stats"]["ok"].as_array().is_some_and(|ops| {
            ops.iter().any(|op| {
                op["name"] == "demo.catalog"
                    && op["executed"] == 1
                    && op["requests"] == 2
                    && op["cacheEntries"] == 1
            })
        });
        {
            let progress = app.state::<Progress>();
            let mut report = progress.0.lock().unwrap();
            report.main_ipc = Some(main_ipc);
            report.catalog_executions = catalog.executed;
            report.catalog_cache_entries = catalog.cache_entries;
        }
        if !main_page_ok || !main_stats_ok {
            return Err("main window did not receive its page and stats over IPC".into());
        }
        if catalog.executed != 1 || catalog.cache_hits != 1 || catalog.cache_entries != 1 {
            return Err("the two WebViews did not share one cached catalog execution".into());
        }
        let main_note = note(app, "main").await?;
        let first = note(app, "w1").await?;
        let before = note_entries(app);
        {
            let progress = app.state::<Progress>();
            let mut report = progress.0.lock().unwrap();
            report.main_note = main_note;
            report.first_w1_note = first;
            report.entries_before_destroy = before;
        }
        if before != 2 || main_note == first {
            return Err("the two windows did not have separate cached notes".into());
        }
        // Occupy every projection slot without blocking the window/event loop.
        // Dropping `releases` also releases the holders on any early return.
        let mut releases = Vec::new();
        let mut holders = Vec::new();
        for _ in 0..shared.runtime().config().max_concurrent_projections {
            let view = shared
                .runtime()
                .view::<Catalog, CatalogPage>()
                .map_err(|e| e.to_string())?;
            let (release_tx, release_rx) = std::sync::mpsc::channel::<()>();
            let (entered_tx, entered_rx) = tokio::sync::oneshot::channel();
            releases.push(release_tx);
            let executor = tauri::async_runtime::handle();
            holders.push(tauri::async_runtime::spawn_blocking(move || {
                executor.block_on(view.get_with(
                    &Caller::window("main"),
                    PageRequest {
                        offset: 0,
                        limit: 1,
                    },
                    CallOptions::default(),
                    move |page| {
                        let _ = entered_tx.send(());
                        let _ = release_rx.recv();
                        page.items.len()
                    },
                ))
            }));
            tokio::time::timeout(Duration::from_secs(5), entered_rx)
                .await
                .map_err(|_| "projection holder did not acquire a slot")?
                .map_err(|_| "projection holder ended before entering")?;
        }
        let view = shared
            .runtime()
            .view::<WindowNote, NoteValue>()
            .map_err(|e| e.to_string())?;
        let old_caller = shared_runtime_tauri::caller(&w1);
        let requests = shared
            .runtime()
            .operation::<WindowNote>()
            .map_err(|e| e.to_string())?
            .stats()
            .requests;
        let mut queued = Box::pin(view.get(
            &old_caller,
            (),
            CallOptions {
                deadline: Some(Duration::from_secs(30)),
            },
        ));
        {
            use std::{
                future::Future,
                task::{Context, Waker},
            };
            if !queued
                .as_mut()
                .poll(&mut Context::from_waker(Waker::noop()))
                .is_pending()
            {
                return Err("old window view did not wait behind the occupied slots".into());
            }
        }
        if shared
            .runtime()
            .operation::<WindowNote>()
            .map_err(|e| e.to_string())?
            .stats()
            .requests
            != requests
        {
            return Err("queued window view fetched its source before admission".into());
        }
        w1.destroy().map_err(|e| e.to_string())?;
        let started = Instant::now();
        while note_entries(app) != before - 1 {
            if started.elapsed() > Duration::from_secs(10) {
                return Err("w1's note was not dropped within 10 s of destroy".into());
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let forget_ms = started.elapsed().as_millis();
        while app.get_webview_window("w1").is_some() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        open(app, "")?;
        let reopened = note(app, "w1").await?;
        let main_again = note(app, "main").await?;
        releases.clear();
        for holder in holders {
            tokio::time::timeout(Duration::from_secs(5), holder)
                .await
                .map_err(|_| "projection holder did not finish after release")?
                .map_err(|e| e.to_string())?
                .map_err(|e| format!("projection holder failed: {e:?}"))?;
        }
        let old_note = tokio::time::timeout(Duration::from_secs(5), queued)
            .await
            .map_err(|_| "old queued window view did not finish")?
            .map_err(|e| format!("old queued window view failed: {e:?}"))?;
        let separated = old_note.execution != reopened;
        let cache_stable = note(app, "w1").await? == reopened && note_entries(app) == before;
        let progress = app.state::<Progress>();
        let mut report = progress.0.lock().unwrap();
        report.entries_after_destroy = Some(before - 1);
        report.forget_ms = Some(forget_ms);
        report.reopened_w1_note = reopened;
        report.queued_view_old_note = Some(old_note.execution);
        report.queued_view_separated = separated;
        report.queued_view_cache_stable = cache_stable;
        if !separated || !cache_stable {
            return Err("old queued view read or replaced the reopened window's cache".into());
        }
        if main_again != main_note {
            return Err("main's note changed when w1 was destroyed".into());
        }
        if reopened == first {
            return Err("reopened w1 got the destroyed window's note".into());
        }
        Ok(())
    }

    /// Starts the test once the app is set up.
    pub fn start<R: tauri::Runtime>(app: AppHandle<R>) {
        app.manage(Progress(Mutex::new(Report::default())));
        tauri::async_runtime::spawn(async move {
            let result = tokio::time::timeout(Duration::from_secs(60), run(&app)).await;
            let error = match result {
                Ok(Ok(())) => None,
                Ok(Err(error)) => Some(error),
                Err(_) => Some("self-test timed out".into()),
            };
            app.state::<Progress>().0.lock().unwrap().error = error;
            app.exit(0);
        });
    }

    /// On `RunEvent::Exit`: the plugin has shut the runtime down by now.
    pub fn finish<R: tauri::Runtime>(app: &AppHandle<R>, path: &PathBuf) {
        let shared = app.state::<SharedRuntime>();
        let catalog = shared.runtime().operation::<Catalog>().expect("registered");
        let after = tauri::async_runtime::block_on(catalog.get(
            &Caller::window("main"),
            (),
            CallOptions::default(),
        ));
        let progress = app.state::<Progress>();
        let mut report = progress.0.lock().unwrap();
        report.refused_after_exit = matches!(after, Err(CallError::ShuttingDown));
        report.caches_empty_after_exit = shared.runtime().stats().cache_weight_bytes() == 0;
        report.passed = report.error.is_none()
            && report.entries_after_destroy.is_some()
            && report.queued_view_separated
            && report.queued_view_cache_stable
            && report.refused_after_exit
            && report.caches_empty_after_exit;
        let text = serde_json::to_string_pretty(&*report).expect("report serializes");
        std::fs::write(path, text).expect("report is writable");
    }
}
