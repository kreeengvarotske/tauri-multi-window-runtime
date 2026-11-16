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

pub(crate) struct CacheEntry<V> {
    value: Arc<V>,
    expires_at: Option<Instant>,
    weight: usize,
    last_used: u64,
}

type RemovedEntries<K, V> = Vec<(K, Arc<V>)>;

fn into_key_value<K, V>((key, entry): (K, CacheEntry<V>)) -> (K, Arc<V>) {
    (key, entry.value)
}

struct Entries<K, V> {
    map: HashMap<K, CacheEntry<V>>,
    total_weight: usize,
    clock: u64,
    evictions: u64,
    // Removals may leave an earlier hint, never a later one.
    next_expiry: Option<Instant>,
}

impl<K, V> Default for Entries<K, V> {
    fn default() -> Self {
        Self {
            map: HashMap::new(),
            total_weight: 0,
            clock: 0,
            evictions: 0,
            next_expiry: None,
        }
    }
}

impl<K: Eq + Hash, V> Entries<K, V> {
    fn tick(&mut self) -> u64 {
        self.clock += 1;
        self.clock
    }

    fn remove(&mut self, key: &K) -> Option<(K, CacheEntry<V>)> {
        let removed = self.map.remove_entry(key);
        if let Some((_, entry)) = &removed {
            self.total_weight -= entry.weight;
        }
        removed
    }

    fn evict_to_weight(&mut self, target: usize, removed: &mut RemovedEntries<K, V>) {
        let mut excess = self.total_weight.saturating_sub(target);
        if excess == 0 {
            return;
        }
        let oldest = self
            .map
            .values()
            .min_by_key(|entry| entry.last_used)
            .expect("positive cache weight requires an entry");
        let cutoff = if oldest.weight >= excess {
            oldest.last_used
        } else {
            // Sort small metadata once instead of scanning the entire map for
            // every eviction when a large insertion needs multiple removals.
            let mut order: Vec<_> = self
                .map
                .values()
                .map(|entry| (entry.last_used, entry.weight))
                .collect();
            order.sort_unstable_by_key(|&(last_used, _)| last_used);
            order
                .into_iter()
                .find_map(|(last_used, weight)| {
                    excess = excess.saturating_sub(weight);
                    (excess == 0).then_some(last_used)
                })
                .expect("cache entries cover the excess weight")
        };

        let Self {
            map,
            total_weight,
            evictions,
            ..
        } = self;
        removed.extend(
            map.extract_if(|_, entry| {
                if entry.last_used > cutoff {
                    return false;
                }
                *total_weight -= entry.weight;
                *evictions += 1;
                true
            })
            .map(into_key_value),
        );
    }

    fn remove_expired(&mut self, now: Instant, removed: &mut RemovedEntries<K, V>) {
        if self.next_expiry.is_none_or(|expiry| expiry > now) {
            return;
        }
        let Self {
            map,
            total_weight,
            next_expiry,
            ..
        } = self;
        let mut next = None;
        removed.extend(
            map.extract_if(|_, entry| {
                if let Some(expiry) = entry.expires_at {
                    if expiry <= now {
                        *total_weight -= entry.weight;
                        return true;
                    }
                    next = Some(next.map_or(expiry, |current: Instant| current.min(expiry)));
                }
                false
            })
            .map(into_key_value),
        );
        *next_expiry = next;
    }
}

/// A key-value cache with per-entry policies and an optional weight budget.
///
/// Key `Hash` and `Eq` implementations run under an internal lock and must not
/// reenter this cache. Removed keys and values are destroyed outside the lock.
pub struct PolicyCache<K, V> {
    entries: Mutex<Entries<K, V>>,
    budget: Option<CacheBudget<V>>,
}

/// A consistent snapshot of live cache entries and budget evictions.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CacheStats {
    /// Number of entries that have not expired.
    pub entries: usize,
    /// Total live weight, or zero without a budget.
    pub weight: usize,
    /// Number of entries evicted to make room for new values.
    pub evictions: u64,
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
        self.get_deferred(key, &mut Vec::new())
    }

    pub(crate) fn get_deferred(
        &self,
        key: &K,
        removed: &mut RemovedEntries<K, V>,
    ) -> Option<Arc<V>> {
        let mut entries = self.entries.lock().unwrap_or_else(|p| p.into_inner());
        let now = Instant::now();

        let expired = entries
            .map
            .get(key)
            .and_then(|entry| entry.expires_at)
            .is_some_and(|expiry| expiry <= now);

        if expired {
            removed.extend(entries.remove(key).map(into_key_value));
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

    /// Stores `value` unless the policy disables storage or the value alone is
    /// heavier than the budget; in both cases an older value for `key` is
    /// removed and `false` is returned. When a budgeted cache needs room,
    /// expired entries are removed first, then live entries are evicted in
    /// least-recently-used order until the new value fits.
    pub fn insert_arc(&self, key: K, value: Arc<V>, policy: CachePolicy) -> bool {
        let weight = self.storage_weight(&value, policy);
        self.insert_deferred(key, &value, policy, weight, &mut Vec::new())
    }

    pub(crate) fn storage_weight(&self, value: &V, policy: CachePolicy) -> Option<usize> {
        if !policy.should_store() {
            return None;
        }
        let weight = self
            .budget
            .as_ref()
            .map_or(0, |budget| (budget.weigher)(value));
        self.budget
            .as_ref()
            .is_none_or(|budget| weight <= budget.max_weight)
            .then_some(weight)
    }

    pub(crate) fn insert_deferred(
        &self,
        key: K,
        value: &Arc<V>,
        policy: CachePolicy,
        weight: Option<usize>,
        removed: &mut RemovedEntries<K, V>,
    ) -> bool {
        let Some(weight) = weight else {
            self.invalidate_deferred(&key, removed);
            // The service may still hold its generation lock. Application key
            // destructors must wait for the caller to release that outer lock.
            removed.push((key, Arc::clone(value)));
            return false;
        };

        {
            let mut entries = self.entries.lock().unwrap_or_else(|p| p.into_inner());
            removed.extend(entries.remove(&key).map(into_key_value));

            if let Some(budget) = &self.budget {
                // Make room before inserting: `weight <= max_weight`, so the
                // bound `max_weight - weight` cannot underflow, and the total
                // after the insert is at most `max_weight` (no overflow).
                let room = budget.max_weight - weight;
                if entries.total_weight > room {
                    entries.remove_expired(Instant::now(), removed);
                }
                entries.evict_to_weight(room, removed);
            }
            let Some(total_weight) = entries.total_weight.checked_add(weight) else {
                // Unreachable while the invariant above holds; refuse to store
                // rather than let the total wrap.
                removed.push((key, Arc::clone(value)));
                return false;
            };
            entries.total_weight = total_weight;
            let last_used = entries.tick();
            let expires_at = match policy {
                CachePolicy::Ttl(ttl) => Instant::now().checked_add(ttl),
                _ => None,
            };
            if let Some(expiry) = expires_at {
                entries.next_expiry =
                    Some(entries.next_expiry.map_or(expiry, |next| next.min(expiry)));
            }
            entries.map.insert(
                key,
                CacheEntry {
                    value: Arc::clone(value),
                    expires_at,
                    weight,
                    last_used,
                },
            );
        }
        true
    }

    pub fn invalidate(&self, key: &K) -> bool {
        self.invalidate_deferred(key, &mut Vec::new())
    }

    pub(crate) fn invalidate_deferred(&self, key: &K, removed: &mut RemovedEntries<K, V>) -> bool {
        let mut entries = self.entries.lock().unwrap_or_else(|p| p.into_inner());
        if let Some(entry) = entries.remove(key) {
            removed.push(into_key_value(entry));
            return true;
        }
        false
    }

    /// Removes every entry whose key matches `predicate`. Returns how many
    /// entries were removed.
    pub fn invalidate_matching(&self, predicate: impl FnMut(&K) -> bool) -> usize {
        self.invalidate_matching_deferred(predicate, &mut Vec::new())
    }

    pub(crate) fn invalidate_matching_deferred(
        &self,
        mut predicate: impl FnMut(&K) -> bool,
        removed: &mut RemovedEntries<K, V>,
    ) -> usize {
        let mut entries = self.entries.lock().unwrap_or_else(|p| p.into_inner());
        let Entries {
            map, total_weight, ..
        } = &mut *entries;
        let initial_count = removed.len();
        removed.extend(
            map.extract_if(|key, entry| {
                if !predicate(key) {
                    return false;
                }
                *total_weight -= entry.weight;
                true
            })
            .map(into_key_value),
        );
        removed.len() - initial_count
    }

    pub fn clear(&self) {
        drop(self.take_entries());
    }

    pub(crate) fn take_entries(&self) -> HashMap<K, CacheEntry<V>> {
        let mut entries = self.entries.lock().unwrap_or_else(|p| p.into_inner());
        entries.total_weight = 0;
        entries.next_expiry = None;
        std::mem::take(&mut entries.map)
    }

    pub fn remove_expired(&self) -> usize {
        let mut removed = Vec::new();
        self.entries
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .remove_expired(Instant::now(), &mut removed);
        removed.len()
    }

    pub fn len(&self) -> usize {
        self.stats().entries
    }

    /// Prunes expired entries and reads all cache counters under one lock.
    pub fn stats(&self) -> CacheStats {
        let mut removed = Vec::new();
        let mut entries = self.entries.lock().unwrap_or_else(|p| p.into_inner());
        entries.remove_expired(Instant::now(), &mut removed);
        CacheStats {
            entries: entries.map.len(),
            weight: entries.total_weight,
            evictions: entries.evictions,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Total weight of the live entries, pruning expired entries first.
    /// Always 0 for a cache without a budget.
    pub fn weight(&self) -> usize {
        self.stats().weight
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
    use super::{Instant, PolicyCache};
    use crate::cache_policy::CachePolicy;

    #[test]
    fn panicking_predicate_preserves_weight_of_remaining_entries() {
        let cache = PolicyCache::with_budget(super::CacheBudget::new(10, |_: &u32| 1));
        for key in 0..3 {
            assert!(cache.insert(key, key, CachePolicy::Forever));
        }
        let mut visited = 0;
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            cache.invalidate_matching(|_| {
                visited += 1;
                assert_ne!(visited, 2, "predicate panicked");
                true
            });
        }));
        assert!(result.is_err());
        assert_eq!(cache.len(), 2);
        assert_eq!(cache.weight(), 2);
    }
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
    fn stale_expiry_hint_advances_to_the_next_live_deadline() {
        let cache = PolicyCache::new();
        assert!(cache.insert(1, 1, CachePolicy::Ttl(Duration::from_secs(60))));
        assert!(cache.insert(2, 2, CachePolicy::Ttl(Duration::from_secs(120))));
        assert!(cache.insert(3, 3, CachePolicy::Forever));
        assert!(cache.invalidate(&1));

        let mut removed = Vec::new();
        let mut entries = cache.entries.lock().unwrap();
        let stale = entries.next_expiry.unwrap();
        let live = entries.map[&2].expires_at.unwrap();
        entries.remove_expired(stale, &mut removed);
        assert!(removed.is_empty());
        assert_eq!(entries.next_expiry, Some(live));
        entries.remove_expired(live, &mut removed);
        assert_eq!(removed.len(), 1);
        assert_eq!(entries.next_expiry, None);
        assert!(entries.map.contains_key(&3));
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
    fn zero_ttl_never_evicts_unrelated_entries() {
        let cache = weighted_by_value(10);
        assert!(cache.insert(1, 10, CachePolicy::Forever));
        assert!(!cache.insert(2, 10, CachePolicy::Ttl(Duration::ZERO)));
        assert_eq!(cache.get(&1).as_deref(), Some(&10));
        assert_eq!(cache.weight(), 10);
        assert_eq!(cache.evictions(), 0);

        assert!(!cache.insert(1, 10, CachePolicy::Ttl(Duration::ZERO)));
        assert!(cache.is_empty());
    }

    #[test]
    fn bulk_eviction_respects_lru_even_with_zero_weight_entries() {
        let cache = weighted_by_value(12);
        for (key, weight) in [(1, 4), (2, 0), (3, 4), (4, 4)] {
            assert!(cache.insert(key, weight, CachePolicy::Forever));
        }
        assert!(cache.get(&1).is_some());
        assert!(cache.insert(5, 7, CachePolicy::Forever));
        assert_eq!((cache.len(), cache.weight(), cache.evictions()), (2, 11, 3));
        assert!(cache.get(&1).is_some());
        assert!(cache.get(&5).is_some());
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
        let stats = cache.stats();
        assert_eq!((stats.entries, stats.weight, stats.evictions), (0, 0, 0));
        // the expired entry no longer pushes a new one out
        assert!(cache.insert("k".into(), vec![0; 60], CachePolicy::Forever));
        assert_eq!(cache.evictions(), 0);
    }

    #[test]
    fn expired_entries_make_room_before_live_entries_are_evicted() {
        let cache = budgeted(100);
        let expired = "expired".to_owned();
        let live = "live".to_owned();
        let ttl = Duration::from_secs(60);
        assert!(cache.insert(live.clone(), vec![0; 40], CachePolicy::Forever));
        assert!(cache.insert(expired.clone(), vec![0; 60], CachePolicy::Ttl(ttl)));
        {
            let mut entries = cache.entries.lock().unwrap();
            let now = Instant::now();
            entries.map.get_mut(&expired).unwrap().expires_at = Some(now);
            entries.next_expiry = Some(now);
        }

        assert!(cache.insert("new".into(), vec![0; 60], CachePolicy::Forever));
        assert!(cache.get(&live).is_some());
        assert!(cache.get(&expired).is_none());
        let stats = cache.stats();
        assert_eq!((stats.entries, stats.weight, stats.evictions), (2, 100, 0));
    }

    #[test]
    fn expiry_drops_values_after_releasing_the_entries_lock() {
        use std::sync::{
            Weak,
            atomic::{AtomicBool, Ordering},
        };

        struct Probe {
            cache: Weak<PolicyCache<u8, Probe>>,
            lock_available: Arc<AtomicBool>,
        }

        impl Drop for Probe {
            fn drop(&mut self) {
                if let Some(cache) = self.cache.upgrade() {
                    self.lock_available
                        .store(cache.entries.try_lock().is_ok(), Ordering::SeqCst);
                }
            }
        }

        let cache = Arc::new(PolicyCache::new());
        let lock_available = Arc::new(AtomicBool::new(false));
        let ttl = Duration::from_secs(60);
        assert!(cache.insert(
            1,
            Probe {
                cache: Arc::downgrade(&cache),
                lock_available: Arc::clone(&lock_available),
            },
            CachePolicy::Ttl(ttl),
        ));
        {
            let mut entries = cache.entries.lock().unwrap();
            let now = Instant::now();
            entries.map.get_mut(&1).unwrap().expires_at = Some(now);
            entries.next_expiry = Some(now);
        }

        assert_eq!(cache.remove_expired(), 1);
        assert!(lock_available.load(Ordering::SeqCst));
    }

    #[test]
    fn removing_entries_drops_keys_after_releasing_the_cache_lock() {
        use std::hash::{Hash, Hasher};
        use std::sync::atomic::{AtomicUsize, Ordering};

        struct Key(u8, Box<dyn Fn()>);
        impl PartialEq for Key {
            fn eq(&self, other: &Self) -> bool {
                self.0 == other.0
            }
        }
        impl Eq for Key {}
        impl Hash for Key {
            fn hash<H: Hasher>(&self, state: &mut H) {
                self.0.hash(state);
            }
        }
        impl Drop for Key {
            fn drop(&mut self) {
                (self.1)();
            }
        }

        let cache = std::rc::Rc::new(PolicyCache::with_budget(super::CacheBudget::new(
            1,
            |_: &()| 1,
        )));
        let locked_drops = Arc::new(AtomicUsize::new(0));
        let key = |id| {
            let cache = std::rc::Rc::downgrade(&cache);
            let locked_drops = Arc::clone(&locked_drops);
            Key(
                id,
                Box::new(move || {
                    if let Some(cache) = cache.upgrade()
                        && cache.entries.try_lock().is_err()
                    {
                        locked_drops.fetch_add(1, Ordering::Relaxed);
                    }
                }),
            )
        };

        assert!(cache.insert(key(1), (), CachePolicy::Forever));
        assert!(cache.insert(key(1), (), CachePolicy::Forever));
        assert!(cache.insert(key(2), (), CachePolicy::Forever));
        assert_eq!(cache.evictions(), 1);
        assert_eq!(cache.invalidate_matching(|_| true), 1);
        assert_eq!(locked_drops.load(Ordering::Relaxed), 0);
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
