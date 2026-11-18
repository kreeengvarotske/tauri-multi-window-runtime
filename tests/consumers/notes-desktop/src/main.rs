use serde::Deserialize;
use shared_runtime::{
    CachePolicy, CallError, CallOptions, Caller, OpContext, Operation, OperationConfig, Runtime,
    RuntimeConfig, ScopeRule,
};
use shared_runtime_tauri::{AdapterConfig, AdapterError, JsonBytes, SharedRuntime, caller, decode};
use std::{
    path::PathBuf,
    sync::atomic::{AtomicBool, AtomicU64, Ordering},
    time::{Duration, Instant},
};
use tauri::{Manager, State, WebviewWindow, ipc::Request};

struct Note;
struct Checks {
    success: AtomicBool,
    calls: AtomicU64,
    started: Instant,
    seconds: u64,
}
impl Operation for Note {
    const NAME: &'static str = "desktop.note";
    type Params = String;
    type Output = String;
    type Error = std::convert::Infallible;
    fn policy(&self) -> CachePolicy {
        CachePolicy::Forever
    }
    fn scope(&self) -> ScopeRule {
        ScopeRule::PerWindow
    }
    fn weight(&self, output: &String) -> usize {
        output.capacity()
    }
    async fn run(&self, _: OpContext, text: String) -> Result<String, Self::Error> {
        Ok(text)
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NoteRequest {
    text: String,
}

#[tauri::command]
async fn note(
    window: WebviewWindow,
    request: Request<'_>,
    shared: State<'_, SharedRuntime>,
    checks: State<'_, Checks>,
) -> Result<JsonBytes, AdapterError> {
    let request: NoteRequest = decode(&request, 512)?;
    if request.text.is_empty() || request.text.len() > 64 {
        return Err(AdapterError::invalid_argument());
    }
    let result = shared
        .call::<Note, _>(
            &caller(&window),
            request.text,
            512,
            CallOptions::default(),
            String::clone,
        )
        .await;
    if result.is_ok() {
        checks.calls.fetch_add(1, Ordering::SeqCst);
    }
    result
}

#[tauri::command]
fn qualification(checks: State<'_, Checks>) -> u64 {
    checks.seconds
}

#[tauri::command]
fn finish(success: bool, app: tauri::AppHandle, result: State<'_, Checks>) {
    result.success.store(success, Ordering::SeqCst);
    app.exit(if success { 0 } else { 1 });
}

fn main() {
    let report = std::env::args()
        .nth(1)
        .map(PathBuf::from)
        .expect("report path argument");
    let seconds = std::env::args()
        .nth(2)
        .map(|v| v.parse::<u64>().expect("soak seconds"))
        .unwrap_or(0);
    assert!(seconds <= 600, "soak is bounded to 600 seconds");
    let runtime = Runtime::builder(RuntimeConfig {
        max_concurrent_operations: 2,
        max_queued_operations: 4,
        max_concurrent_projections: 1,
        max_queued_projections: 2,
        default_deadline: Duration::from_secs(5),
        shutdown_grace: Duration::from_secs(1),
        cache_budget_bytes: 256,
    })
    .unwrap()
    .register(
        Note,
        OperationConfig {
            cache_budget_bytes: 256,
        },
    )
    .unwrap()
    .build();
    tauri::Builder::default()
        .manage(Checks {
            success: AtomicBool::new(false),
            calls: AtomicU64::new(0),
            started: Instant::now(),
            seconds,
        })
        .plugin(shared_runtime_tauri::init(
            runtime,
            AdapterConfig {
                abort_wait: Duration::from_secs(1),
            },
        ))
        .invoke_handler(tauri::generate_handler![note, finish, qualification])
        .build(tauri::generate_context!())
        .expect("build notes app")
        .run(move |app, event| {
            if let tauri::RunEvent::Exit = event {
                let shared = app.state::<SharedRuntime>();
                let stats = shared.runtime().stats();
                let note = stats.operation(Note::NAME).unwrap();
                let refused = tauri::async_runtime::block_on(
                    shared.runtime().operation::<Note>().unwrap().get(
                        &Caller::window("main"),
                        "after exit".into(),
                        CallOptions::default(),
                    ),
                );
                let checks = app.state::<Checks>();
                let calls = checks.calls.load(Ordering::SeqCst);
                let passed = checks.success.load(Ordering::SeqCst)
                    && calls >= checks.seconds + 3
                    && checks.started.elapsed() >= Duration::from_secs(checks.seconds)
                    && note.executed == 2
                    && note.cache_hits == calls - 2
                    && note.requests == calls
                    && note.outcomes() == calls
                    && note.cache_entries == 0
                    && note.in_flight == 0
                    && matches!(refused, Err(CallError::ShuttingDown));
                let result = serde_json::json!({"passed": passed, "executed": note.executed,
                    "cacheHits": note.cache_hits, "cacheEntriesAfterExit": note.cache_entries,
                    "refusedAfterExit": matches!(refused, Err(CallError::ShuttingDown)),
                    "completedCalls": calls, "soakSeconds": checks.seconds,
                    "elapsedSeconds": checks.started.elapsed().as_secs_f64()});
                std::fs::write(&report, serde_json::to_vec_pretty(&result).unwrap())
                    .expect("write report");
                if !passed {
                    std::process::exit(1);
                }
            }
        });
}
