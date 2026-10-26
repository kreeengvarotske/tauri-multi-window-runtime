use crate::cache_policy::CachePolicy;
use std::{
    collections::HashMap,
    fmt,
    hash::Hash,
    sync::{Arc, Mutex},
    time::Instant,
};

/// Upper bound on the total weight of the values a cache keeps.
///
/// The weight of a value is whatever `weigher` returns for it, normally an
/// estimate of the bytes it retains. When an insertion takes the total above
/// `max_weight`, the least recently used entries are removed until it fits.
/// A value heavier than `max_weight` on its own is not stored.
pub struct CacheBudget<V> {
    max_weight: usize,
    weigher: Arc<dyn Fn(&V) -> usize + Send + Sync>,
}

impl<V> CacheBudget<V> {
    pub fn new(max_weight: usize, weigher: impl Fn(&V) -> usize + Send + Sync + 'static) -> Self {
        Self {
            max_weight,
            weigher: Arc::new(weigher),
        }
    }

    pub const fn max_weight(&self) -> usize {
        self.max_weight
    }
}

impl<V> Clone for CacheBudget<V> {
    fn clone(&self) -> Self {
        Self {
            max_weight: self.max_weight,
            weigher: Arc::clone(&self.weigher),
        }
    }
}

impl<V> fmt::Debug for CacheBudget<V> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CacheBudget")
            .field("max_weight", &self.max_weight)
            .finish_non_exhaustive()
    }
}

struct CacheEntry<V> {
    value: Arc<V>,
    inserted_at: Instant,
    policy: CachePolicy,
    weight: usize,
    last_used: u64,
}

struct Entries<K, V> {
    map: HashMap<K, CacheEntry<V>>,
    total_weight: usize,
    clock: u64,
    evictions: u64,
}

impl<K, V> Default for Entries<K, V> {
    fn default() -> Self {
        Self {
            map: HashMap::new(),
            total_weight: 0,
            clock: 0,
            evictions: 0,
        }
    }
}

impl<K: Eq + Hash, V> Entries<K, V> {
    fn tick(&mut self) -> u64 {
        self.clock += 1;
        self.clock
    }

    fn remove(&mut self, key: &K) -> Option<CacheEntry<V>> {
        let removed = self.map.remove(key);
        if let Some(entry) = &removed {
            self.total_weight -= entry.weight;
        }
        removed
    }

    /// Removes the least recently used entry. Returns its value so that the
    /// caller can drop it after releasing the lock.
    fn evict_oldest(&mut self) -> Option<Arc<V>> {
        let oldest = self.map.values().map(|entry| entry.last_used).min()?;
        let mut evicted = None;
        let mut freed = 0;
        self.map.retain(|_, entry| {
            if entry.last_used != oldest {
                return true;
            }
            freed = entry.weight;
            evicted = Some(Arc::clone(&entry.value));
            false
        });
        self.total_weight -= freed;
        self.evictions += 1;
        evicted
    }

    fn remove_expired(&mut self, now: Instant) -> usize {
        let before = self.map.len();
        let mut freed = 0;
        self.map.retain(|_, entry| {
            let expired = entry.policy.is_expired(entry.inserted_at, now);
            if expired {
                freed += entry.weight;
            }
            !expired
        });
        self.total_weight -= freed;
        before - self.map.len()
    }
}

/// A key-value cache with per-entry policies and an optional weight budget.
pub struct PolicyCache<K, V> {
    entries: Mutex<Entries<K, V>>,
    budget: Option<CacheBudget<V>>,
}

impl<K, V> Default for PolicyCache<K, V>
where
    K: Eq + Hash,
{
    fn default() -> Self {
        Self {
            entries: Mutex::new(Entries::default()),
            budget: None,
        }
    }
}

impl<K, V> PolicyCache<K, V>
where
    K: Eq + Hash,
{
    pub fn new() -> Self {
        Self::default()
    }

    /// Creates a cache whose total weight stays within `budget`.
    pub fn with_budget(budget: CacheBudget<V>) -> Self {
        Self {
            entries: Mutex::new(Entries::default()),
            budget: Some(budget),
        }
    }

    pub fn get(&self, key: &K) -> Option<Arc<V>> {
        let mut entries = self.entries.lock().unwrap_or_else(|p| p.into_inner());
        let now = Instant::now();

        let expired = entries
            .map
            .get(key)
            .is_some_and(|entry| entry.policy.is_expired(entry.inserted_at, now));

        if expired {
            let removed = entries.remove(key);
            drop(entries);
            drop(removed);
            return None;
        }

        let tick = entries.tick();
        entries.map.get_mut(key).map(|entry| {
            entry.last_used = tick;
            Arc::clone(&entry.value)
        })
    }

    pub fn insert(&self, key: K, value: V, policy: CachePolicy) -> bool {
        self.insert_arc(key, Arc::new(value), policy)
    }

    /// Stores `value` unless the policy is `NoStore` or the value alone is
    /// heavier than the budget; in both cases an older value for `key` is
    /// removed and `false` is returned. With a budget, least recently used
    /// entries are evicted before the insert until the new value fits, so the
    /// total weight never exceeds the budget and never overflows.
    pub fn insert_arc(&self, key: K, value: Arc<V>, policy: CachePolicy) -> bool {
        if !policy.should_store() {
            self.invalidate(&key);
            return false;
        }

        let weight = self
            .budget
            .as_ref()
            .map_or(0, |budget| (budget.weigher)(&value));
        if self
            .budget
            .as_ref()
            .is_some_and(|budget| weight > budget.max_weight)
        {
            self.invalidate(&key);
            return false;
        }

        let mut evicted = Vec::new();
        let replaced = {
            let mut entries = self.entries.lock().unwrap_or_else(|p| p.into_inner());
            let replaced = entries.remove(&key);

            if let Some(budget) = &self.budget {
                // Make room before inserting: `weight <= max_weight`, so the
                // bound `max_weight - weight` cannot underflow, and the total
                // after the insert is at most `max_weight` (no overflow).
                let room = budget.max_weight - weight;
                while entries.total_weight > room {
                    match entries.evict_oldest() {
                        Some(value) => evicted.push(value),
                        None => break,
                    }
                }
            }
            let Some(total_weight) = entries.total_weight.checked_add(weight) else {
                // Unreachable while the invariant above holds; refuse to store
                // rather than let the total wrap.
                drop(entries);
                drop(replaced);
                drop(evicted);
                return false;
            };
            entries.total_weight = total_weight;
            let last_used = entries.tick();
            entries.map.insert(
                key,
                CacheEntry {
                    value,
                    inserted_at: Instant::now(),
                    policy,
                    weight,
                    last_used,
                },
            );
            replaced
        };

        drop(replaced);
        drop(evicted);
        true
    }

    pub fn invalidate(&self, key: &K) -> bool {
        let removed = {
            let mut entries = self.entries.lock().unwrap_or_else(|p| p.into_inner());
            entries.remove(key)
        };

        let existed = removed.is_some();
        drop(removed);
        existed
    }

    /// Removes every entry whose key matches `predicate`. Returns how many
    /// entries were removed.
    pub fn invalidate_matching(&self, mut predicate: impl FnMut(&K) -> bool) -> usize {
        let mut removed = Vec::new();
        {
            let mut entries = self.entries.lock().unwrap_or_else(|p| p.into_inner());
            let mut freed = 0;
            entries.map.retain(|key, entry| {
                if !predicate(key) {
                    return true;
                }
                freed += entry.weight;
                removed.push(Arc::clone(&entry.value));
                false
            });
            entries.total_weight -= freed;
        }
        let count = removed.len();
        drop(removed);
        count
    }

    pub fn clear(&self) {
        let removed = {
            let mut entries = self.entries.lock().unwrap_or_else(|p| p.into_inner());
            entries.total_weight = 0;
            std::mem::take(&mut entries.map)
        };
        drop(removed);
    }

    pub fn remove_expired(&self) -> usize {
        let mut entries = self.entries.lock().unwrap_or_else(|p| p.into_inner());
        entries.remove_expired(Instant::now())
    }

    pub fn len(&self) -> usize {
        self.remove_expired();
        self.entries
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .map
            .len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Total weight of the live entries, pruning expired entries first.
    /// Always 0 for a cache without a budget.
    pub fn weight(&self) -> usize {
        let mut entries = self.entries.lock().unwrap_or_else(|p| p.into_inner());
        entries.remove_expired(Instant::now());
        entries.total_weight
    }

    /// Number of entries removed to stay within the budget.
    pub fn evictions(&self) -> u64 {
        self.entries
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .evictions
    }

    /// The budget this cache was created with, if any.
    pub fn budget(&self) -> Option<&CacheBudget<V>> {
        self.budget.as_ref()
    }
}

#[cfg(test)]
mod tests {
    use super::PolicyCache;
    use crate::cache_policy::CachePolicy;
    use std::{sync::Arc, thread, time::Duration};

    #[test]
    fn stores_and_returns_shared_value() {
        let cache = PolicyCache::<String, usize>::new();
        let key = "answer".to_owned();

        assert!(cache.insert(key.clone(), 42, CachePolicy::Forever));

        let first = cache.get(&key).unwrap();
        let second = cache.get(&key).unwrap();

        assert_eq!(*first, 42);
        assert!(Arc::ptr_eq(&first, &second));
    }

    #[test]
    fn no_store_does_not_cache_and_invalidates_old_value() {
        let cache = PolicyCache::<String, usize>::new();
        let key = "answer".to_owned();

        assert!(cache.insert(key.clone(), 1, CachePolicy::Forever));
        assert!(!cache.insert(key.clone(), 2, CachePolicy::NoStore));

        assert!(cache.get(&key).is_none());
        assert!(cache.is_empty());
    }

    #[test]
    fn ttl_entry_expires_on_lookup() {
        let cache = PolicyCache::<String, usize>::new();
        let key = "short-lived".to_owned();

        assert!(cache.insert(key.clone(), 42, CachePolicy::Ttl(Duration::from_millis(10)),));

        thread::sleep(Duration::from_millis(25));
        assert!(cache.get(&key).is_none());
        assert!(cache.is_empty());
    }

    #[test]
    fn remove_expired_keeps_unexpired_entries() {
        let cache = PolicyCache::<String, usize>::new();
        let expired_key = "expired".to_owned();
        let forever_key = "forever".to_owned();

        assert!(cache.insert(
            expired_key.clone(),
            1,
            CachePolicy::Ttl(Duration::from_millis(10)),
        ));
        assert!(cache.insert(forever_key.clone(), 2, CachePolicy::Forever));

        thread::sleep(Duration::from_millis(25));

        assert_eq!(cache.remove_expired(), 1);
        assert!(cache.get(&expired_key).is_none());
        assert_eq!(*cache.get(&forever_key).unwrap(), 2);
    }

    #[test]
    fn invalidate_removes_only_the_requested_key() {
        let cache = PolicyCache::<String, usize>::new();
        let first_key = "first".to_owned();
        let second_key = "second".to_owned();

        assert!(cache.insert(first_key.clone(), 1, CachePolicy::Forever));
        assert!(cache.insert(second_key.clone(), 2, CachePolicy::Forever));

        assert!(cache.invalidate(&first_key));
        assert!(!cache.invalidate(&first_key));
        assert!(cache.get(&first_key).is_none());
        assert_eq!(*cache.get(&second_key).unwrap(), 2);
    }

    #[test]
    fn clear_removes_all_entries() {
        let cache = PolicyCache::<String, usize>::new();

        assert!(cache.insert("first".to_owned(), 1, CachePolicy::Forever));
        assert!(cache.insert("second".to_owned(), 2, CachePolicy::Forever));
        assert_eq!(cache.len(), 2);

        cache.clear();

        assert!(cache.is_empty());
    }

    #[test]
    fn insert_arc_preserves_shared_allocation() {
        let cache = PolicyCache::<String, usize>::new();
        let key = "shared".to_owned();
        let value = Arc::new(7);

        assert!(cache.insert_arc(key.clone(), Arc::clone(&value), CachePolicy::Forever,));

        let cached = cache.get(&key).unwrap();
        assert!(Arc::ptr_eq(&value, &cached));
    }

    fn budgeted(max: usize) -> PolicyCache<String, Vec<u8>> {
        PolicyCache::with_budget(super::CacheBudget::new(max, |v: &Vec<u8>| v.len()))
    }

    #[test]
    fn budget_evicts_least_recently_used_entries() {
        let cache = budgeted(100);
        assert!(cache.insert("a".into(), vec![0; 40], CachePolicy::Forever));
        assert!(cache.insert("b".into(), vec![0; 40], CachePolicy::Forever));
        // touch "a", so "b" is now the least recently used entry
        assert!(cache.get(&"a".to_owned()).is_some());
        assert!(cache.insert("c".into(), vec![0; 40], CachePolicy::Forever));

        assert!(cache.get(&"b".to_owned()).is_none());
        assert!(cache.get(&"a".to_owned()).is_some());
        assert!(cache.get(&"c".to_owned()).is_some());
        assert_eq!(cache.weight(), 80);
        assert_eq!(cache.evictions(), 1);
    }

    #[test]
    fn budget_evicts_as_many_entries_as_needed() {
        let cache = budgeted(100);
        for key in ["a", "b", "c", "d"] {
            assert!(cache.insert(key.into(), vec![0; 25], CachePolicy::Forever));
        }
        assert_eq!(cache.weight(), 100);
        assert!(cache.insert("big".into(), vec![0; 70], CachePolicy::Forever));
        assert_eq!(cache.weight(), 95);
        assert_eq!(cache.len(), 2);
        assert_eq!(cache.evictions(), 3);
        assert!(cache.get(&"d".to_owned()).is_some());
    }

    #[test]
    fn value_heavier_than_budget_is_not_stored_and_drops_the_old_value() {
        let cache = budgeted(100);
        assert!(cache.insert("k".into(), vec![0; 10], CachePolicy::Forever));
        assert!(!cache.insert("k".into(), vec![0; 101], CachePolicy::Forever));
        assert!(cache.get(&"k".to_owned()).is_none());
        assert_eq!(cache.weight(), 0);
        assert_eq!(cache.evictions(), 0);
    }

    #[test]
    fn replacing_invalidating_and_clearing_keep_the_weight_exact() {
        let cache = budgeted(100);
        assert!(cache.insert("k".into(), vec![0; 30], CachePolicy::Forever));
        assert!(cache.insert("k".into(), vec![0; 50], CachePolicy::Forever));
        assert_eq!(cache.weight(), 50);
        assert!(cache.insert("j".into(), vec![0; 20], CachePolicy::Forever));
        assert!(cache.invalidate(&"k".to_owned()));
        assert_eq!(cache.weight(), 20);
        assert!(!cache.insert("j".into(), vec![0; 1], CachePolicy::NoStore));
        assert_eq!(cache.weight(), 0);
        assert!(cache.insert("x".into(), vec![0; 60], CachePolicy::Forever));
        cache.clear();
        assert_eq!(cache.weight(), 0);
        assert_eq!(cache.evictions(), 0);
    }

    #[test]
    fn expired_entries_leave_the_weight() {
        let cache = budgeted(100);
        assert!(cache.insert(
            "short".into(),
            vec![0; 60],
            CachePolicy::Ttl(Duration::from_millis(10))
        ));
        thread::sleep(Duration::from_millis(25));
        assert_eq!(cache.weight(), 0);
        // the expired entry no longer pushes a new one out
        assert!(cache.insert("k".into(), vec![0; 60], CachePolicy::Forever));
        assert_eq!(cache.evictions(), 0);
    }

    /// Weights near `usize::MAX` without allocating: the value is its weight.
    fn weighted_by_value(max: usize) -> PolicyCache<u8, usize> {
        PolicyCache::with_budget(super::CacheBudget::new(max, |weight: &usize| *weight))
    }

    #[test]
    fn total_weight_never_overflows_or_exceeds_the_budget() {
        let cache = weighted_by_value(usize::MAX);
        assert!(cache.insert(1, usize::MAX - 1, CachePolicy::Forever));
        assert_eq!(cache.weight(), usize::MAX - 1);
        // usize::MAX - 1 + 2 would wrap to 0 with unchecked addition.
        assert!(cache.insert(2, 2, CachePolicy::Forever));
        assert_eq!(cache.weight(), 2, "the older heavy entry must be evicted");
        assert_eq!((cache.len(), cache.evictions()), (1, 1));
        assert!(cache.get(&1).is_none());

        assert!(cache.insert(3, usize::MAX, CachePolicy::Forever));
        assert_eq!(cache.weight(), usize::MAX);
        assert_eq!((cache.len(), cache.evictions()), (1, 2));

        // Replacing a key with the same weight frees its old weight first.
        assert!(cache.insert(3, usize::MAX, CachePolicy::Forever));
        assert_eq!((cache.weight(), cache.evictions()), (usize::MAX, 2));

        let small = weighted_by_value(10);
        for (key, weight) in [(1, 4), (2, 4), (3, 4), (4, 10), (5, 1)] {
            assert!(small.insert(key, weight, CachePolicy::Forever));
            assert!(small.weight() <= 10);
        }
        assert_eq!(small.weight(), 1);
    }

    #[test]
    fn cache_without_budget_reports_zero_weight_and_never_evicts() {
        let cache = PolicyCache::<String, Vec<u8>>::new();
        for n in 0..50 {
            assert!(cache.insert(n.to_string(), vec![0; 1000], CachePolicy::Forever));
        }
        assert_eq!(cache.len(), 50);
        assert_eq!(cache.weight(), 0);
        assert_eq!(cache.evictions(), 0);
        assert!(cache.budget().is_none());
    }
}
