//! The two request paths that are compared: plain (the operation runs for
//! every request) and runtime (requests go through `CachedService`).
//! Everything else, including the counters, is the same in both builds.

use serde::Serialize;
use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
};

/// How a request obtained its result.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum RunKind {
    Executed,
    Coalesced,
    CacheHit,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunResponse {
    /// The 64-bit checksum as 16 hex digits: a JS number cannot hold it.
    pub checksum: String,
    pub kind: RunKind,
}

/// Counters, read the same way in both builds.
///
/// `requests_received` grows when a request enters; the others when it
/// completes. A failed request counts in its kind and in `failed_requests`.
/// While no request is in flight,
/// `received = executed + coalesced + cache_hits`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BenchStats {
    pub requests_received: u64,
    pub operations_executed: u64,
    pub coalesced_requests: u64,
    pub cache_hits: u64,
    pub failed_requests: u64,
}

#[derive(Default)]
struct Counters {
    received: AtomicU64,
    executed: AtomicU64,
    coalesced: AtomicU64,
    hits: AtomicU64,
    failed: AtomicU64,
}

/// The operation behind every request. Production uses `work::work`; tests
/// substitute one whose timing they control.
pub type Operation = Arc<dyn Fn(&str) -> u64 + Send + Sync>;

pub struct Bench {
    operation: Operation,
    counters: Counters,
    #[cfg(feature = "runtime")]
    service: runtime_core::CachedService<String, u64, String>,
}

impl Bench {
    /// `ttl` is used only by the runtime build: `None` stores nothing.
    #[cfg_attr(not(feature = "runtime"), allow(unused_variables))]
    pub fn new(operation: Operation, ttl: Option<std::time::Duration>) -> Self {
        Self {
            operation,
            counters: Counters::default(),
            #[cfg(feature = "runtime")]
            service: runtime_core::CachedService::new(match ttl {
                Some(ttl) => runtime_core::CachePolicy::Ttl(ttl),
                None => runtime_core::CachePolicy::NoStore,
            }),
        }
    }

    pub fn stats(&self) -> BenchStats {
        let c = &self.counters;
        BenchStats {
            requests_received: c.received.load(Ordering::Relaxed),
            operations_executed: c.executed.load(Ordering::Relaxed),
            coalesced_requests: c.coalesced.load(Ordering::Relaxed),
            cache_hits: c.hits.load(Ordering::Relaxed),
            failed_requests: c.failed.load(Ordering::Relaxed),
        }
    }

    /// Runs the operation outside the measured path, for the expected checksum.
    pub async fn expected(&self, key: String) -> Result<String, String> {
        execute(&self.operation, key).await.map(hex)
    }

    /// Handles one request.
    pub async fn run(&self, key: String) -> Result<RunResponse, String> {
        self.counters.received.fetch_add(1, Ordering::Relaxed);
        let (result, kind) = self.run_path(key).await;
        let counter = match kind {
            RunKind::Executed => &self.counters.executed,
            RunKind::Coalesced => &self.counters.coalesced,
            RunKind::CacheHit => &self.counters.hits,
        };
        counter.fetch_add(1, Ordering::Relaxed);
        if result.is_err() {
            self.counters.failed.fetch_add(1, Ordering::Relaxed);
        }
        result.map(|checksum| RunResponse {
            checksum: hex(checksum),
            kind,
        })
    }

    #[cfg(not(feature = "runtime"))]
    async fn run_path(&self, key: String) -> (Result<u64, String>, RunKind) {
        (execute(&self.operation, key).await, RunKind::Executed)
    }

    #[cfg(feature = "runtime")]
    async fn run_path(&self, key: String) -> (Result<u64, String>, RunKind) {
        let operation = Arc::clone(&self.operation);
        let task_key = key.clone();
        let outcome = self
            .service
            .run_with_metadata(key, || execute(&operation, task_key))
            .await;
        let kind = match outcome.kind {
            runtime_core::ServiceRunKind::Executed => RunKind::Executed,
            runtime_core::ServiceRunKind::Coalesced => RunKind::Coalesced,
            runtime_core::ServiceRunKind::CacheHit => RunKind::CacheHit,
        };
        (
            outcome
                .result
                .map(|value| *value)
                .map_err(|error| (*error).clone()),
            kind,
        )
    }
}

/// Runs the operation on the blocking pool, so it never holds an async
/// worker thread of the Tauri runtime.
async fn execute(operation: &Operation, key: String) -> Result<u64, String> {
    let operation = Arc::clone(operation);
    tokio::task::spawn_blocking(move || operation(&key))
        .await
        .map_err(|error| format!("operation failed: {error}"))
}

fn hex(checksum: u64) -> String {
    format!("{checksum:016x}")
}

#[cfg(test)]
mod tests {
    use super::{Bench, BenchStats, Operation, RunKind};
    use std::{
        sync::{
            Arc,
            atomic::{AtomicU64, Ordering},
        },
        time::Duration,
    };

    const RUNTIME: bool = cfg!(feature = "runtime");

    /// An operation that takes `delay` and counts how often it really ran.
    fn slow_operation(delay: Duration) -> (Operation, Arc<AtomicU64>) {
        let calls = Arc::new(AtomicU64::new(0));
        let counted = Arc::clone(&calls);
        let operation: Operation = Arc::new(move |key: &str| {
            counted.fetch_add(1, Ordering::SeqCst);
            std::thread::sleep(delay);
            key.len() as u64
        });
        (operation, calls)
    }

    /// Sends all requests at once, as two windows do in one round.
    async fn round(bench: &Arc<Bench>, keys: Vec<String>) -> Vec<RunKind> {
        let handles: Vec<_> = keys
            .into_iter()
            .map(|key| {
                let bench = Arc::clone(bench);
                tokio::spawn(async move { bench.run(key).await.unwrap().kind })
            })
            .collect();
        let mut kinds = Vec::new();
        for handle in handles {
            kinds.push(handle.await.unwrap());
        }
        kinds
    }

    fn same_key(n: usize) -> Vec<String> {
        vec!["project".to_owned(); n]
    }

    fn distinct_keys(n: usize) -> Vec<String> {
        (0..n).map(|i| format!("key-{i}")).collect()
    }

    fn assert_idle_invariant(stats: BenchStats) {
        assert_eq!(
            stats.requests_received,
            stats.operations_executed + stats.coalesced_requests + stats.cache_hits,
            "{stats:?}"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn s1_one_request_runs_the_operation_once() {
        let (operation, calls) = slow_operation(Duration::from_millis(10));
        let bench = Arc::new(Bench::new(operation, None));
        assert_eq!(round(&bench, same_key(1)).await, vec![RunKind::Executed]);
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert_eq!(bench.stats().operations_executed, 1);
        assert_idle_invariant(bench.stats());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn s2_concurrent_requests_for_one_key() {
        let (operation, calls) = slow_operation(Duration::from_millis(200));
        let bench = Arc::new(Bench::new(operation, None));
        round(&bench, same_key(20)).await;
        let stats = bench.stats();
        assert_eq!(stats.requests_received, 20);
        if RUNTIME {
            assert_eq!(
                (stats.operations_executed, stats.coalesced_requests),
                (1, 19)
            );
            assert_eq!(calls.load(Ordering::SeqCst), 1);
        } else {
            assert_eq!(
                (stats.operations_executed, stats.coalesced_requests),
                (20, 0)
            );
            assert_eq!(calls.load(Ordering::SeqCst), 20);
        }
        assert_eq!(stats.cache_hits, 0);
        assert_idle_invariant(stats);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn s3_distinct_keys_are_never_coalesced() {
        let (operation, calls) = slow_operation(Duration::from_millis(100));
        let bench = Arc::new(Bench::new(operation, None));
        round(&bench, distinct_keys(20)).await;
        let stats = bench.stats();
        assert_eq!(
            (
                stats.operations_executed,
                stats.coalesced_requests,
                stats.cache_hits
            ),
            (20, 0, 0)
        );
        assert_eq!(calls.load(Ordering::SeqCst), 20);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn s4_rounds_within_the_ttl_reuse_the_result() {
        let (operation, calls) = slow_operation(Duration::from_millis(100));
        let bench = Arc::new(Bench::new(operation, Some(Duration::from_secs(3600))));
        for _ in 0..3 {
            round(&bench, same_key(20)).await;
        }
        let stats = bench.stats();
        assert_eq!(stats.requests_received, 60);
        if RUNTIME {
            assert_eq!(
                (
                    stats.operations_executed,
                    stats.coalesced_requests,
                    stats.cache_hits
                ),
                (1, 19, 40)
            );
            assert_eq!(calls.load(Ordering::SeqCst), 1);
        } else {
            assert_eq!(stats.operations_executed, 60);
        }
        assert_idle_invariant(stats);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn s4_runs_the_operation_again_after_the_ttl_expires() {
        let (operation, calls) = slow_operation(Duration::from_millis(5));
        let bench = Arc::new(Bench::new(operation, Some(Duration::from_millis(100))));
        round(&bench, same_key(1)).await;
        let second = round(&bench, same_key(1)).await;
        tokio::time::sleep(Duration::from_millis(150)).await;
        let third = round(&bench, same_key(1)).await;
        if RUNTIME {
            assert_eq!(second, vec![RunKind::CacheHit]);
            assert_eq!(calls.load(Ordering::SeqCst), 2);
        } else {
            assert_eq!(calls.load(Ordering::SeqCst), 3);
        }
        assert_eq!(third, vec![RunKind::Executed]);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_failed_operation_is_counted_and_never_cached() {
        let calls = Arc::new(AtomicU64::new(0));
        let counted = Arc::clone(&calls);
        let operation: Operation = Arc::new(move |_key: &str| {
            counted.fetch_add(1, Ordering::SeqCst);
            panic!("operation broke");
        });
        let bench = Bench::new(operation, Some(Duration::from_secs(3600)));
        assert!(bench.run("k".to_owned()).await.is_err());
        assert!(bench.run("k".to_owned()).await.is_err());
        let stats = bench.stats();
        assert_eq!(
            (
                stats.operations_executed,
                stats.failed_requests,
                stats.cache_hits
            ),
            (2, 2, 0)
        );
        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn the_operation_does_not_block_the_async_runtime() {
        // One async thread: if the operation ran on it, the timer below could
        // not fire before the operation finished.
        let (operation, _) = slow_operation(Duration::from_millis(300));
        let bench = Arc::new(Bench::new(operation, None));
        let running = Arc::clone(&bench);
        let request = tokio::spawn(async move { running.run("k".to_owned()).await });
        tokio::time::sleep(Duration::from_millis(50)).await;
        let stats = bench.stats();
        assert_eq!((stats.requests_received, stats.operations_executed), (1, 0));
        assert!(!request.is_finished());
        request.await.unwrap().unwrap();
        assert_eq!(bench.stats().operations_executed, 1);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn expected_does_not_touch_the_counters() {
        let (operation, _) = slow_operation(Duration::from_millis(1));
        let bench = Bench::new(operation, Some(Duration::from_secs(3600)));
        assert_eq!(
            bench.expected("abc".to_owned()).await.unwrap(),
            "0000000000000003"
        );
        assert_eq!(bench.stats(), BenchStats::default());
        // ...and does not fill the cache.
        assert_eq!(
            bench.run("abc".to_owned()).await.unwrap().kind,
            RunKind::Executed
        );
    }
}
