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
    CachePolicy, CallOptions, OpContext, Operation, OperationConfig, RegistryError, Runtime,
    RuntimeConfig, ScopeRule, View, ViewError,
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
    pub limit: u32,
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
        100
    }

    fn max_response_bytes(&self) -> usize {
        32 << 10
    }

    fn project(
        &self,
        output: &Vec<Item>,
        request: PageRequest,
        max_items: usize,
    ) -> Result<OwnedPage, ViewError> {
        if request.limit == 0 || request.limit as usize > max_items {
            return Err(ViewError::InvalidRequest(format!(
                "limit must be 1 to {max_items}"
            )));
        }
        let start = (request.offset as usize).min(output.len());
        let end = (start + request.limit as usize).min(output.len());
        Ok(OwnedPage {
            total: output.len(),
            items: output[start..end].to_vec(),
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

/// Builds the runtime with both operations and the view.
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
    use super::{Catalog, WindowNote};
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
        pub entries_before_destroy: usize,
        pub entries_after_destroy: Option<usize>,
        pub forget_ms: Option<u128>,
        pub reopened_w1_note: u64,
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
        expect(
            "page: total 10000",
            results["page"]["ok"]["total"] == 10_000,
        );
        expect(
            "page: item 5 first",
            results["page"]["ok"]["items"][0]["id"] == 5,
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

    async fn run<R: tauri::Runtime>(app: &AppHandle<R>) -> Result<(), String> {
        let (tx, rx) = std::sync::mpsc::channel();
        app.once("demo://self-test", move |event| {
            let _ = tx.send(event.payload().to_owned());
        });
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
        open(app, "?self-test")?;
        let started = Instant::now();
        let payload = loop {
            if let Ok(payload) = rx.try_recv() {
                break payload;
            }
            if started.elapsed() > Duration::from_secs(30) {
                return Err("w1 sent no IPC results within 30 s".into());
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        };
        let results: serde_json::Value =
            serde_json::from_str(&payload).map_err(|e| e.to_string())?;
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
        app.get_webview_window("w1")
            .unwrap()
            .destroy()
            .map_err(|e| e.to_string())?;
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
        let progress = app.state::<Progress>();
        let mut report = progress.0.lock().unwrap();
        report.entries_after_destroy = Some(before - 1);
        report.forget_ms = Some(forget_ms);
        report.reopened_w1_note = reopened;
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
            && report.refused_after_exit
            && report.caches_empty_after_exit;
        let text = serde_json::to_string_pretty(&*report).expect("report serializes");
        std::fs::write(path, text).expect("report is writable");
    }
}
