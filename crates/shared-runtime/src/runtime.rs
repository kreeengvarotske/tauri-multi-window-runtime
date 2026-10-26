use runtime_core::{CacheBudget, CachedService, ServiceRunKind};
use std::{
    any::{Any, TypeId},
    collections::{HashMap, HashSet},
    fmt,
    hash::Hash,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, AtomicUsize, Ordering},
    },
};
use tokio::sync::{Notify, Semaphore, watch};

use crate::{
    CallError, CallOptions, Caller, ConfigError, OpContext, Operation, OperationConfig,
    OperationStats, RuntimeConfig, RuntimeStats, ScopeRule, View, ViewCallError, ViewError,
};

/// Lifecycle of a runtime.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Phase {
    /// Accepting calls.
    Running,
    /// `shutdown` started: new calls are rejected, calls in flight may finish.
    Draining,
    /// The grace period ended: calls still in flight return `ShuttingDown`.
    Aborted,
}

/// A registration or lookup that the runtime refuses.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RegistryError {
    /// Two operations or two views share a name.
    DuplicateName(&'static str),
    /// The same operation or view type was registered twice.
    DuplicateType(&'static str),
    /// A view was registered before its source operation.
    SourceNotRegistered {
        view: &'static str,
        operation: &'static str,
    },
    /// A handle was requested for a type that was never registered.
    NotRegistered(&'static str),
    /// The runtime limits are invalid.
    Config(ConfigError),
}

impl fmt::Display for RegistryError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::DuplicateName(name) => write!(f, "name `{name}` is already registered"),
            Self::DuplicateType(name) => write!(f, "type of `{name}` is already registered"),
            Self::SourceNotRegistered { view, operation } => {
                write!(
                    f,
                    "view `{view}` reads `{operation}`, which is not registered"
                )
            }
            Self::NotRegistered(name) => write!(f, "`{name}` is not registered"),
            Self::Config(error) => write!(f, "invalid runtime config: {error}"),
        }
    }
}

impl std::error::Error for RegistryError {}

/// State shared by every operation of one runtime.
struct Shared {
    config: RuntimeConfig,
    slots: Arc<Semaphore>,
    queued: AtomicUsize,
    phase: watch::Sender<Phase>,
    in_flight: AtomicUsize,
    idle: Notify,
}

impl Shared {
    async fn wait_idle(&self) {
        loop {
            let notified = self.idle.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if self.in_flight.load(Ordering::SeqCst) == 0 {
                return;
            }
            notified.await;
        }
    }
}

/// Which callers share a cached result.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
enum ScopeKey {
    Shared,
    Window(Arc<str>),
}

/// Error stored by the core service: an operation error, or no slot.
enum Failure<E> {
    Op(Arc<E>),
    Overloaded,
}

#[derive(Default)]
struct Counters {
    requests: AtomicU64,
    cache_hits: AtomicU64,
    executed: AtomicU64,
    coalesced: AtomicU64,
    overloaded: AtomicU64,
    deadline_exceeded: AtomicU64,
    shutting_down: AtomicU64,
    cancelled: AtomicU64,
    failed: AtomicU64,
    in_flight: AtomicU64,
}

fn bump(counter: &AtomicU64) {
    counter.fetch_add(1, Ordering::Relaxed);
}

type Service<O> = CachedService<
    (ScopeKey, <O as Operation>::Params),
    <O as Operation>::Output,
    Failure<<O as Operation>::Error>,
>;

struct OpEntry<O: Operation> {
    op: Arc<O>,
    scope: ScopeRule,
    service: Service<O>,
    budget_bytes: usize,
    counters: Counters,
    /// Windows that called a `PerWindow` operation, so that `invalidate`
    /// reaches each window's entry. Labels only, no data.
    windows: Mutex<HashSet<Arc<str>>>,
}

/// Type-erased access for stats and shutdown.
trait ErasedOp: Send + Sync {
    fn stats(&self) -> OperationStats;
    fn clear(&self);
}

impl<O: Operation> ErasedOp for OpEntry<O> {
    fn stats(&self) -> OperationStats {
        let c = &self.counters;
        let load = |counter: &AtomicU64| counter.load(Ordering::Relaxed);
        OperationStats {
            name: O::NAME,
            requests: load(&c.requests),
            cache_hits: load(&c.cache_hits),
            executed: load(&c.executed),
            coalesced: load(&c.coalesced),
            overloaded: load(&c.overloaded),
            deadline_exceeded: load(&c.deadline_exceeded),
            shutting_down: load(&c.shutting_down),
            cancelled: load(&c.cancelled),
            failed: load(&c.failed),
            in_flight: load(&c.in_flight),
            cache_entries: self.service.cached_entries(),
            cache_weight_bytes: self.service.cached_weight(),
            cache_budget_bytes: self.budget_bytes,
            evictions: self.service.evictions(),
        }
    }

    fn clear(&self) {
        self.service.clear();
    }
}

/// Builds a [`Runtime`]. Operations and views are registered once, at startup.
pub struct RuntimeBuilder {
    shared: Arc<Shared>,
    names: HashSet<&'static str>,
    ops: HashMap<TypeId, Arc<dyn Any + Send + Sync>>,
    erased: Vec<Arc<dyn ErasedOp>>,
    views: HashMap<TypeId, Arc<dyn Any + Send + Sync>>,
}

impl RuntimeBuilder {
    /// Fails when a limit cannot work, e.g. zero concurrent operations.
    pub fn new(config: RuntimeConfig) -> Result<Self, RegistryError> {
        config.validate().map_err(RegistryError::Config)?;
        let (phase, _) = watch::channel(Phase::Running);
        Ok(Self {
            shared: Arc::new(Shared {
                slots: Arc::new(Semaphore::new(config.max_concurrent_operations)),
                config,
                queued: AtomicUsize::new(0),
                phase,
                in_flight: AtomicUsize::new(0),
                idle: Notify::new(),
            }),
            names: HashSet::new(),
            ops: HashMap::new(),
            erased: Vec::new(),
            views: HashMap::new(),
        })
    }

    pub fn register<O: Operation>(
        mut self,
        op: O,
        config: OperationConfig,
    ) -> Result<Self, RegistryError> {
        let type_id = TypeId::of::<O>();
        if self.ops.contains_key(&type_id) {
            return Err(RegistryError::DuplicateType(O::NAME));
        }
        if !self.names.insert(O::NAME) {
            return Err(RegistryError::DuplicateName(O::NAME));
        }
        let op = Arc::new(op);
        let weigher = Arc::clone(&op);
        let budget = CacheBudget::new(config.cache_budget_bytes, move |output: &O::Output| {
            weigher.weight(output)
        });
        let entry = Arc::new(OpEntry::<O> {
            scope: op.scope(),
            service: CachedService::with_budget(op.policy(), budget),
            op,
            budget_bytes: config.cache_budget_bytes,
            counters: Counters::default(),
            windows: Mutex::new(HashSet::new()),
        });
        self.erased.push(entry.clone());
        self.ops.insert(type_id, entry);
        Ok(self)
    }

    /// Registers a view over an already registered operation.
    pub fn view<O: Operation, V: View<O>>(mut self, view: V) -> Result<Self, RegistryError> {
        let type_id = TypeId::of::<V>();
        if self.views.contains_key(&type_id) {
            return Err(RegistryError::DuplicateType(V::NAME));
        }
        if !self.ops.contains_key(&TypeId::of::<O>()) {
            return Err(RegistryError::SourceNotRegistered {
                view: V::NAME,
                operation: O::NAME,
            });
        }
        if !self.names.insert(V::NAME) {
            return Err(RegistryError::DuplicateName(V::NAME));
        }
        self.views.insert(type_id, Arc::new(view));
        Ok(self)
    }

    pub fn build(self) -> Runtime {
        Runtime {
            shared: self.shared,
            ops: self.ops,
            erased: self.erased,
            views: self.views,
        }
    }
}

/// One per application. Holds every operation's cache and limits.
pub struct Runtime {
    shared: Arc<Shared>,
    ops: HashMap<TypeId, Arc<dyn Any + Send + Sync>>,
    erased: Vec<Arc<dyn ErasedOp>>,
    views: HashMap<TypeId, Arc<dyn Any + Send + Sync>>,
}

impl Runtime {
    pub fn builder(config: RuntimeConfig) -> Result<RuntimeBuilder, RegistryError> {
        RuntimeBuilder::new(config)
    }

    pub fn operation<O: Operation>(&self) -> Result<OperationHandle<O>, RegistryError> {
        let entry = self
            .ops
            .get(&TypeId::of::<O>())
            .cloned()
            .and_then(|entry| entry.downcast::<OpEntry<O>>().ok())
            .ok_or(RegistryError::NotRegistered(O::NAME))?;
        Ok(OperationHandle {
            entry,
            shared: Arc::clone(&self.shared),
        })
    }

    pub fn view<O: Operation, V: View<O>>(&self) -> Result<ViewHandle<O, V>, RegistryError> {
        let view = self
            .views
            .get(&TypeId::of::<V>())
            .cloned()
            .and_then(|view| view.downcast::<V>().ok())
            .ok_or(RegistryError::NotRegistered(V::NAME))?;
        Ok(ViewHandle {
            source: self.operation::<O>()?,
            view,
        })
    }

    pub fn stats(&self) -> RuntimeStats {
        RuntimeStats {
            operations: self.erased.iter().map(|op| op.stats()).collect(),
        }
    }

    /// Clears every operation's cache. Calls in flight still return their
    /// results, but those results are not cached.
    pub fn clear(&self) {
        for op in &self.erased {
            op.clear();
        }
    }

    /// Stops the runtime.
    ///
    /// New calls return `ShuttingDown` at once. Calls in flight get
    /// `shutdown_grace` to finish; after it they return `ShuttingDown` and
    /// their executions are dropped. Returns once no call is in flight, with
    /// every cache cleared. The runtime does not restart.
    pub async fn shutdown(&self) {
        let shared = &self.shared;
        shared.phase.send_if_modified(|phase| {
            let running = *phase == Phase::Running;
            if running {
                *phase = Phase::Draining;
            }
            running
        });
        let grace = shared.config.shutdown_grace;
        if tokio::time::timeout(grace, shared.wait_idle())
            .await
            .is_err()
        {
            shared.phase.send_replace(Phase::Aborted);
            shared.wait_idle().await;
        }
        shared.phase.send_replace(Phase::Aborted);
        self.clear();
    }
}

/// Decrements the in-flight counters when a call ends in any way.
struct InFlight<'a> {
    shared: &'a Shared,
    op: &'a AtomicU64,
}

impl<'a> InFlight<'a> {
    fn enter(shared: &'a Shared, op: &'a AtomicU64) -> Self {
        shared.in_flight.fetch_add(1, Ordering::SeqCst);
        op.fetch_add(1, Ordering::Relaxed);
        Self { shared, op }
    }
}

impl Drop for InFlight<'_> {
    fn drop(&mut self) {
        self.op.fetch_sub(1, Ordering::Relaxed);
        if self.shared.in_flight.fetch_sub(1, Ordering::SeqCst) == 1 {
            self.shared.idle.notify_waiters();
        }
    }
}

/// Counts a call as `cancelled` if it is dropped before an outcome is set.
struct Outcome<'a> {
    counters: &'a Counters,
    recorded: bool,
}

impl Outcome<'_> {
    fn record(&mut self, counter: &AtomicU64, failed: bool) {
        bump(counter);
        if failed {
            bump(&self.counters.failed);
        }
        self.recorded = true;
    }
}

impl Drop for Outcome<'_> {
    fn drop(&mut self) {
        if !self.recorded {
            bump(&self.counters.cancelled);
        }
    }
}

/// Releases a queue position when the waiting execution gets a slot or is
/// dropped.
struct QueueSlot<'a>(&'a AtomicUsize);

impl Drop for QueueSlot<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

/// Typed entry point of one operation. Cheap to clone.
pub struct OperationHandle<O: Operation> {
    entry: Arc<OpEntry<O>>,
    shared: Arc<Shared>,
}

impl<O: Operation> Clone for OperationHandle<O> {
    fn clone(&self) -> Self {
        Self {
            entry: Arc::clone(&self.entry),
            shared: Arc::clone(&self.shared),
        }
    }
}

impl<O: Operation> OperationHandle<O> {
    /// Returns the shared output for `params`, from the cache, from an
    /// execution in flight, or from a new execution.
    ///
    /// The execution runs in the task of the caller that started it. If that
    /// caller is dropped or reaches its deadline before the result is
    /// published, one remaining caller restarts it (core semantics B3).
    pub async fn get(
        &self,
        caller: &Caller,
        params: O::Params,
        options: CallOptions,
    ) -> Result<Arc<O::Output>, CallError<O::Error>> {
        let entry = &*self.entry;
        let shared = &*self.shared;
        let counters = &entry.counters;
        bump(&counters.requests);
        // Enter before reading the phase so that `shutdown` never sees an
        // idle runtime while this call is about to start.
        let _in_flight = InFlight::enter(shared, &counters.in_flight);
        let mut outcome = Outcome {
            counters,
            recorded: false,
        };
        let mut phase = shared.phase.subscribe();
        if *phase.borrow_and_update() != Phase::Running {
            outcome.record(&counters.shutting_down, true);
            return Err(CallError::ShuttingDown);
        }

        let scope = match entry.scope {
            ScopeRule::Shared => ScopeKey::Shared,
            ScopeRule::PerWindow => {
                let window = caller.window_key();
                entry
                    .windows
                    .lock()
                    .unwrap_or_else(|p| p.into_inner())
                    .insert(Arc::clone(&window));
                ScopeKey::Window(window)
            }
        };
        let ctx = OpContext {
            phase: phase.clone(),
        };
        let op = &entry.op;
        let run = entry
            .service
            .run_with_metadata((scope, params.clone()), || async move {
                let _permit = match Arc::clone(&shared.slots).try_acquire_owned() {
                    Ok(permit) => permit,
                    Err(_) => {
                        let max = shared.config.max_queued_operations;
                        if shared.queued.fetch_add(1, Ordering::SeqCst) >= max {
                            shared.queued.fetch_sub(1, Ordering::SeqCst);
                            return Err(Failure::Overloaded);
                        }
                        let _slot = QueueSlot(&shared.queued);
                        Arc::clone(&shared.slots)
                            .acquire_owned()
                            .await
                            .expect("the slot semaphore is never closed")
                    }
                };
                op.run(ctx, params)
                    .await
                    .map_err(|error| Failure::Op(Arc::new(error)))
            });
        let deadline = options.deadline.unwrap_or(shared.config.default_deadline);

        let result = tokio::select! {
            result = tokio::time::timeout(deadline, run) => result,
            _ = phase.wait_for(|phase| *phase == Phase::Aborted) => {
                outcome.record(&counters.shutting_down, true);
                return Err(CallError::ShuttingDown);
            }
        };
        let Ok(run) = result else {
            outcome.record(&counters.deadline_exceeded, true);
            return Err(CallError::DeadlineExceeded);
        };
        let kind_counter = match run.kind {
            ServiceRunKind::CacheHit => &counters.cache_hits,
            ServiceRunKind::Executed => &counters.executed,
            ServiceRunKind::Coalesced => &counters.coalesced,
        };
        match run.result {
            Ok(output) => {
                outcome.record(kind_counter, false);
                Ok(output)
            }
            Err(failure) => match &*failure {
                Failure::Overloaded => {
                    outcome.record(&counters.overloaded, true);
                    Err(CallError::Overloaded)
                }
                Failure::Op(error) => {
                    outcome.record(kind_counter, true);
                    Err(CallError::Operation(Arc::clone(error)))
                }
            },
        }
    }

    /// Drops the cached output for `params` in every scope, and keeps
    /// executions already in flight from caching theirs. Returns `true` if
    /// any cached entry existed.
    pub fn invalidate(&self, params: &O::Params) -> bool {
        let entry = &*self.entry;
        match entry.scope {
            ScopeRule::Shared => entry
                .service
                .invalidate(&(ScopeKey::Shared, params.clone())),
            ScopeRule::PerWindow => {
                let windows: Vec<_> = entry
                    .windows
                    .lock()
                    .unwrap_or_else(|p| p.into_inner())
                    .iter()
                    .cloned()
                    .collect();
                let mut any = false;
                for window in windows {
                    any |= entry
                        .service
                        .invalidate(&(ScopeKey::Window(window), params.clone()));
                }
                any
            }
        }
    }

    /// Drops every cached output of this operation.
    pub fn clear(&self) {
        self.entry.service.clear();
    }

    pub fn stats(&self) -> OperationStats {
        self.entry.stats()
    }
}

/// Typed entry point of one view. Cheap to clone.
pub struct ViewHandle<O: Operation, V: View<O>> {
    source: OperationHandle<O>,
    view: Arc<V>,
}

impl<O: Operation, V: View<O>> Clone for ViewHandle<O, V> {
    fn clone(&self) -> Self {
        Self {
            source: self.source.clone(),
            view: Arc::clone(&self.view),
        }
    }
}

impl<O: Operation, V: View<O>> ViewHandle<O, V> {
    /// Reads the source output (shared, cached, coalesced) and returns a
    /// bounded projection of it. A response with more than `max_items`
    /// items is refused, never truncated.
    pub async fn get(
        &self,
        caller: &Caller,
        request: V::Request,
        options: CallOptions,
    ) -> Result<V::Response, ViewCallError<O::Error>> {
        let params = self.view.source(&request);
        let output = self
            .source
            .get(caller, params, options)
            .await
            .map_err(ViewCallError::Source)?;
        let max_items = self.view.max_items();
        let response = self
            .view
            .project(&output, request, max_items)
            .map_err(ViewCallError::View)?;
        let items = V::items(&response);
        if items > max_items {
            return Err(ViewCallError::View(ViewError::TooLarge {
                items,
                max_items,
            }));
        }
        Ok(response)
    }

    pub fn max_items(&self) -> usize {
        self.view.max_items()
    }
}
