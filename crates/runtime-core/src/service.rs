use crate::{CoalescerRunKind, TaskCoalescer, cache::PolicyCache, cache_policy::CachePolicy};
use std::{
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

/// Combines cache lookup, concurrent request coalescing,
/// and successful-result caching.
///
/// Errors are never cached. Calls started after `invalidate` or `clear`
/// use a new generation, so they do not join older in-flight work.
pub struct CachedService<K, V, E> {
    cache: PolicyCache<K, V>,
    coalescer: TaskCoalescer<(K, u64), CachedValue<V>, E>,
    policy: CachePolicy,
    generation: Mutex<u64>,
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
            generation: Mutex::new(0),
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
        // Read the generation and cache under the same gate used by
        // invalidation. This keeps cache publication and invalidation ordered.
        let generation = {
            let generation = self
                .generation
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());

            if let Some(value) = self.cache.get(&key) {
                return ServiceRunOutcome {
                    result: Ok(value),
                    kind: ServiceRunKind::CacheHit,
                };
            }

            *generation
        };

        let cache = &self.cache;
        let generation_gate = &self.generation;
        let policy = self.policy;
        let cache_key = key.clone();

        let (result, coalescer_kind) = self
            .coalescer
            .run_with_kind((key, generation), || async move {
                let value = operation().await?;
                let value = Arc::new(value);

                // An invalidation during the operation prevents stale insertion.
                let current_generation = generation_gate
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());

                if *current_generation == generation {
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

    /// Invalidates a key and separates future calls from older in-flight work.
    ///
    /// This bumps the service-wide generation: operations already in flight
    /// for any key still return to existing callers, but cannot populate
    /// the cache. Returns `true` if a cached entry existed.
    pub fn invalidate(&self, key: &K) -> bool {
        let mut generation = self
            .generation
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());

        *generation = generation.wrapping_add(1);
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

        *generation = generation.wrapping_add(1);
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
