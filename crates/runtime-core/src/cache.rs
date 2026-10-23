use crate::cache_policy::CachePolicy;
use std::{
    collections::HashMap,
    hash::Hash,
    sync::{Arc, Mutex},
    time::Instant,
};

struct CacheEntry<V> {
    value: Arc<V>,
    inserted_at: Instant,
    policy: CachePolicy,
}

/// A thread-safe cache whose entries follow an explicit [`CachePolicy`].
///
/// Expired values are never returned by `get`. Entries are cleaned up on lookup,
/// when `len` is called, or explicitly through `remove_expired`.
pub struct PolicyCache<K, V> {
    entries: Mutex<HashMap<K, CacheEntry<V>>>,
}

impl<K, V> Default for PolicyCache<K, V>
where
    K: Eq + Hash,
{
    fn default() -> Self {
        Self {
            entries: Mutex::new(HashMap::new()),
        }
    }
}

impl<K, V> PolicyCache<K, V>
where
    K: Eq + Hash,
{
    /// Creates an empty cache.
    pub fn new() -> Self {
        Self::default()
    }

    /// Returns a shared value if it exists and has not expired.
    ///
    /// If the entry has expired, it is removed and `None` is returned.
    pub fn get(&self, key: &K) -> Option<Arc<V>> {
        let mut entries = self.entries.lock().unwrap_or_else(|p| p.into_inner());
        let now = Instant::now();

        let expired = entries
            .get(key)
            .is_some_and(|entry| entry.policy.is_expired(entry.inserted_at, now));

        if expired {
            let removed = entries.remove(key);
            drop(entries);
            drop(removed);
            return None;
        }

        entries.get(key).map(|entry| Arc::clone(&entry.value))
    }

    /// Stores a value using the given policy.
    ///
    /// Returns `true` if the value was stored. With `NoStore`, any existing
    /// value for this key is invalidated and this call returns `false`.
    pub fn insert(&self, key: K, value: V, policy: CachePolicy) -> bool {
        self.insert_arc(key, Arc::new(value), policy)
    }

    /// Stores an existing `Arc` without wrapping it in another `Arc`.
    ///
    /// Returns `true` if the value was stored. With `NoStore`, any existing
    /// value for this key is invalidated and this call returns `false`.
    pub fn insert_arc(&self, key: K, value: Arc<V>, policy: CachePolicy) -> bool {
        if !policy.should_store() {
            self.invalidate(&key);
            return false;
        }

        let replaced = {
            let mut entries = self.entries.lock().unwrap_or_else(|p| p.into_inner());
            entries.insert(
                key,
                CacheEntry {
                    value,
                    inserted_at: Instant::now(),
                    policy,
                },
            )
        };

        // Drop replaced values after releasing the mutex.
        drop(replaced);
        true
    }

    /// Removes one entry. Returns `true` if an entry existed.
    pub fn invalidate(&self, key: &K) -> bool {
        let removed = {
            let mut entries = self.entries.lock().unwrap_or_else(|p| p.into_inner());
            entries.remove(key)
        };

        let existed = removed.is_some();
        drop(removed);
        existed
    }

    /// Removes all entries.
    pub fn clear(&self) {
        let removed = {
            let mut entries = self.entries.lock().unwrap_or_else(|p| p.into_inner());
            std::mem::take(&mut *entries)
        };
        drop(removed);
    }

    /// Removes all expired entries and returns the number removed.
    pub fn remove_expired(&self) -> usize {
        let mut entries = self.entries.lock().unwrap_or_else(|p| p.into_inner());
        let now = Instant::now();
        let before = entries.len();

        entries.retain(|_, entry| !entry.policy.is_expired(entry.inserted_at, now));

        before - entries.len()
    }

    /// Returns the number of live entries, pruning expired entries first.
    pub fn len(&self) -> usize {
        self.remove_expired();
        self.entries.lock().unwrap_or_else(|p| p.into_inner()).len()
    }

    /// Returns whether the cache has no live entries.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
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
}
