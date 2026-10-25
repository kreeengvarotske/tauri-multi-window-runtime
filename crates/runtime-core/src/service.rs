use crate::{CoalescerRunKind, TaskCoalescer, cache::PolicyCache, cache_policy::CachePolicy};
use std::{
    collections::HashMap,
    future::Future,
    hash::Hash,
    sync::{Arc, Mutex},
};

/// Describes how a service call obtained its result.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServiceRunKind {
    /// The result was read from the cache.
    CacheHit,
    /// The call shared an operation started by another caller.
    Coalesced,
    /// This call initialized and executed the operation.
    Executed,
}

/// The result of a service call, including execution metadata.
#[derive(Debug)]
pub struct ServiceRunOutcome<V, E> {
    /// The successful value or the shared operation error.
    pub result: Result<Arc<V>, Arc<E>>,
    /// How this call obtained its result.
    pub kind: ServiceRunKind,
}

/// Internal wrapper that allows sharing a value through the coalescer.
struct CachedValue<V>(Arc<V>);

/// Generation and active-call count for one key with work in flight.
struct KeyGeneration {
    version: u64,
    active_calls: usize,
}

/// A service-wide generation invalidates all work; per-key generations
/// invalidate only the affected key. Idle key entries are removed by the guard.
struct GenerationState<K> {
    global_version: u64,
    keys: HashMap<K, KeyGeneration>,
}

impl<K> Default for GenerationState<K> {
    fn default() -> Self {
        Self {
            global_version: 0,
            keys: HashMap::new(),
        }
    }
}

/// Keeps a key-generation entry alive while any run call for that key is active.
struct KeyCallGuard<'a, K: Eq + Hash> {
    state: &'a Mutex<GenerationState<K>>,
    key: K,
}

impl<K> Drop for KeyCallGuard<'_, K>
where
    K: Eq + Hash,
{
    fn drop(&mut self) {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());

        let remove_entry = match state.keys.get_mut(&self.key) {
            Some(key_state) => {
                debug_assert!(key_state.active_calls > 0);
                key_state.active_calls -= 1;
                key_state.active_calls == 0
            }
            None => false,
        };

        if remove_entry {
            state.keys.remove(&self.key);
        }
    }
}

/// Combines cache lookup, concurrent request coalescing,
/// and successful-result caching.
///
/// Errors are never cached. `invalidate` advances only the affected key's
/// generation, while `clear` advances the service-wide generation.
pub struct CachedService<K, V, E> {
    cache: PolicyCache<K, V>,
    coalescer: TaskCoalescer<(K, u64, u64), CachedValue<V>, E>,
    policy: CachePolicy,
    generation: Mutex<GenerationState<K>>,
}

impl<K, V, E> CachedService<K, V, E>
where
    K: Eq + Hash + Clone,
{
    /// Creates a service using one cache policy for all keys.
    pub fn new(policy: CachePolicy) -> Self {
        Self {
            cache: PolicyCache::new(),
            coalescer: TaskCoalescer::new(),
            policy,
            generation: Mutex::new(GenerationState::default()),
        }
    }

    /// Returns a value or error using the original API.
    ///
    /// This method remains compatible with existing callers.
    pub async fn run<F, Fut>(&self, key: K, operation: F) -> Result<Arc<V>, Arc<E>>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<V, E>>,
    {
        self.run_with_metadata(key, operation).await.result
    }

    /// Like `run`, but also reports how the result was obtained.
    ///
    /// `CacheHit` means the value was found in the cache.
    /// `Coalesced` means another caller initialized the shared operation.
    /// `Executed` means this caller initialized the shared operation.
    ///
    /// Errors are returned in `outcome.result` and are not cached.
    pub async fn run_with_metadata<F, Fut>(&self, key: K, operation: F) -> ServiceRunOutcome<V, E>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<V, E>>,
    {
        // Keep cache lookup, generation capture, and invalidation ordered by the
        // same mutex. Each in-flight call also keeps its key state alive.
        let (global_version, key_version) = {
            let mut generations = self
                .generation
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            // Test-only: keep this inside the section that captures versions.
            #[cfg(test)]
            probe::mark();

            if let Some(value) = self.cache.get(&key) {
                return ServiceRunOutcome {
                    result: Ok(value),
                    kind: ServiceRunKind::CacheHit,
                };
            }

            let global_version = generations.global_version;
            let key_state = generations
                .keys
                .entry(key.clone())
                .or_insert(KeyGeneration {
                    version: 0,
                    active_calls: 0,
                });
            key_state.active_calls += 1;

            let key_version = key_state.version;
            (global_version, key_version)
        };
        let _key_call_guard = KeyCallGuard {
            state: &self.generation,
            key: key.clone(),
        };

        let cache = &self.cache;
        let generation_gate = &self.generation;
        let policy = self.policy;
        let cache_key = key.clone();

        let (result, coalescer_kind) = self
            .coalescer
            .run_with_kind((key, global_version, key_version), || async move {
                let value = operation().await?;
                let value = Arc::new(value);

                // An invalidation during the operation prevents stale insertion,
                // but invalidating a different key leaves this result cacheable.
                let current_generation = generation_gate
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());

                let may_cache = current_generation.global_version == global_version
                    && current_generation
                        .keys
                        .get(&cache_key)
                        .is_some_and(|key_state| key_state.version == key_version);

                if may_cache {
                    cache.insert_arc(cache_key, Arc::clone(&value), policy);
                }

                Ok(CachedValue(value))
            })
            .await;

        let result = result.map(|shared| Arc::clone(&shared.0));

        let kind = match coalescer_kind {
            CoalescerRunKind::Executed => ServiceRunKind::Executed,
            CoalescerRunKind::Coalesced => ServiceRunKind::Coalesced,
        };

        ServiceRunOutcome { result, kind }
    }

    /// Invalidates a key and separates future calls for that key from older work.
    ///
    /// In-flight operations for other keys remain cacheable. A key generation
    /// is kept only while calls for that key are active. Returns `true` if a
    /// cached entry existed.
    pub fn invalidate(&self, key: &K) -> bool {
        let mut generations = self
            .generation
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        #[cfg(test)]
        probe::mark();

        if let Some(key_state) = generations.keys.get_mut(key) {
            key_state.version = key_state.version.wrapping_add(1);
        }

        self.cache.invalidate(key)
    }

    /// Clears all cached values and separates future calls from older work.
    ///
    /// Existing callers may still receive their results, but those results
    /// cannot repopulate the cache after this call.
    pub fn clear(&self) {
        let mut generation = self
            .generation
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        #[cfg(test)]
        probe::mark();

        generation.global_version = generation.global_version.wrapping_add(1);
        self.cache.clear();
    }

    /// Returns the number of live cached entries, pruning expired entries first.
    pub fn cached_entries(&self) -> usize {
        self.cache.len()
    }

    /// Returns the policy used for values computed by this service.
    pub const fn policy(&self) -> CachePolicy {
        self.policy
    }
}

/// Test-only event clock for the concurrency tests.
///
/// `mark` runs inside the `generation` critical sections of `run_with_metadata`,
/// `invalidate` and `clear`, so the ticks it hands out follow the order in which
/// those sections ran. It only bumps an atomic and writes a task-local cell; it
/// takes no lock and never awaits, and it is compiled only under `cfg(test)`.
#[cfg(test)]
pub(crate) mod probe {
    use std::{
        cell::Cell,
        sync::atomic::{AtomicU64, Ordering},
    };
    static CLOCK: AtomicU64 = AtomicU64::new(1);

    tokio::task_local! {
        /// Receives the tick of the last `mark` made by the current task.
        pub(crate) static MARK: Cell<u64>;
    }

    pub(crate) fn mark() {
        let tick = CLOCK.fetch_add(1, Ordering::SeqCst);
        let _ = MARK.try_with(|cell| cell.set(tick));
    }

    /// A tick taken outside the service, on the same clock.
    pub(crate) fn now() -> u64 {
        CLOCK.fetch_add(1, Ordering::SeqCst)
    }
}

#[cfg(test)]
impl<K, V, E> CachedService<K, V, E>
where
    K: Eq + Hash + Clone,
{
    pub(crate) fn in_flight_keys(&self) -> usize {
        self.generation.lock().unwrap().keys.len()
    }
    pub(crate) fn in_flight_tasks(&self) -> usize {
        self.coalescer.test_len()
    }
    pub(crate) fn in_flight_callers(&self) -> usize {
        self.coalescer.test_callers()
    }
}

#[cfg(test)]
mod tests {
    use super::{CachedService, ServiceRunKind};
    use crate::cache_policy::CachePolicy;
    use std::{
        sync::{
            Arc,
            atomic::{AtomicUsize, Ordering},
        },
        time::Duration,
    };
    use tokio::task::JoinSet;

    #[tokio::test]
    async fn caches_successful_results() {
        let service = CachedService::<String, usize, String>::new(CachePolicy::Forever);
        let executions = AtomicUsize::new(0);
        let key = "settings".to_owned();

        let first = service
            .run(key.clone(), || async {
                executions.fetch_add(1, Ordering::SeqCst);
                Ok(42)
            })
            .await
            .unwrap();

        let second = service
            .run(key, || async {
                executions.fetch_add(1, Ordering::SeqCst);
                Ok(100)
            })
            .await
            .unwrap();

        assert_eq!(*first, 42);
        assert_eq!(*second, 42);
        assert_eq!(executions.load(Ordering::SeqCst), 1);
        assert_eq!(service.cached_entries(), 1);
    }

    #[tokio::test]
    async fn no_store_recomputes_each_time() {
        let service = CachedService::<String, usize, String>::new(CachePolicy::NoStore);
        let executions = AtomicUsize::new(0);
        let key = "uncached".to_owned();

        let first = service
            .run(key.clone(), || async {
                executions.fetch_add(1, Ordering::SeqCst);
                Ok(1)
            })
            .await
            .unwrap();

        let second = service
            .run(key, || async {
                executions.fetch_add(1, Ordering::SeqCst);
                Ok(2)
            })
            .await
            .unwrap();

        assert_eq!(*first, 1);
        assert_eq!(*second, 2);
        assert_eq!(executions.load(Ordering::SeqCst), 2);
        assert_eq!(service.cached_entries(), 0);
    }

    #[tokio::test]
    async fn errors_are_not_cached() {
        let service = CachedService::<String, usize, String>::new(CachePolicy::Forever);
        let executions = AtomicUsize::new(0);

        for _ in 0..2 {
            let error = service
                .run("unstable".to_owned(), || async {
                    executions.fetch_add(1, Ordering::SeqCst);
                    Err::<usize, String>("temporary failure".to_owned())
                })
                .await
                .unwrap_err();

            assert_eq!(error.as_str(), "temporary failure");
        }

        assert_eq!(executions.load(Ordering::SeqCst), 2);
        assert_eq!(service.cached_entries(), 0);
    }

    #[tokio::test]
    async fn expired_value_is_recomputed() {
        let service = CachedService::<String, usize, String>::new(CachePolicy::Ttl(
            Duration::from_millis(10),
        ));
        let executions = AtomicUsize::new(0);
        let key = "short-lived".to_owned();

        let first = service
            .run(key.clone(), || async {
                executions.fetch_add(1, Ordering::SeqCst);
                Ok(1)
            })
            .await
            .unwrap();

        tokio::time::sleep(Duration::from_millis(25)).await;

        let second = service
            .run(key, || async {
                executions.fetch_add(1, Ordering::SeqCst);
                Ok(2)
            })
            .await
            .unwrap();

        assert_eq!(*first, 1);
        assert_eq!(*second, 2);
        assert_eq!(executions.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn invalidate_forces_recomputation() {
        let service = CachedService::<String, usize, String>::new(CachePolicy::Forever);
        let executions = AtomicUsize::new(0);
        let key = "refreshable".to_owned();

        let first = service
            .run(key.clone(), || async {
                executions.fetch_add(1, Ordering::SeqCst);
                Ok(1)
            })
            .await
            .unwrap();

        assert_eq!(*first, 1);
        assert!(service.invalidate(&key));
        assert!(!service.invalidate(&key));

        let second = service
            .run(key, || async {
                executions.fetch_add(1, Ordering::SeqCst);
                Ok(2)
            })
            .await
            .unwrap();

        assert_eq!(*second, 2);
        assert_eq!(executions.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn coalesces_concurrent_requests_and_caches_result() {
        let service = Arc::new(CachedService::<String, usize, String>::new(
            CachePolicy::Forever,
        ));
        let executions = Arc::new(AtomicUsize::new(0));
        let mut tasks = JoinSet::new();

        for _ in 0..20 {
            let service = Arc::clone(&service);
            let executions = Arc::clone(&executions);

            tasks.spawn(async move {
                service
                    .run("shared".to_owned(), || async move {
                        executions.fetch_add(1, Ordering::SeqCst);
                        tokio::time::sleep(Duration::from_millis(100)).await;
                        Ok(42)
                    })
                    .await
            });
        }

        for _ in 0..20 {
            let result = tasks.join_next().await.unwrap().unwrap().unwrap();
            assert_eq!(*result, 42);
        }

        assert_eq!(executions.load(Ordering::SeqCst), 1);
        assert_eq!(service.cached_entries(), 1);
    }

    #[tokio::test]
    async fn invalidation_during_operation_prevents_stale_cache_insert() {
        let service = Arc::new(CachedService::<String, usize, String>::new(
            CachePolicy::Forever,
        ));
        let started = Arc::new(tokio::sync::Notify::new());

        let first_service = Arc::clone(&service);
        let first_started = Arc::clone(&started);

        let first_task = tokio::spawn(async move {
            first_service
                .run("resource".to_owned(), || async move {
                    first_started.notify_one();
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    Ok(1)
                })
                .await
        });

        started.notified().await;
        service.invalidate(&"resource".to_owned());

        // The post-invalidation call gets a new generation and computes independently.
        let fresh = service
            .run("resource".to_owned(), || async { Ok(2) })
            .await
            .unwrap();

        assert_eq!(*fresh, 2);

        // The earlier caller still receives its result, but cannot overwrite the cache.
        let old = first_task.await.unwrap().unwrap();
        assert_eq!(*old, 1);

        let cached = service
            .run("resource".to_owned(), || async { Ok(3) })
            .await
            .unwrap();

        assert_eq!(*cached, 2);
    }

    #[tokio::test]
    async fn reports_executed_then_cache_hit() {
        let service = CachedService::<String, usize, String>::new(CachePolicy::Forever);

        let first = service
            .run_with_metadata("settings".to_owned(), || async { Ok(42) })
            .await;

        assert_eq!(first.kind, ServiceRunKind::Executed);
        assert_eq!(*first.result.unwrap(), 42);

        let second = service
            .run_with_metadata("settings".to_owned(), || async { Ok(100) })
            .await;

        assert_eq!(second.kind, ServiceRunKind::CacheHit);
        assert_eq!(*second.result.unwrap(), 42);
    }

    #[tokio::test]
    async fn reports_coalesced_for_concurrent_request() {
        let service = Arc::new(CachedService::<String, usize, String>::new(
            CachePolicy::Forever,
        ));

        let first_started = Arc::new(tokio::sync::Notify::new());
        let release = Arc::new(tokio::sync::Notify::new());
        let first_service = Arc::clone(&service);
        let first_signal = Arc::clone(&first_started);
        let first_release = Arc::clone(&release);

        let first_task = tokio::spawn(async move {
            first_service
                .run_with_metadata("shared".to_owned(), || async move {
                    first_signal.notify_one();
                    first_release.notified().await;
                    Ok(42)
                })
                .await
        });

        first_started.notified().await;

        let second_service = Arc::clone(&service);
        let second_task = tokio::spawn(async move {
            second_service
                .run_with_metadata("shared".to_owned(), || async { Ok(99) })
                .await
        });

        // Release the operation only after the second call has joined it.
        tokio::time::timeout(Duration::from_secs(5), async {
            while service.in_flight_callers() < 2 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("second caller did not join the shared operation");
        release.notify_one();

        let first = first_task.await.unwrap();
        let second = second_task.await.unwrap();

        assert_eq!(first.kind, ServiceRunKind::Executed);
        assert_eq!(second.kind, ServiceRunKind::Coalesced);
        assert_eq!(*first.result.unwrap(), 42);
        assert_eq!(*second.result.unwrap(), 42);
    }

    #[tokio::test]
    async fn invalidating_one_key_does_not_block_another_key_from_being_cached() {
        let service = Arc::new(CachedService::<String, usize, String>::new(
            CachePolicy::Forever,
        ));
        let started = Arc::new(tokio::sync::Notify::new());
        let release = Arc::new(tokio::sync::Notify::new());
        let executions = Arc::new(AtomicUsize::new(0));

        let task_service = Arc::clone(&service);
        let task_started = Arc::clone(&started);
        let task_release = Arc::clone(&release);
        let task_executions = Arc::clone(&executions);
        let task = tokio::spawn(async move {
            task_service
                .run("unrelated".to_owned(), || async move {
                    task_executions.fetch_add(1, Ordering::SeqCst);
                    task_started.notify_one();
                    task_release.notified().await;
                    Ok(42)
                })
                .await
        });

        started.notified().await;

        // Invalidating a key with no active calls must not affect this operation.
        assert!(!service.invalidate(&"different".to_owned()));
        release.notify_one();

        let first = task.await.unwrap().unwrap();
        assert_eq!(*first, 42);

        // If invalidation had changed the service-wide generation, the first
        // result would not have been cached and this closure would run again.
        let cached = service
            .run("unrelated".to_owned(), || async {
                executions.fetch_add(1, Ordering::SeqCst);
                Ok(100)
            })
            .await
            .unwrap();

        assert_eq!(*cached, 42);
        assert_eq!(executions.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn idle_key_generation_entries_are_released() {
        let service = CachedService::<String, usize, String>::new(CachePolicy::Forever);

        for index in 0..100 {
            let key = format!("key-{index}");
            service
                .run(key.clone(), || async { Ok::<usize, String>(1) })
                .await
                .unwrap();
            service.invalidate(&key);
        }

        let generations = service
            .generation
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());

        assert!(
            generations.keys.is_empty(),
            "idle per-key generation entries must not accumulate"
        );
    }

    #[tokio::test]
    async fn reports_execution_kind_when_operation_fails() {
        let service = CachedService::<String, usize, String>::new(CachePolicy::Forever);

        let outcome = service
            .run_with_metadata("failing".to_owned(), || async {
                Err::<usize, String>("expected failure".to_owned())
            })
            .await;

        assert_eq!(outcome.kind, ServiceRunKind::Executed);
        assert_eq!(outcome.result.unwrap_err().as_str(), "expected failure");
        assert_eq!(service.cached_entries(), 0);
    }
}

/// Multi-threaded regression tests for coalescing, invalidation, cancellation
/// and in-flight cleanup. T-numbers refer to the stage 1 Core test plan.
#[cfg(test)]
mod concurrency {
    use super::{CachedService, ServiceRunKind, probe};
    use crate::cache_policy::CachePolicy;
    use std::{
        cell::Cell,
        sync::{
            Arc, Mutex,
            atomic::{AtomicUsize, Ordering},
        },
        time::Duration,
    };
    use tokio::{sync::Notify, time::timeout};

    #[derive(Debug, Clone, PartialEq)]
    struct Val {
        key: u8,
        executor: u64,
    }

    const LIMIT: Duration = Duration::from_secs(5);

    async fn wait_until(mut cond: impl FnMut() -> bool, what: &str) {
        timeout(LIMIT, async {
            while !cond() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap_or_else(|_| panic!("timed out waiting for: {what}"));
    }

    // ---- T1 ----
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn t1_same_key_coalesces_to_one_execution() {
        let svc = Arc::new(CachedService::<u8, Val, String>::new(CachePolicy::Forever));
        let gate = Arc::new(tokio::sync::Semaphore::new(0));
        let executions = Arc::new(AtomicUsize::new(0));
        let mut hs = Vec::new();
        for id in 0..20u64 {
            let (svc, gate, executions) = (svc.clone(), gate.clone(), executions.clone());
            hs.push(tokio::spawn(async move {
                svc.run_with_metadata(1, move || async move {
                    executions.fetch_add(1, Ordering::SeqCst);
                    let _open = gate.acquire().await.unwrap();
                    Ok(Val {
                        key: 1,
                        executor: id,
                    })
                })
                .await
            }));
        }
        wait_until(|| svc.in_flight_callers() == 20, "20 callers registered").await;
        gate.add_permits(1);
        let mut kinds = Vec::new();
        let mut executors = std::collections::HashSet::new();
        for h in hs {
            let r = timeout(LIMIT, h).await.unwrap().unwrap();
            kinds.push(r.kind);
            executors.insert(r.result.unwrap().executor);
        }
        assert_eq!(executions.load(Ordering::SeqCst), 1);
        assert_eq!(
            kinds
                .iter()
                .filter(|k| **k == ServiceRunKind::Executed)
                .count(),
            1
        );
        assert_eq!(
            kinds
                .iter()
                .filter(|k| **k == ServiceRunKind::Coalesced)
                .count(),
            19
        );
        assert_eq!(executors.len(), 1, "callers received different results");
        assert_eq!(svc.cached_entries(), 1);
        assert_eq!((svc.in_flight_tasks(), svc.in_flight_keys()), (0, 0));
    }

    fn gated(
        svc: &Arc<CachedService<u8, Val, String>>,
        key: u8,
        executor: u64,
        gate: &Arc<Notify>,
        started: &Arc<Notify>,
        fail: bool,
    ) -> tokio::task::JoinHandle<super::ServiceRunOutcome<Val, String>> {
        let (svc, gate, started) = (svc.clone(), gate.clone(), started.clone());
        tokio::spawn(async move {
            svc.run_with_metadata(key, move || async move {
                started.notify_one();
                gate.notified().await;
                if fail {
                    Err(format!("fail-{executor}"))
                } else {
                    Ok(Val { key, executor })
                }
            })
            .await
        })
    }

    fn spawn_plain(
        svc: &Arc<CachedService<u8, Val, String>>,
        key: u8,
        executor: u64,
    ) -> tokio::task::JoinHandle<super::ServiceRunOutcome<Val, String>> {
        let svc = svc.clone();
        tokio::spawn(async move {
            svc.run_with_metadata(key, move || async move { Ok(Val { key, executor }) })
                .await
        })
    }

    // ---- T3 ----
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn t3_invalidate_in_flight_is_isolated_per_key() {
        let svc = Arc::new(CachedService::<u8, Val, String>::new(CachePolicy::Forever));
        let (ga, sa, go, so) = (
            Arc::new(Notify::new()),
            Arc::new(Notify::new()),
            Arc::new(Notify::new()),
            Arc::new(Notify::new()),
        );
        let a = gated(&svc, 1, 1, &ga, &sa, false);
        let o = gated(&svc, 2, 2, &go, &so, false);
        timeout(LIMIT, sa.notified()).await.unwrap();
        timeout(LIMIT, so.notified()).await.unwrap();
        assert!(!svc.invalidate(&1));
        let n = spawn_plain(&svc, 1, 3);
        // N either completes on its own or is registered somewhere (3 callers in total)
        wait_until(
            || n.is_finished() || svc.in_flight_callers() >= 3,
            "N finished or registered",
        )
        .await;
        ga.notify_one();
        go.notify_one();
        let n = timeout(LIMIT, n).await.unwrap().unwrap();
        assert_eq!(
            (n.kind, n.result.unwrap().executor),
            (ServiceRunKind::Executed, 3),
            "N joined the pre-invalidate operation"
        );
        let a = a.await.unwrap();
        let o = o.await.unwrap();
        assert_eq!(
            (a.kind, a.result.unwrap().executor),
            (ServiceRunKind::Executed, 1)
        );
        assert_eq!(
            (o.kind, o.result.unwrap().executor),
            (ServiceRunKind::Executed, 2)
        );
        let k1 = svc
            .run_with_metadata(1, || async {
                Ok(Val {
                    key: 1,
                    executor: 9,
                })
            })
            .await;
        assert_eq!(
            (k1.kind, k1.result.unwrap().executor),
            (ServiceRunKind::CacheHit, 3)
        );
        let k2 = svc
            .run_with_metadata(2, || async {
                Ok(Val {
                    key: 2,
                    executor: 9,
                })
            })
            .await;
        assert_eq!(
            (k2.kind, k2.result.unwrap().executor),
            (ServiceRunKind::CacheHit, 2),
            "invalidate(1) affected key 2"
        );
        assert_eq!((svc.in_flight_tasks(), svc.in_flight_keys()), (0, 0));
    }

    // ---- T5 ----
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn t5_clear_in_flight_cannot_repopulate() {
        let svc = Arc::new(CachedService::<u8, Val, String>::new(CachePolicy::Forever));
        let (ga, sa, gb, sb) = (
            Arc::new(Notify::new()),
            Arc::new(Notify::new()),
            Arc::new(Notify::new()),
            Arc::new(Notify::new()),
        );
        let a = gated(&svc, 1, 1, &ga, &sa, false);
        let b = gated(&svc, 2, 2, &gb, &sb, false);
        timeout(LIMIT, sa.notified()).await.unwrap();
        timeout(LIMIT, sb.notified()).await.unwrap();
        svc.clear();
        let n = spawn_plain(&svc, 1, 3);
        wait_until(
            || n.is_finished() || svc.in_flight_callers() >= 3,
            "N finished or registered",
        )
        .await;
        ga.notify_one();
        gb.notify_one();
        let n = timeout(LIMIT, n).await.unwrap().unwrap();
        assert_eq!(
            (n.kind, n.result.unwrap().executor),
            (ServiceRunKind::Executed, 3),
            "N joined the pre-clear operation"
        );
        assert_eq!(a.await.unwrap().result.unwrap().executor, 1);
        assert_eq!(b.await.unwrap().result.unwrap().executor, 2);
        assert_eq!(
            svc.cached_entries(),
            1,
            "pre-clear result repopulated the cache"
        );
        let k1 = svc
            .run_with_metadata(1, || async {
                Ok(Val {
                    key: 1,
                    executor: 9,
                })
            })
            .await;
        assert_eq!(
            (k1.kind, k1.result.unwrap().executor),
            (ServiceRunKind::CacheHit, 3)
        );
        let k2 = svc
            .run_with_metadata(2, || async {
                Ok(Val {
                    key: 2,
                    executor: 9,
                })
            })
            .await;
        assert_eq!(
            (k2.kind, k2.result.unwrap().executor),
            (ServiceRunKind::Executed, 9)
        );
        assert_eq!((svc.in_flight_tasks(), svc.in_flight_keys()), (0, 0));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn t5b_clear_during_failing_operation() {
        let svc = Arc::new(CachedService::<u8, Val, String>::new(CachePolicy::Forever));
        let (ga, sa) = (Arc::new(Notify::new()), Arc::new(Notify::new()));
        let a = gated(&svc, 1, 1, &ga, &sa, true);
        timeout(LIMIT, sa.notified()).await.unwrap();
        svc.clear();
        ga.notify_one();
        assert_eq!(a.await.unwrap().result.unwrap_err().as_str(), "fail-1");
        assert_eq!(svc.cached_entries(), 0);
        let n = svc
            .run_with_metadata(1, || async {
                Ok(Val {
                    key: 1,
                    executor: 3,
                })
            })
            .await;
        assert_eq!(
            (n.kind, n.result.unwrap().executor),
            (ServiceRunKind::Executed, 3)
        );
        assert_eq!((svc.in_flight_tasks(), svc.in_flight_keys()), (0, 0));
    }

    // ---- T9 ----
    async fn t9_case(case: &str) {
        let svc = Arc::new(CachedService::<u8, Val, String>::new(CachePolicy::Forever));
        let (gate, started) = (Arc::new(Notify::new()), Arc::new(Notify::new()));
        let a = {
            let (svc, gate, started) = (svc.clone(), gate.clone(), started.clone());
            let case = case.to_owned();
            tokio::spawn(async move {
                svc.run_with_metadata(1, move || async move {
                    started.notify_one();
                    match case.as_str() {
                        "cancel" | "cancel_all" => std::future::pending::<()>().await,
                        _ => gate.notified().await,
                    }
                    match case.as_str() {
                        "error" => Err("boom".to_owned()),
                        "panic" => panic!("operation panicked (expected in t9)"),
                        _ => Ok(Val {
                            key: 1,
                            executor: 1,
                        }),
                    }
                })
                .await
            })
        };
        timeout(LIMIT, started.notified()).await.unwrap();
        let w = {
            let svc = svc.clone();
            tokio::spawn(async move {
                svc.run_with_metadata(1, || async {
                    Ok(Val {
                        key: 1,
                        executor: 2,
                    })
                })
                .await
            })
        };
        wait_until(|| svc.in_flight_callers() == 2, "waiter joined").await;
        match case {
            "success" | "error" => {
                gate.notify_one();
                let a = a.await.unwrap();
                let w = w.await.unwrap();
                assert_eq!(a.kind, ServiceRunKind::Executed);
                assert_eq!(w.kind, ServiceRunKind::Coalesced);
                assert_eq!(a.result.is_ok(), case == "success");
                assert_eq!(w.result.is_ok(), case == "success");
            }
            "cancel" => {
                a.abort();
                assert!(a.await.unwrap_err().is_cancelled());
                let w = timeout(LIMIT, w).await.unwrap().unwrap();
                assert_eq!(
                    (w.kind, w.result.unwrap().executor),
                    (ServiceRunKind::Executed, 2)
                );
            }
            "panic" => {
                gate.notify_one();
                assert!(a.await.unwrap_err().is_panic());
                let w = timeout(LIMIT, w).await.unwrap().unwrap();
                assert_eq!(
                    (w.kind, w.result.unwrap().executor),
                    (ServiceRunKind::Executed, 2)
                );
            }
            "cancel_all" => {
                w.abort();
                a.abort();
                let _ = w.await;
                let _ = a.await;
            }
            _ => unreachable!(),
        }
        assert_eq!(
            (svc.in_flight_tasks(), svc.in_flight_keys()),
            (0, 0),
            "in-flight state leaked after {case}"
        );
        let next = svc
            .run_with_metadata(1, || async {
                Ok(Val {
                    key: 1,
                    executor: 3,
                })
            })
            .await;
        assert!(next.result.is_ok(), "service unusable after {case}");
        assert_eq!((svc.in_flight_tasks(), svc.in_flight_keys()), (0, 0));
    }
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn t9_in_flight_state_released() {
        for case in ["success", "error", "cancel", "panic", "cancel_all"] {
            t9_case(case).await;
        }
    }

    // ---- T2 ----
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn t2_different_keys_execute_independently() {
        let svc = Arc::new(CachedService::<u8, Val, String>::new(CachePolicy::Forever));
        let gates: Vec<_> = (0..8).map(|_| Arc::new(Notify::new())).collect();
        let started = Arc::new(AtomicUsize::new(0));
        let mut handles = Vec::new();
        for k in 0..8u8 {
            let (svc, gate, started) = (svc.clone(), gates[k as usize].clone(), started.clone());
            handles.push(tokio::spawn(async move {
                svc.run_with_metadata(k, move || async move {
                    started.fetch_add(1, Ordering::SeqCst);
                    gate.notified().await;
                    Ok(Val {
                        key: k,
                        executor: u64::from(k),
                    })
                })
                .await
            }));
        }
        // every key runs its own operation concurrently
        if timeout(LIMIT, async {
            while started.load(Ordering::SeqCst) < 8 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .is_err()
        {
            panic!(
                "operations of different keys did not run concurrently: started = {} of 8, callers = {}",
                started.load(Ordering::SeqCst),
                svc.in_flight_callers()
            );
        }
        gates[0].notify_one();
        let first = handles.remove(0);
        let r0 = timeout(LIMIT, first)
            .await
            .expect("key 0 blocked by other keys")
            .unwrap();
        assert_eq!(r0.kind, ServiceRunKind::Executed);
        assert_eq!(
            *r0.result.unwrap(),
            Val {
                key: 0,
                executor: 0
            }
        );
        assert!(
            handles.iter().all(|h| !h.is_finished()),
            "other keys finished without their gate"
        );
        for g in &gates[1..] {
            g.notify_one();
        }
        for (i, h) in handles.into_iter().enumerate() {
            let k = (i + 1) as u8;
            let r = timeout(LIMIT, h).await.unwrap().unwrap();
            assert_eq!(r.kind, ServiceRunKind::Executed);
            assert_eq!(
                *r.result.unwrap(),
                Val {
                    key: k,
                    executor: u64::from(k)
                }
            );
        }
        assert_eq!(svc.cached_entries(), 8);
        assert_eq!((svc.in_flight_tasks(), svc.in_flight_keys()), (0, 0));
    }

    // ---- T4 ----
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn t4_invalidate_with_joined_waiter() {
        let svc = Arc::new(CachedService::<u8, Val, String>::new(CachePolicy::Forever));
        let (gate, started) = (Arc::new(Notify::new()), Arc::new(Notify::new()));
        let a = {
            let (svc, gate, started) = (svc.clone(), gate.clone(), started.clone());
            tokio::spawn(async move {
                svc.run_with_metadata(1, move || async move {
                    started.notify_one();
                    gate.notified().await;
                    Ok(Val {
                        key: 1,
                        executor: 1,
                    })
                })
                .await
            })
        };
        timeout(LIMIT, started.notified()).await.unwrap();
        let w = {
            let svc = svc.clone();
            tokio::spawn(async move {
                svc.run_with_metadata(1, || async {
                    Ok(Val {
                        key: 1,
                        executor: 2,
                    })
                })
                .await
            })
        };
        wait_until(|| svc.in_flight_callers() == 2, "waiter joined").await;
        svc.invalidate(&1);
        // N is called after invalidate returned
        let n = {
            let svc = svc.clone();
            tokio::spawn(async move {
                svc.run_with_metadata(1, || async {
                    Ok(Val {
                        key: 1,
                        executor: 3,
                    })
                })
                .await
            })
        };
        wait_until(
            || n.is_finished() || svc.in_flight_callers() >= 3,
            "N finished or registered",
        )
        .await;
        gate.notify_one();
        let n = timeout(LIMIT, n).await.unwrap().unwrap();
        assert_eq!(
            (n.kind, n.result.unwrap().executor),
            (ServiceRunKind::Executed, 3),
            "N joined the pre-invalidate operation"
        );
        let a = a.await.unwrap();
        let w = w.await.unwrap();
        assert_eq!(
            (a.kind, a.result.unwrap().executor),
            (ServiceRunKind::Executed, 1)
        );
        assert_eq!(
            (w.kind, w.result.unwrap().executor),
            (ServiceRunKind::Coalesced, 1)
        );
        let next = svc
            .run_with_metadata(1, || async {
                Ok(Val {
                    key: 1,
                    executor: 4,
                })
            })
            .await;
        assert_eq!(
            (next.kind, next.result.unwrap().executor),
            (ServiceRunKind::CacheHit, 3)
        );
        assert_eq!((svc.in_flight_tasks(), svc.in_flight_keys()), (0, 0));
    }

    // ---- T6 ----
    async fn t6(clear: bool) {
        let svc = Arc::new(CachedService::<u8, Val, String>::new(CachePolicy::Forever));
        let started = Arc::new(Notify::new());
        let a = {
            let (svc, started) = (svc.clone(), started.clone());
            tokio::spawn(async move {
                svc.run_with_metadata(1, move || async move {
                    started.notify_one();
                    std::future::pending::<()>().await;
                    Ok(Val {
                        key: 1,
                        executor: 1,
                    })
                })
                .await
            })
        };
        timeout(LIMIT, started.notified()).await.unwrap();
        let w = {
            let svc = svc.clone();
            tokio::spawn(async move {
                svc.run_with_metadata(1, || async {
                    Ok(Val {
                        key: 1,
                        executor: 2,
                    })
                })
                .await
            })
        };
        wait_until(|| svc.in_flight_callers() == 2, "waiter joined").await;
        if clear {
            svc.clear()
        } else {
            svc.invalidate(&1);
        }
        // A never completes on its own: W can only get a result by executing after this abort
        a.abort();
        assert!(a.await.unwrap_err().is_cancelled());
        let w = timeout(LIMIT, w).await.unwrap().unwrap();
        assert_eq!(
            (w.kind, w.result.unwrap().executor),
            (ServiceRunKind::Executed, 2)
        );
        assert_eq!(
            svc.cached_entries(),
            0,
            "request registered before the invalidation re-executed and repopulated the cache"
        );
        let next = svc
            .run_with_metadata(1, || async {
                Ok(Val {
                    key: 1,
                    executor: 3,
                })
            })
            .await;
        assert_eq!(
            (next.kind, next.result.unwrap().executor),
            (ServiceRunKind::Executed, 3)
        );
        assert_eq!((svc.in_flight_tasks(), svc.in_flight_keys()), (0, 0));
    }
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn t6_initializer_cancel_after_invalidate() {
        t6(false).await
    }
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn t6_initializer_cancel_after_clear() {
        t6(true).await
    }

    // ---- T10 ----
    // Oracle: registration, invalidate and clear all take the `generation`
    // mutex, and `probe::mark` ticks inside those critical sections, so tick
    // order is the order in which the service observed these events.
    #[derive(Debug, Clone)]
    struct Req {
        id: u64,
        key: u8,
        /// Tick of this request's registration (or cache hit).
        reg: u64,
        kind: ServiceRunKind,
        /// Request whose operation produced the returned value or error.
        exec: u64,
    }

    #[derive(Debug, Clone)]
    struct Inv {
        /// `None` for `clear`.
        key: Option<u8>,
        tick: u64,
        start: u64,
        ret: u64,
    }

    struct Rng(u64);

    impl Rng {
        fn next(&mut self) -> u64 {
            self.0 ^= self.0 << 13;
            self.0 ^= self.0 >> 7;
            self.0 ^= self.0 << 17;
            self.0
        }
    }

    fn env_or<T: std::str::FromStr>(name: &str, default: T) -> T {
        std::env::var(name)
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(default)
    }

    /// Set `STRESS_SEED` and `STRESS_ITERS` to reproduce or extend a run.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn t10_no_stale_after_invalidate_or_clear() {
        let seed: u64 = env_or("STRESS_SEED", 0x9E37_79B9_7F4A_7C15);
        let iters: usize = env_or("STRESS_ITERS", 300);
        let svc = Arc::new(CachedService::<u8, Val, Val>::new(CachePolicy::Forever));
        let ids = Arc::new(std::sync::atomic::AtomicU64::new(1));
        let reqs = Arc::new(Mutex::new(Vec::<Req>::new()));
        let invs = Arc::new(Mutex::new(Vec::<Inv>::new()));
        let mut hs = Vec::new();
        for w in 0..16u64 {
            let (svc, ids, reqs, invs) = (svc.clone(), ids.clone(), reqs.clone(), invs.clone());
            hs.push(tokio::spawn(async move {
                let mut rng = Rng(seed ^ (w + 1).wrapping_mul(0x2545_F491_4F6C_DD1D));
                for _ in 0..iters {
                    let r = rng.next() % 100;
                    let key = (rng.next() % 4) as u8;
                    if r < 10 {
                        let all = r >= 8;
                        let start = probe::now();
                        let tick = probe::MARK.sync_scope(Cell::new(0), || {
                            if all {
                                svc.clear()
                            } else {
                                svc.invalidate(&key);
                            }
                            probe::MARK.with(Cell::get)
                        });
                        let ret = probe::now();
                        invs.lock().unwrap().push(Inv {
                            key: (!all).then_some(key),
                            tick,
                            start,
                            ret,
                        });
                    } else {
                        // The id is assigned before the call; the value carries
                        // the id of the request that actually computed it.
                        let id = ids.fetch_add(1, Ordering::SeqCst);
                        let fail = rng.next() % 100 < 20;
                        let yields = rng.next() % 4;
                        let (out, reg) = probe::MARK
                            .scope(Cell::new(0), async {
                                let out = svc
                                    .run_with_metadata(key, move || async move {
                                        for _ in 0..yields {
                                            tokio::task::yield_now().await;
                                        }
                                        let v = Val { key, executor: id };
                                        if fail { Err(v) } else { Ok(v) }
                                    })
                                    .await;
                                (out, probe::MARK.with(Cell::get))
                            })
                            .await;
                        assert_ne!(reg, 0, "registration tick missing");
                        let v = match &out.result {
                            Ok(v) => (**v).clone(),
                            Err(e) => (**e).clone(),
                        };
                        assert_eq!(v.key, key, "cross-key result");
                        reqs.lock().unwrap().push(Req {
                            id,
                            key,
                            reg,
                            kind: out.kind,
                            exec: v.executor,
                        });
                    }
                }
            }));
        }
        for h in hs {
            h.await.unwrap();
        }

        let reqs = reqs.lock().unwrap();
        let invs = invs.lock().unwrap();
        for i in invs.iter() {
            assert!(
                i.start < i.tick && i.tick < i.ret,
                "invalidation tick outside its call: {i:?}"
            );
        }
        let by_id: std::collections::HashMap<u64, &Req> = reqs.iter().map(|r| (r.id, r)).collect();
        let mut violations = 0usize;
        for r in reqs.iter() {
            let e = by_id[&r.exec];
            assert_eq!(
                e.kind,
                ServiceRunKind::Executed,
                "result from a request that did not execute: {e:?}"
            );
            // A request registered after an invalidation of its key must not
            // see the work of a request registered before that invalidation.
            for i in invs.iter().filter(|i| i.key.is_none_or(|k| k == r.key)) {
                if r.id != e.id && e.reg < i.tick && i.tick < r.reg {
                    violations += 1;
                    if violations <= 5 {
                        println!("STALE: req={r:?} executor={e:?} inv={i:?}");
                    }
                }
            }
        }
        println!(
            "T10 seed={seed} iters={iters} requests={} invalidations={} violations={violations}",
            reqs.len(),
            invs.len()
        );
        assert_eq!(
            violations, 0,
            "stale results after invalidate/clear (seed {seed})"
        );
        assert_eq!((svc.in_flight_tasks(), svc.in_flight_keys()), (0, 0));
    }
}
