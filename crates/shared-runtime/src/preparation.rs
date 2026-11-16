//! Invalidation identity while source parameters are still being derived.
//!
//! No application values or callbacks are held under this registry's lock.
//! Entries exist only until pending calls transfer to keyed core registrations.

use std::{
    collections::HashMap,
    hash::{Hash, Hasher},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
};

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) enum Scope {
    Shared,
    Window(Arc<str>),
}

/// Pointer identity separates discarded preparations from every current key.
/// The Arc keeps that identity alive until all associated work is dropped.
#[derive(Debug, Clone)]
pub(crate) struct Epoch(Arc<AtomicBool>);

impl Epoch {
    fn new() -> Self {
        Self(Arc::new(AtomicBool::new(true)))
    }
    fn valid(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
    fn invalidate(&self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

impl PartialEq for Epoch {
    fn eq(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0)
    }
}
impl Eq for Epoch {}
impl Hash for Epoch {
    fn hash<H: Hasher>(&self, state: &mut H) {
        Arc::as_ptr(&self.0).hash(state);
    }
}

struct ActiveScope {
    epoch: Epoch,
    calls: usize,
}

#[derive(Default)]
pub(crate) struct Preparations {
    scopes: Mutex<HashMap<Scope, ActiveScope>>,
}

impl Preparations {
    pub(crate) fn enter(&self, scope: Scope) -> Preparation<'_> {
        let epoch = {
            let mut scopes = self.scopes.lock().unwrap_or_else(|p| p.into_inner());
            let active = scopes.entry(scope.clone()).or_insert_with(|| ActiveScope {
                epoch: Epoch::new(),
                calls: 0,
            });
            if !active.epoch.valid() {
                active.epoch = Epoch::new();
            }
            active.calls += 1;
            active.epoch.clone()
        };
        Preparation {
            owner: self,
            scope,
            epoch,
        }
    }

    pub(crate) fn invalidate_all(&self) {
        let scopes = self.scopes.lock().unwrap_or_else(|p| p.into_inner());
        for active in scopes.values() {
            active.epoch.invalidate();
        }
    }

    pub(crate) fn forget_window(&self, label: &str) {
        let scopes = self.scopes.lock().unwrap_or_else(|p| p.into_inner());
        for (scope, active) in scopes.iter() {
            if matches!(scope, Scope::Window(window) if &**window == label) {
                active.epoch.invalidate();
            }
        }
    }
}

pub(crate) struct Preparation<'a> {
    owner: &'a Preparations,
    pub(crate) scope: Scope,
    pub(crate) epoch: Epoch,
}

impl Preparation<'_> {
    pub(crate) fn invalidated(&self) -> bool {
        !self.epoch.valid()
    }
}

impl Drop for Preparation<'_> {
    fn drop(&mut self) {
        let mut scopes = self.owner.scopes.lock().unwrap_or_else(|p| p.into_inner());
        let remove = if let Some(active) = scopes.get_mut(&self.scope) {
            active.calls -= 1;
            active.calls == 0
        } else {
            false
        };
        let removed = if remove {
            scopes.remove_entry(&self.scope)
        } else {
            None
        };
        drop(scopes);
        drop(removed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn forgotten_preparations_stay_invalid_while_other_and_reopened_scopes_are_current() {
        let registry = Preparations::default();
        let old = registry.enter(Scope::Window("w1".into()));
        let other = registry.enter(Scope::Window("w2".into()));
        registry.forget_window("w1");
        let reopened = registry.enter(Scope::Window("w1".into()));
        assert!(old.invalidated());
        assert!(!other.invalidated());
        assert!(!reopened.invalidated());
        assert_ne!(old.epoch, reopened.epoch);
        drop(old);
        assert!(!reopened.invalidated());
        registry.invalidate_all();
        assert!(other.invalidated());
        assert!(reopened.invalidated());
        drop((other, reopened));
        assert!(registry.scopes.lock().unwrap().is_empty());
    }

    #[test]
    fn completed_preparations_do_not_retain_window_labels() {
        let registry = Preparations::default();
        for index in 0..1000 {
            let label: Arc<str> = format!("window-{index}").into();
            let weak = Arc::downgrade(&label);
            let call = registry.enter(Scope::Window(label));
            assert!(weak.upgrade().is_some());
            drop(call);
            assert!(weak.upgrade().is_none());
        }
        assert!(registry.scopes.lock().unwrap().is_empty());
    }
}
