use runtime_core::{CacheBudget, CachedService, ServiceRunKind};
use std::{
    any::{Any, TypeId},
    collections::{HashMap, HashSet},
    fmt,
    hash::Hash,
    sync::{
        Arc,
        atomic::{AtomicU64, AtomicUsize, Ordering},
    },
};
use tokio::sync::{Notify, Semaphore, watch};
use tokio::time::Instant;

use crate::{
    CallError, CallOptions, Caller, ConfigError, OpContext, Operation, OperationConfig,
    OperationStats, ResponseBudget, RuntimeConfig, RuntimeStats, ScopeRule, View, ViewCallError,
    ViewError,
};

/// Lifecycle of a runtime.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Phase {
    /// Accepting calls.
    Running,
    /// `shutdown` started: new calls are rejected, calls in flight may finish.
    Draining(Instant),
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
    /// The operation's cache budget does not fit in what is left of the
    /// runtime's total cache budget.
    BudgetExceeded {
        operation: &'static str,
        requested: usize,
        available: usize,
    },
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
            Self::BudgetExceeded {
                operation,
                requested,
                available,
            } => write!(
                f,
                "`{operation}` asks for a {requested}-byte cache budget, {available} bytes are left"
            ),
        }
    }
}

impl std::error::Error for RegistryError {}

/// State shared by every operation of one runtime.
struct Shared {
    config: RuntimeConfig,
    slots: Arc<Semaphore>,
    queued: AtomicUsize,
    projections: Semaphore,
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
}

/// Type-erased access for stats, window lifecycle and shutdown.
trait ErasedOp: Send + Sync {
    fn stats(&self) -> OperationStats;
    fn clear(&self);
    fn forget_window(&self, label: &str) -> usize;
}

impl<O: Operation> ErasedOp for OpEntry<O> {
    fn stats(&self) -> OperationStats {
        let c = &self.counters;
        let load = |counter: &AtomicU64| counter.load(Ordering::Relaxed);
        let cache = self.service.cache_stats();
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
            cache_entries: cache.entries,
            cache_weight_bytes: cache.weight,
            cache_budget_bytes: self.budget_bytes,
            evictions: cache.evictions,
        }
    }

    fn clear(&self) {
        self.service.clear();
    }

    fn forget_window(&self, label: &str) -> usize {
        match self.scope {
            ScopeRule::Shared => 0,
            ScopeRule::PerWindow => self.service.invalidate_matching(
                |(scope, _)| matches!(scope, ScopeKey::Window(window) if &**window == label),
            ),
        }
    }
}

/// Builds a [`Runtime`]. Operations and views are registered once, at startup.
pub struct RuntimeBuilder {
    shared: Arc<Shared>,
    names: HashSet<&'static str>,
    ops: HashMap<TypeId, Arc<dyn Any + Send + Sync>>,
    erased: Vec<Arc<dyn ErasedOp>>,
    views: HashMap<TypeId, Arc<dyn Any + Send + Sync>>,
    allocated_budget: usize,
}

impl RuntimeBuilder {
    /// Fails when a limit cannot work, e.g. zero concurrent operations.
    pub fn new(config: RuntimeConfig) -> Result<Self, RegistryError> {
        config.validate().map_err(RegistryError::Config)?;
        let (phase, _) = watch::channel(Phase::Running);
        Ok(Self {
            shared: Arc::new(Shared {
                slots: Arc::new(Semaphore::new(config.max_concurrent_operations)),
                projections: Semaphore::new(config.max_concurrent_projections),
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
            allocated_budget: 0,
        })
    }

    /// Fails on a duplicate name or type, or when `config.cache_budget_bytes`
    /// does not fit in what is left of `RuntimeConfig::cache_budget_bytes`.
    pub fn register<O: Operation>(
        mut self,
        op: O,
        config: OperationConfig,
    ) -> Result<Self, RegistryError> {
        let type_id = TypeId::of::<O>();
        if self.ops.contains_key(&type_id) {
            return Err(RegistryError::DuplicateType(O::NAME));
        }
        let available = self.shared.config.cache_budget_bytes - self.allocated_budget;
        if config.cache_budget_bytes > available {
            return Err(RegistryError::BudgetExceeded {
                operation: O::NAME,
                requested: config.cache_budget_bytes,
                available,
            });
        }
        if !self.names.insert(O::NAME) {
            return Err(RegistryError::DuplicateName(O::NAME));
        }
        self.allocated_budget += config.cache_budget_bytes;
        let op = Arc::new(op);
        let weigher = Arc::clone(&op);
        let budget = CacheBudget::new(config.cache_budget_bytes, move |output: &O::Output| {
            weigher.weight(output).max(1)
        });
        let entry = Arc::new(OpEntry::<O> {
            scope: op.scope(),
            service: CachedService::with_budget(op.policy(), budget),
            op,
            budget_bytes: config.cache_budget_bytes,
            counters: Counters::default(),
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

    /// The limits the runtime was built with.
    pub fn config(&self) -> &RuntimeConfig {
        &self.shared.config
    }

    pub fn stats(&self) -> RuntimeStats {
        RuntimeStats {
            operations: self.erased.iter().map(|op| op.stats()).collect(),
            cache_budget_bytes: self.shared.config.cache_budget_bytes,
        }
    }

    /// Drops every `PerWindow` output of a window that has closed. The
    /// adapter calls it when Tauri reports the window destroyed. Calls of
    /// that window still in flight return their results, but those results
    /// are not cached. A window opened later under the same label starts
    /// empty. Returns how many cached outputs were dropped.
    ///
    /// The runtime keeps no list of windows, so nothing grows with the
    /// number of windows ever opened beyond their cached outputs, which the
    /// budget bounds.
    pub fn forget_window(&self, caller: &Caller) -> usize {
        self.erased
            .iter()
            .map(|op| op.forget_window(caller.label()))
            .sum()
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
    /// their executions are dropped; view calls waiting for a projection slot
    /// end too. Returns once no call is in flight, with every cache cleared.
    /// A projection or `finish` already running is synchronous code and is
    /// waited for, not interrupted; a caller that must not wait longer than
    /// a limit wraps this in a timeout (the Tauri adapter does). The runtime
    /// does not restart. If the shutdown future is dropped, poll shutdown
    /// again to finish cleanup; the grace period still starts at the first call.
    pub async fn shutdown(&self) {
        let shared = &self.shared;
        shared.phase.send_if_modified(|phase| {
            let running = *phase == Phase::Running;
            if running {
                *phase = Phase::Draining(Instant::now());
            }
            running
        });
        let phase = *shared.phase.borrow();
        if let Phase::Draining(started) = phase {
            let remaining = shared
                .config
                .shutdown_grace
                .saturating_sub(started.elapsed());
            if !remaining.is_zero() {
                let _ = tokio::time::timeout(remaining, shared.wait_idle()).await;
            }
        }
        shared.phase.send_replace(Phase::Aborted);
        shared.wait_idle().await;
        self.clear();
    }
}

/// Decrements the in-flight counters when a call ends in any way. `op` is
/// the operation's own counter; a view call counts only runtime-wide.
struct InFlight<'a> {
    shared: &'a Shared,
    op: Option<&'a AtomicU64>,
}

impl<'a> InFlight<'a> {
    fn enter(shared: &'a Shared, op: Option<&'a AtomicU64>) -> Self {
        shared.in_flight.fetch_add(1, Ordering::SeqCst);
        if let Some(op) = op {
            op.fetch_add(1, Ordering::Relaxed);
        }
        Self { shared, op }
    }
}

impl Drop for InFlight<'_> {
    fn drop(&mut self) {
        if let Some(op) = self.op {
            op.fetch_sub(1, Ordering::Relaxed);
        }
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
        let _in_flight = InFlight::enter(shared, Some(&counters.in_flight));
        let mut outcome = Outcome {
            counters,
            recorded: false,
        };
        let mut phase = shared.phase.subscribe();
        if *phase.borrow_and_update() != Phase::Running {
            outcome.record(&counters.shutting_down, true);
            return Err(CallError::ShuttingDown);
        }

        let deadline = options.deadline.unwrap_or(shared.config.default_deadline);
        let started = Instant::now();
        if deadline.is_zero() {
            outcome.record(&counters.deadline_exceeded, true);
            return Err(CallError::DeadlineExceeded);
        }

        let scope = match entry.scope {
            ScopeRule::Shared => ScopeKey::Shared,
            ScopeRule::PerWindow => ScopeKey::Window(caller.window_key()),
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
        let run = tokio::select! {
            biased;
            _ = phase.wait_for(|phase| *phase == Phase::Aborted) => {
                outcome.record(&counters.shutting_down, true);
                return Err(CallError::ShuttingDown);
            }
            _ = tokio::time::sleep(deadline.saturating_sub(started.elapsed())) => {
                outcome.record(&counters.deadline_exceeded, true);
                return Err(CallError::DeadlineExceeded);
            }
            result = run => result,
        };
        if started.elapsed() >= deadline {
            outcome.record(&counters.deadline_exceeded, true);
            return Err(CallError::DeadlineExceeded);
        }
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
                entry
                    .service
                    .invalidate_matching(|(_, cached)| cached == params)
                    > 0
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
    /// items or more than `max_response_bytes` bytes is refused, never
    /// truncated. `max_items` alone bounds the count, not the bytes.
    pub async fn get(
        &self,
        caller: &Caller,
        request: V::Request,
        options: CallOptions,
    ) -> Result<V::Response, ViewCallError<O::Error>> {
        self.get_with(caller, request, options, |response| response)
            .await
    }

    /// Like `get`, but runs `finish` on the response while still holding the
    /// projection slot, so that an adapter can serialize the response
    /// within the same concurrency bound.
    ///
    /// The call is in flight from start to return, `finish` included:
    /// `shutdown` waits for it. Waiting for a projection slot ends with
    /// `Source(CallError::ShuttingDown)` once the shutdown grace has passed;
    /// the call's deadline covers admission and source lookup. A projection
    /// or `finish` already running is not interrupted. Admission precedes
    /// source lookup so queued views do not retain source outputs.
    pub async fn get_with<T>(
        &self,
        caller: &Caller,
        request: V::Request,
        options: CallOptions,
        finish: impl FnOnce(V::Response) -> T,
    ) -> Result<T, ViewCallError<O::Error>> {
        let shared = &*self.source.shared;
        // The whole call is in flight, `finish` included, so that `shutdown`
        // does not return or clear the caches while a response is still
        // being built or serialized. Entered before reading the phase, as in
        // `OperationHandle::get`.
        let _in_flight = InFlight::enter(shared, None);
        let mut phase = shared.phase.subscribe();
        if *phase.borrow_and_update() != Phase::Running {
            return Err(ViewCallError::Source(CallError::ShuttingDown));
        }
        let deadline = options.deadline.unwrap_or(shared.config.default_deadline);
        let started = Instant::now();
        let remaining = || {
            let time = deadline.saturating_sub(started.elapsed());
            if time.is_zero() {
                Err(ViewCallError::DeadlineExceeded)
            } else {
                Ok(time)
            }
        };
        let projection_wait = remaining()?;
        // Waiting for a slot ends at the caller's deadline or when the
        // shutdown grace ends, whichever comes first.
        let _slot = tokio::select! {
            slot = tokio::time::timeout(projection_wait, shared.projections.acquire()) => slot
                .map_err(|_| ViewCallError::DeadlineExceeded)?
                .expect("the projection semaphore is never closed"),
            _ = phase.wait_for(|phase| *phase == Phase::Aborted) => {
                return Err(ViewCallError::Source(CallError::ShuttingDown));
            }
        };
        if *phase.borrow() != Phase::Running {
            return Err(ViewCallError::Source(CallError::ShuttingDown));
        }
        remaining()?;
        let params = self.view.source(&request);
        let output = self
            .source
            .get(
                caller,
                params,
                CallOptions {
                    deadline: Some(remaining()?),
                },
            )
            .await
            .map_err(ViewCallError::Source)?;
        if *phase.borrow() == Phase::Aborted {
            return Err(ViewCallError::Source(CallError::ShuttingDown));
        }
        remaining()?;

        let mut budget = ResponseBudget::new(self.view.max_items(), self.view.max_response_bytes());
        let response = self
            .view
            .project(&output, request, &mut budget)
            .map_err(ViewCallError::View)?;
        // Backstop for a view that builds before charging the budget: the
        // response is refused, but its memory was already allocated.
        let (max_items, max_bytes) = (budget.max_items(), budget.max_bytes());
        let items = V::items(&response);
        if items > max_items {
            return Err(ViewCallError::View(ViewError::TooManyItems {
                items,
                max_items,
            }));
        }
        let bytes = V::response_bytes(&response);
        if bytes > max_bytes {
            return Err(ViewCallError::View(ViewError::TooManyBytes {
                bytes,
                max_bytes,
            }));
        }
        Ok(finish(response))
    }

    pub fn max_items(&self) -> usize {
        self.view.max_items()
    }
}
