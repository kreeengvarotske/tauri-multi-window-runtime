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
        let first_service = Arc::clone(&service);
        let first_signal = Arc::clone(&first_started);

        let first_task = tokio::spawn(async move {
            first_service
                .run_with_metadata("shared".to_owned(), || async move {
                    first_signal.notify_one();
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    Ok(42)
                })
                .await
        });

        first_started.notified().await;

        let second_entered = Arc::new(tokio::sync::Notify::new());
        let second_service = Arc::clone(&service);
        let second_signal = Arc::clone(&second_entered);

        let second_task = tokio::spawn(async move {
            second_signal.notify_one();

            second_service
                .run_with_metadata("shared".to_owned(), || async { Ok(99) })
                .await
        });

        second_entered.notified().await;

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
