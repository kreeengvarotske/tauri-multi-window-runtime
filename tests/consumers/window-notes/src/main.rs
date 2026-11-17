//! Independent backend consumer; no workspace path dependencies or WebView.
use shared_runtime::{
    CachePolicy, CallError, CallOptions, Caller, OpContext, Operation, OperationConfig, Runtime,
    RuntimeConfig, ScopeRule,
};
use std::{sync::Arc, time::Duration};

struct Note;

impl Operation for Note {
    const NAME: &'static str = "consumer.note";
    type Params = String;
    type Output = String;
    type Error = &'static str;

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
        if text.is_empty() || text.len() > 64 {
            Err("invalid note length")
        } else {
            Ok(text)
        }
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
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
    let note = runtime.operation::<Note>().unwrap();
    // Trusted backend callers. A Tauri command derives them from injected windows.
    let editor = Caller::window("editor");
    let other = Caller::window("other");
    let opts = CallOptions::default();
    let first = note.get(&editor, "draft".into(), opts).await.unwrap();
    let hit = note.get(&editor, "draft".into(), opts).await.unwrap();
    assert!(Arc::ptr_eq(&first, &hit));
    let isolated = note.get(&other, "draft".into(), opts).await.unwrap();
    assert!(!Arc::ptr_eq(&first, &isolated));
    assert!(note.get(&editor, String::new(), opts).await.is_err());
    assert_eq!(runtime.forget_window(&editor), 1);
    let fresh = note.get(&editor, "draft".into(), opts).await.unwrap();
    assert!(!Arc::ptr_eq(&first, &fresh));
    let retained = note.get(&other, "draft".into(), opts).await.unwrap();
    assert!(Arc::ptr_eq(&isolated, &retained));
    drop((first, hit, isolated, fresh, retained));
    runtime.shutdown().await;
    let stats = note.stats();
    assert_eq!(stats.cache_entries, 0);
    assert_eq!(stats.in_flight, 0);
    assert_eq!(stats.requests, stats.outcomes());
    assert!(matches!(
        note.get(&editor, "closed".into(), opts).await,
        Err(CallError::ShuttingDown)
    ));
    println!("WINDOW_NOTES_CONSUMER_PASS");
}
