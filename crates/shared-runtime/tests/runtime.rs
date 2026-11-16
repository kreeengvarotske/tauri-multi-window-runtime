//! Behaviour of the runtime: cache budget and eviction, scope separation,
//! cancellation, overload, deadlines, shutdown, view size limits and the
//! terminal-outcome invariant of the counters.

use shared_runtime::{
    CachePolicy, CallError, CallOptions, Caller, OpContext, Operation, OperationConfig,
    OperationStats, RegistryError, ResponseBudget, Runtime, RuntimeConfig, ScopeRule, View,
    ViewCallError, ViewError,
};
use std::{
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::sync::Semaphore;

const LIMIT: Duration = Duration::from_secs(5);

fn config() -> RuntimeConfig {
    RuntimeConfig {
        max_concurrent_operations: 4,
        max_queued_operations: 16,
        max_concurrent_projections: 2,
        max_queued_projections: 16,
        default_deadline: Duration::from_secs(30),
        shutdown_grace: Duration::from_secs(1),
        cache_budget_bytes: 4 << 20,
    }
}

fn budget(bytes: usize) -> OperationConfig {
    OperationConfig {
        cache_budget_bytes: bytes,
    }
}

/// Loads `params` bytes. `0` fails. Optionally waits on a gate or sleeps.
#[derive(Clone)]
struct Load {
    scope: ScopeRule,
    executions: Arc<AtomicUsize>,
    gate: Option<Arc<Semaphore>>,
    sleep: Option<Duration>,
    saw_shutdown: Arc<AtomicUsize>,
}

impl Load {
    fn new(scope: ScopeRule) -> Self {
        Self {
            scope,
            executions: Arc::default(),
            gate: None,
            sleep: None,
            saw_shutdown: Arc::default(),
        }
    }
    fn gated(scope: ScopeRule) -> (Self, Arc<Semaphore>) {
        let gate = Arc::new(Semaphore::new(0));
        let mut op = Self::new(scope);
        op.gate = Some(Arc::clone(&gate));
        (op, gate)
    }
    fn sleeping(duration: Duration) -> Self {
        let mut op = Self::new(ScopeRule::Shared);
        op.sleep = Some(duration);
        op
    }
    fn executions(&self) -> usize {
        self.executions.load(Ordering::SeqCst)
    }
}

impl Operation for Load {
    const NAME: &'static str = "test.load";
    type Params = u32;
    type Output = Vec<u8>;
    type Error = String;

    fn policy(&self) -> CachePolicy {
        CachePolicy::Forever
    }
    fn scope(&self) -> ScopeRule {
        self.scope
    }
    fn weight(&self, output: &Vec<u8>) -> usize {
        output.len()
    }
    async fn run(&self, ctx: OpContext, params: u32) -> Result<Vec<u8>, String> {
        self.executions.fetch_add(1, Ordering::SeqCst);
        if let Some(gate) = &self.gate {
            gate.acquire().await.expect("gate open").forget();
        }
        if let Some(duration) = self.sleep {
            tokio::time::sleep(duration).await;
        }
        if ctx.is_shutting_down() {
            self.saw_shutdown.fetch_add(1, Ordering::SeqCst);
        }
        if params == 0 {
            return Err("empty".to_owned());
        }
        Ok(vec![0; params as usize])
    }
}

fn runtime_with(op: Load, cache_bytes: usize) -> Runtime {
    Runtime::builder(config())
        .unwrap()
        .register(op, budget(cache_bytes))
        .unwrap()
        .build()
}

fn stats(runtime: &Runtime) -> OperationStats {
    runtime.stats().operation(Load::NAME).unwrap().clone()
}

fn assert_balanced(stats: &OperationStats) {
    assert_eq!(stats.in_flight, 0, "{stats:?}");
    assert_eq!(stats.requests, stats.outcomes(), "unbalanced: {stats:?}");
}

async fn wait_until(mut condition: impl FnMut() -> bool, what: &str) {
    tokio::time::timeout(LIMIT, async {
        while !condition() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("timed out waiting for: {what}"));
}

/// Under paused time a sleep completes only once every other task is
/// blocked, so after `settle` each spawned call has registered wherever it
/// waits (slot queue, in-flight entry, gate). No wall-clock assumption.
async fn settle() {
    tokio::time::sleep(Duration::from_millis(1)).await;
}

fn window(label: &str) -> Caller {
    Caller::window(label)
}

const NO_OPTIONS: CallOptions = CallOptions { deadline: None };

// ---------------------------------------------------------------- budget

struct Empty;

impl Operation for Empty {
    const NAME: &'static str = "test.empty";
    type Params = u32;
    type Output = ();
    type Error = String;

    fn policy(&self) -> CachePolicy {
        CachePolicy::Forever
    }

    fn weight(&self, _: &()) -> usize {
        0
    }

    async fn run(&self, _: OpContext, _: u32) -> Result<(), String> {
        Ok(())
    }
}

#[tokio::test]
async fn zero_weight_outputs_cannot_bypass_the_cache_budget() {
    for capacity in [0, 2] {
        let runtime = Runtime::builder(config())
            .unwrap()
            .register(Empty, budget(capacity))
            .unwrap()
            .build();
        let empty = runtime.operation::<Empty>().unwrap();
        for key in 0..5 {
            empty.get(&window("a"), key, NO_OPTIONS).await.unwrap();
        }
        let s = empty.stats();
        assert_eq!(s.cache_entries, capacity);
        assert_eq!(s.cache_weight_bytes, capacity);
        assert_eq!(s.evictions, if capacity == 0 { 0 } else { 3 });
    }
}

#[tokio::test]
async fn cache_budget_evicts_least_recently_used_outputs() {
    let op = Load::new(ScopeRule::Shared);
    let runtime = runtime_with(op.clone(), 100);
    let load = runtime.operation::<Load>().unwrap();
    let main = window("main");

    load.get(&main, 40, NO_OPTIONS).await.unwrap();
    load.get(&main, 50, NO_OPTIONS).await.unwrap();
    load.get(&main, 40, NO_OPTIONS).await.unwrap(); // hit, 40 is now most recent
    load.get(&main, 30, NO_OPTIONS).await.unwrap(); // 120 > 100: evicts 50

    let s = stats(&runtime);
    assert_eq!((s.cache_entries, s.cache_weight_bytes), (2, 70));
    assert_eq!((s.cache_budget_bytes, s.evictions), (100, 1));
    assert_eq!((s.executed, s.cache_hits), (3, 1));

    load.get(&main, 40, NO_OPTIONS).await.unwrap();
    load.get(&main, 50, NO_OPTIONS).await.unwrap(); // evicted: executes again
    assert_eq!(op.executions(), 4);
    assert!(stats(&runtime).cache_weight_bytes <= 100);

    // An output heavier than the whole budget is returned but not cached.
    let big = load.get(&main, 500, NO_OPTIONS).await.unwrap();
    assert_eq!(big.len(), 500);
    load.get(&main, 500, NO_OPTIONS).await.unwrap();
    assert_eq!(op.executions(), 6);
    let s = stats(&runtime);
    assert!(s.cache_weight_bytes <= 100, "{s:?}");
    assert_balanced(&s);
}

#[tokio::test]
async fn operation_errors_are_not_cached() {
    let op = Load::new(ScopeRule::Shared);
    let runtime = runtime_with(op.clone(), 1024);
    let load = runtime.operation::<Load>().unwrap();

    for _ in 0..2 {
        let error = load.get(&window("main"), 0, NO_OPTIONS).await.unwrap_err();
        assert!(matches!(error, CallError::Operation(e) if *e == "empty"));
    }
    let s = stats(&runtime);
    assert_eq!((op.executions(), s.executed, s.failed), (2, 2, 2));
    assert_eq!(s.cache_entries, 0);
    assert_balanced(&s);
}

// ---------------------------------------------------------------- scope

#[tokio::test]
async fn shared_scope_executes_once_for_all_windows() {
    let op = Load::new(ScopeRule::Shared);
    let runtime = runtime_with(op.clone(), 1024);
    let load = runtime.operation::<Load>().unwrap();

    let a = load.get(&window("a"), 8, NO_OPTIONS).await.unwrap();
    let b = load.get(&window("b"), 8, NO_OPTIONS).await.unwrap();
    assert!(Arc::ptr_eq(&a, &b), "windows got different copies");
    assert_eq!(op.executions(), 1);
    assert_eq!(stats(&runtime).cache_entries, 1);
}

#[tokio::test]
async fn per_window_scope_separates_windows_and_invalidates_all() {
    let op = Load::new(ScopeRule::PerWindow);
    let runtime = runtime_with(op.clone(), 1024);
    let load = runtime.operation::<Load>().unwrap();

    let a = load.get(&window("a"), 8, NO_OPTIONS).await.unwrap();
    let b = load.get(&window("b"), 8, NO_OPTIONS).await.unwrap();
    assert!(!Arc::ptr_eq(&a, &b), "per-window outputs were shared");
    load.get(&window("a"), 8, NO_OPTIONS).await.unwrap();
    assert_eq!(op.executions(), 2);
    assert_eq!(stats(&runtime).cache_entries, 2);

    assert!(load.invalidate(&8));
    assert_eq!(stats(&runtime).cache_entries, 0);
    load.get(&window("a"), 8, NO_OPTIONS).await.unwrap();
    load.get(&window("b"), 8, NO_OPTIONS).await.unwrap();
    assert_eq!(op.executions(), 4);
    assert_balanced(&stats(&runtime));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn per_window_scope_does_not_coalesce_across_windows() {
    let (op, gate) = Load::gated(ScopeRule::PerWindow);
    let runtime = Arc::new(runtime_with(op.clone(), 1024));
    let spawn = |label: &'static str| {
        let load = runtime.operation::<Load>().unwrap();
        tokio::spawn(async move { load.get(&window(label), 8, NO_OPTIONS).await })
    };
    let a = spawn("a");
    let b = spawn("b");
    wait_until(|| op.executions() == 2, "both windows execute").await;
    gate.add_permits(2);
    a.await.unwrap().unwrap();
    b.await.unwrap().unwrap();
    let s = stats(&runtime);
    assert_eq!((s.executed, s.coalesced), (2, 0));
    assert_balanced(&s);
}

// ---------------------------------------------------------- cancellation

#[tokio::test(start_paused = true)]
async fn cancelled_caller_is_counted_and_remaining_caller_gets_result() {
    let (op, gate) = Load::gated(ScopeRule::Shared);
    let runtime = Arc::new(runtime_with(op.clone(), 1024));
    let load = runtime.operation::<Load>().unwrap();

    let first = {
        let load = load.clone();
        tokio::spawn(async move { load.get(&window("a"), 8, NO_OPTIONS).await })
    };
    wait_until(|| op.executions() == 1, "first execution started").await;
    let second = {
        let load = load.clone();
        tokio::spawn(async move { load.get(&window("b"), 8, NO_OPTIONS).await })
    };
    settle().await;
    assert_eq!(stats(&runtime).in_flight, 2, "second caller joined");

    first.abort();
    assert!(first.await.unwrap_err().is_cancelled());
    // The remaining caller restarts the dropped execution (core B3).
    wait_until(|| op.executions() == 2, "remaining caller restarts").await;
    gate.add_permits(1);
    let output = tokio::time::timeout(LIMIT, second).await.unwrap().unwrap();
    assert_eq!(output.unwrap().len(), 8);

    let s = stats(&runtime);
    assert_eq!((s.requests, s.cancelled, s.executed), (2, 1, 1));
    assert_eq!(s.failed, 0, "a cancelled call is not a failure");
    assert_balanced(&s);
}

// -------------------------------------------------------------- overload

#[tokio::test(start_paused = true)]
async fn full_slots_and_queue_return_overloaded() {
    let (op, gate) = Load::gated(ScopeRule::Shared);
    let runtime = Arc::new(
        Runtime::builder(RuntimeConfig {
            max_concurrent_operations: 1,
            max_queued_operations: 1,
            ..config()
        })
        .unwrap()
        .register(op.clone(), budget(1024))
        .unwrap()
        .build(),
    );
    let load = runtime.operation::<Load>().unwrap();
    let spawn = |params: u32| {
        let load = load.clone();
        tokio::spawn(async move { load.get(&window("main"), params, NO_OPTIONS).await })
    };

    let running = spawn(1); // takes the only slot
    wait_until(|| op.executions() == 1, "first execution holds the slot").await;
    let queued = spawn(2); // waits in the queue
    settle().await;
    assert_eq!(stats(&runtime).in_flight, 2, "second call queued");
    let joined = spawn(1); // coalesces, needs no slot
    settle().await;
    assert_eq!(stats(&runtime).in_flight, 3, "third call joined");

    let rejected = load.get(&window("main"), 3, NO_OPTIONS).await;
    assert!(
        matches!(rejected, Err(CallError::Overloaded)),
        "{rejected:?}"
    );

    gate.add_permits(2);
    for task in [running, queued, joined] {
        tokio::time::timeout(LIMIT, task)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
    }
    assert_eq!(op.executions(), 2);

    let s = stats(&runtime);
    assert_eq!((s.overloaded, s.failed), (1, 1));
    assert_eq!((s.executed, s.coalesced), (2, 1));
    assert_balanced(&s);

    // The rejection was not cached: the same call succeeds once slots free up.
    gate.add_permits(1);
    load.get(&window("main"), 3, NO_OPTIONS).await.unwrap();
}

// -------------------------------------------------------------- deadline

#[tokio::test(start_paused = true)]
async fn zero_deadline_neither_starts_work_nor_reads_a_cached_result() {
    let op = Load::new(ScopeRule::Shared);
    let runtime = runtime_with(op.clone(), 1024);
    let load = runtime.operation::<Load>().unwrap();
    let caller = window("a");
    load.get(&caller, 4, NO_OPTIONS).await.unwrap();

    let expired = CallOptions {
        deadline: Some(Duration::ZERO),
    };
    for params in [4, 8] {
        assert!(matches!(
            load.get(&caller, params, expired).await,
            Err(CallError::DeadlineExceeded)
        ));
    }
    assert_eq!(op.executions(), 1);
    let s = stats(&runtime);
    assert_eq!((s.deadline_exceeded, s.executed, s.cache_hits), (2, 1, 0));
    assert_balanced(&s);
}

#[tokio::test(start_paused = true)]
async fn deadline_wins_when_the_operation_becomes_ready_on_the_same_tick() {
    let op = Load::sleeping(Duration::from_secs(1));
    let runtime = runtime_with(op, 1024);
    let load = runtime.operation::<Load>().unwrap();
    let result = load
        .get(
            &window("a"),
            8,
            CallOptions {
                deadline: Some(Duration::from_secs(1)),
            },
        )
        .await;
    assert!(matches!(result, Err(CallError::DeadlineExceeded)));
    assert_eq!(stats(&runtime).cache_entries, 0);
}

#[tokio::test(start_paused = true)]
async fn deadline_ends_only_the_caller_that_set_it() {
    let op = Load::sleeping(Duration::from_secs(10));
    let runtime = Arc::new(runtime_with(op.clone(), 1024));
    let load = runtime.operation::<Load>().unwrap();

    let patient = {
        let load = load.clone();
        tokio::spawn(async move {
            let options = CallOptions {
                deadline: Some(Duration::from_secs(60)),
            };
            load.get(&window("a"), 8, options).await
        })
    };
    wait_until(|| op.executions() == 1, "execution started").await;
    let options = CallOptions {
        deadline: Some(Duration::from_secs(1)),
    };
    let hasty = load.get(&window("b"), 8, options).await;
    assert!(
        matches!(hasty, Err(CallError::DeadlineExceeded)),
        "{hasty:?}"
    );

    assert_eq!(patient.await.unwrap().unwrap().len(), 8);
    assert_eq!(op.executions(), 1);
    let s = stats(&runtime);
    assert_eq!((s.deadline_exceeded, s.executed, s.failed), (1, 1, 1));
    assert_balanced(&s);
}

#[tokio::test(start_paused = true)]
async fn default_deadline_applies_without_call_options() {
    let op = Load::sleeping(Duration::from_secs(120));
    let runtime = runtime_with(op, 1024);
    let load = runtime.operation::<Load>().unwrap();
    let result = load.get(&window("a"), 8, NO_OPTIONS).await;
    assert!(matches!(result, Err(CallError::DeadlineExceeded)));
    assert_balanced(&stats(&runtime));
}

// -------------------------------------------------------------- shutdown

#[tokio::test(start_paused = true)]
async fn retrying_shutdown_does_not_restart_grace() {
    let op = Load::sleeping(Duration::from_secs(3600));
    let runtime = runtime_with(op.clone(), 1024);
    let load = runtime.operation::<Load>().unwrap();
    let stuck = tokio::spawn(async move { load.get(&window("a"), 8, NO_OPTIONS).await });
    wait_until(|| op.executions() == 1, "execution started").await;

    let started = tokio::time::Instant::now();
    let partial = tokio::time::timeout(Duration::from_millis(750), runtime.shutdown());
    assert!(partial.await.is_err());
    runtime.shutdown().await;

    assert!(started.elapsed() < Duration::from_millis(1100));
    assert!(matches!(stuck.await.unwrap(), Err(CallError::ShuttingDown)));
}

#[tokio::test(start_paused = true)]
async fn shutdown_lets_calls_in_flight_finish_within_grace() {
    let op = Load::sleeping(Duration::from_millis(500));
    let runtime = Arc::new(runtime_with(op.clone(), 1024));
    let load = runtime.operation::<Load>().unwrap();

    load.get(&window("a"), 4, NO_OPTIONS).await.unwrap(); // cached
    let in_flight = {
        let load = load.clone();
        tokio::spawn(async move { load.get(&window("a"), 8, NO_OPTIONS).await })
    };
    wait_until(|| op.executions() == 2, "execution started").await;
    let shutdown = {
        let runtime = Arc::clone(&runtime);
        tokio::spawn(async move { runtime.shutdown().await })
    };
    tokio::task::yield_now().await;

    let late = load.get(&window("b"), 4, NO_OPTIONS).await;
    assert!(matches!(late, Err(CallError::ShuttingDown)), "{late:?}");
    assert_eq!(in_flight.await.unwrap().unwrap().len(), 8);
    shutdown.await.unwrap();
    assert_eq!(op.saw_shutdown.load(Ordering::SeqCst), 1);

    let s = stats(&runtime);
    assert_eq!(s.cache_entries, 0, "shutdown keeps cached outputs");
    assert_eq!((s.shutting_down, s.executed, s.cache_hits), (1, 2, 0));
    assert_balanced(&s);
}

#[tokio::test(start_paused = true)]
async fn shutdown_ends_calls_that_outlive_grace() {
    let op = Load::sleeping(Duration::from_secs(3600));
    let runtime = Arc::new(runtime_with(op.clone(), 1024));
    let load = runtime.operation::<Load>().unwrap();
    let options = CallOptions {
        deadline: Some(Duration::from_secs(7200)),
    };
    let stuck = {
        let load = load.clone();
        tokio::spawn(async move { load.get(&window("a"), 8, options).await })
    };
    wait_until(|| op.executions() == 1, "execution started").await;

    runtime.shutdown().await;
    let result = stuck.await.unwrap();
    assert!(matches!(result, Err(CallError::ShuttingDown)), "{result:?}");
    let s = stats(&runtime);
    assert_eq!((s.shutting_down, s.failed), (1, 1));
    assert_balanced(&s);

    let after = load.get(&window("a"), 8, NO_OPTIONS).await;
    assert!(matches!(after, Err(CallError::ShuttingDown)));
}

// ------------------------------------------------------------------ views

/// Source for view tests: `params` items.
struct Catalog {
    executions: Arc<AtomicUsize>,
}

impl Operation for Catalog {
    const NAME: &'static str = "test.catalog";
    type Params = u32;
    type Output = Vec<u32>;
    type Error = String;

    fn policy(&self) -> CachePolicy {
        CachePolicy::Forever
    }
    fn weight(&self, output: &Vec<u32>) -> usize {
        output.len() * size_of::<u32>()
    }
    async fn run(&self, _ctx: OpContext, params: u32) -> Result<Vec<u32>, String> {
        self.executions.fetch_add(1, Ordering::SeqCst);
        Ok((0..params).collect())
    }
}

struct PageRequest {
    offset: usize,
    limit: usize,
}

/// A page, clamped to `max_items`.
struct Page;

impl View<Catalog> for Page {
    const NAME: &'static str = "test.catalog.page";
    type Request = PageRequest;
    type Response = Vec<u32>;

    fn source(&self, _request: &PageRequest) -> u32 {
        1000
    }
    fn max_items(&self) -> usize {
        10
    }
    fn project(
        &self,
        output: &Vec<u32>,
        request: PageRequest,
        budget: &mut ResponseBudget,
    ) -> Result<Vec<u32>, ViewError> {
        if request.offset > output.len() {
            return Err(ViewError::InvalidRequest("offset past the end".into()));
        }
        let limit = request.limit.min(budget.max_items());
        let mut page = Vec::new();
        for value in output.iter().skip(request.offset).take(limit) {
            budget.take(size_of::<u32>())?;
            page.push(*value);
        }
        Ok(page)
    }
    fn items(response: &Vec<u32>) -> usize {
        response.len()
    }
    fn max_response_bytes(&self) -> usize {
        1024
    }
    fn response_bytes(response: &Vec<u32>) -> usize {
        response.len() * size_of::<u32>()
    }
}

/// Ignores its limit; the runtime must refuse its response.
struct Unbounded;

impl View<Catalog> for Unbounded {
    const NAME: &'static str = "test.catalog.unbounded";
    type Request = ();
    type Response = Vec<u32>;

    fn source(&self, _request: &()) -> u32 {
        1000
    }
    fn max_items(&self) -> usize {
        10
    }
    fn project(
        &self,
        output: &Vec<u32>,
        _: (),
        _: &mut ResponseBudget,
    ) -> Result<Vec<u32>, ViewError> {
        Ok(output.clone())
    }
    fn items(response: &Vec<u32>) -> usize {
        response.len()
    }
    fn max_response_bytes(&self) -> usize {
        1024
    }
    fn response_bytes(response: &Vec<u32>) -> usize {
        response.len() * size_of::<u32>()
    }
}

#[tokio::test]
async fn views_are_bounded_and_share_one_source_output() {
    let executions = Arc::new(AtomicUsize::new(0));
    let runtime = Runtime::builder(config())
        .unwrap()
        .register(
            Catalog {
                executions: Arc::clone(&executions),
            },
            budget(1 << 20),
        )
        .unwrap()
        .view::<Catalog, _>(Page)
        .unwrap()
        .view::<Catalog, _>(Unbounded)
        .unwrap()
        .build();
    let page = runtime.view::<Catalog, Page>().unwrap();
    let unbounded = runtime.view::<Catalog, Unbounded>().unwrap();
    let main = window("main");

    let first = page
        .get(
            &main,
            PageRequest {
                offset: 0,
                limit: 5,
            },
            NO_OPTIONS,
        )
        .await
        .unwrap();
    assert_eq!(first, vec![0, 1, 2, 3, 4]);
    let expired = page
        .get(
            &main,
            PageRequest {
                offset: 0,
                limit: 5,
            },
            CallOptions {
                deadline: Some(Duration::ZERO),
            },
        )
        .await;
    assert!(matches!(expired, Err(ViewCallError::DeadlineExceeded)));
    let clamped = page
        .get(
            &main,
            PageRequest {
                offset: 990,
                limit: 500,
            },
            NO_OPTIONS,
        )
        .await
        .unwrap();
    assert_eq!(clamped.len(), 10);

    let invalid = page
        .get(
            &main,
            PageRequest {
                offset: 5000,
                limit: 1,
            },
            NO_OPTIONS,
        )
        .await;
    assert!(matches!(
        invalid,
        Err(ViewCallError::View(ViewError::InvalidRequest(_)))
    ));

    let refused = unbounded.get(&main, (), NO_OPTIONS).await;
    assert!(
        matches!(
            refused,
            Err(ViewCallError::View(ViewError::TooManyItems {
                items: 1000,
                max_items: 10
            }))
        ),
        "{refused:?}"
    );
    assert_eq!(
        executions.load(Ordering::SeqCst),
        1,
        "views re-executed the source"
    );
}

// --------------------------------------------------------------- registry

#[test]
fn registry_rejects_duplicates_missing_sources_and_bad_limits() {
    let builder = || Runtime::builder(config()).unwrap();
    let load = || Load::new(ScopeRule::Shared);
    let catalog = || Catalog {
        executions: Arc::default(),
    };

    let twice = builder()
        .register(load(), budget(1))
        .unwrap()
        .register(load(), budget(1));
    assert_eq!(twice.err(), Some(RegistryError::DuplicateType(Load::NAME)));

    let orphan = builder().view::<Catalog, _>(Page);
    assert!(matches!(
        orphan,
        Err(RegistryError::SourceNotRegistered { .. })
    ));

    let runtime = builder().register(catalog(), budget(1)).unwrap().build();
    assert!(matches!(
        runtime.operation::<Load>(),
        Err(RegistryError::NotRegistered(Load::NAME))
    ));
    assert!(matches!(
        runtime.view::<Catalog, Page>(),
        Err(RegistryError::NotRegistered(Page::NAME))
    ));

    for bad in [
        RuntimeConfig {
            max_concurrent_operations: 0,
            ..config()
        },
        RuntimeConfig {
            default_deadline: Duration::ZERO,
            ..config()
        },
    ] {
        assert!(matches!(
            Runtime::builder(bad),
            Err(RegistryError::Config(_))
        ));
    }
}

#[test]
fn registry_rejects_duplicate_names() {
    struct Other;
    impl Operation for Other {
        const NAME: &'static str = Load::NAME;
        type Params = u32;
        type Output = ();
        type Error = ();
        fn policy(&self) -> CachePolicy {
            CachePolicy::NoStore
        }
        fn weight(&self, _: &()) -> usize {
            0
        }
        async fn run(&self, _: OpContext, _: u32) -> Result<(), ()> {
            Ok(())
        }
    }
    let result = Runtime::builder(config())
        .unwrap()
        .register(Load::new(ScopeRule::Shared), budget(1))
        .unwrap()
        .register(Other, budget(1));
    assert_eq!(result.err(), Some(RegistryError::DuplicateName(Load::NAME)));
}

// ------------------------------------------------- runtime memory bounds

#[test]
fn operation_budgets_must_fit_in_the_runtime_budget() {
    let total = RuntimeConfig {
        cache_budget_bytes: 1000,
        ..config()
    };
    let catalog = Catalog {
        executions: Arc::default(),
    };
    let result = Runtime::builder(total.clone())
        .unwrap()
        .register(Load::new(ScopeRule::Shared), budget(700))
        .unwrap()
        .register(catalog, budget(301));
    assert_eq!(
        result.err(),
        Some(RegistryError::BudgetExceeded {
            operation: Catalog::NAME,
            requested: 301,
            available: 300,
        })
    );

    let runtime = Runtime::builder(total)
        .unwrap()
        .register(Load::new(ScopeRule::Shared), budget(700))
        .unwrap()
        .register(
            Catalog {
                executions: Arc::default(),
            },
            budget(300),
        )
        .unwrap()
        .build();
    let stats = runtime.stats();
    assert_eq!(
        (stats.cache_budget_bytes, stats.allocated_budget_bytes()),
        (1000, 1000)
    );
}

#[tokio::test]
async fn summed_cache_weight_stays_within_the_runtime_budget() {
    let runtime = Runtime::builder(RuntimeConfig {
        cache_budget_bytes: 300,
        ..config()
    })
    .unwrap()
    .register(Load::new(ScopeRule::PerWindow), budget(200))
    .unwrap()
    .register(
        Catalog {
            executions: Arc::default(),
        },
        budget(100),
    )
    .unwrap()
    .build();
    let load = runtime.operation::<Load>().unwrap();
    let catalog = runtime.operation::<Catalog>().unwrap();
    for (i, label) in ["a", "b", "c", "d", "e"].into_iter().enumerate() {
        load.get(&window(label), 60 + i as u32, NO_OPTIONS)
            .await
            .unwrap();
        catalog
            .get(&window(label), 10 + i as u32, NO_OPTIONS)
            .await
            .unwrap();
        let stats = runtime.stats();
        assert!(
            stats.cache_weight_bytes() <= stats.cache_budget_bytes,
            "{stats:?}"
        );
        for op in &stats.operations {
            assert!(op.cache_weight_bytes <= op.cache_budget_bytes, "{op:?}");
        }
    }
    assert!(runtime.stats().operations.iter().all(|op| op.evictions > 0));
}

/// One item can be arbitrarily large; the byte limit must catch it.
struct Notes;

impl Operation for Notes {
    const NAME: &'static str = "test.notes";
    type Params = usize;
    type Output = Vec<String>;
    type Error = String;

    fn policy(&self) -> CachePolicy {
        CachePolicy::Forever
    }
    fn weight(&self, output: &Vec<String>) -> usize {
        output.iter().map(String::len).sum()
    }
    async fn run(&self, _ctx: OpContext, huge: usize) -> Result<Vec<String>, String> {
        Ok(vec!["short".to_owned(), "x".repeat(huge)])
    }
}

/// Returns the note at `index`.
struct Note;

impl View<Notes> for Note {
    const NAME: &'static str = "test.notes.one";
    type Request = (usize, usize);
    type Response = Vec<String>;

    fn source(&self, request: &(usize, usize)) -> usize {
        request.0
    }
    fn max_items(&self) -> usize {
        10
    }
    fn max_response_bytes(&self) -> usize {
        64 * 1024
    }
    fn project(
        &self,
        output: &Vec<String>,
        (_, index): (usize, usize),
        budget: &mut ResponseBudget,
    ) -> Result<Vec<String>, ViewError> {
        let Some(note) = output.get(index) else {
            return Ok(Vec::new());
        };
        budget.take(note.len())?;
        Ok(vec![note.clone()])
    }
    fn items(response: &Vec<String>) -> usize {
        response.len()
    }
    fn response_bytes(response: &Vec<String>) -> usize {
        response.iter().map(String::len).sum()
    }
}

#[tokio::test]
async fn one_huge_item_is_refused_by_the_byte_limit() {
    let runtime = Runtime::builder(config())
        .unwrap()
        .register(Notes, budget(2 << 20))
        .unwrap()
        .view::<Notes, _>(Note)
        .unwrap()
        .build();
    let note = runtime.view::<Notes, Note>().unwrap();
    let main = window("main");
    let huge = 1 << 20;

    let short = note.get(&main, (huge, 0), NO_OPTIONS).await.unwrap();
    assert_eq!(short, vec!["short".to_owned()]);

    let refused = note.get(&main, (huge, 1), NO_OPTIONS).await;
    assert!(
        matches!(
            refused,
            Err(ViewCallError::View(ViewError::TooManyBytes {
                bytes,
                max_bytes: 65536,
            })) if bytes == huge
        ),
        "one item under max_items slipped past the byte limit: {:?}",
        refused.as_ref().map(|r| r.len())
    );
}

/// The output is only a seed; responses are generated from it, so a request
/// can ask for far more than any limit allows.
struct Seed;

impl Operation for Seed {
    const NAME: &'static str = "test.seed";
    type Params = ();
    type Output = u8;
    type Error = String;

    fn policy(&self) -> CachePolicy {
        CachePolicy::Forever
    }
    fn weight(&self, _output: &u8) -> usize {
        1
    }
    async fn run(&self, _ctx: OpContext, _params: ()) -> Result<u8, String> {
        Ok(b'x')
    }
}

const GENERATED_ITEM: usize = 1024;
const GENERATED_MAX_BYTES: usize = 8 * GENERATED_ITEM;

/// Generates `request` items of `GENERATED_ITEM` bytes each, counting every
/// item it builds. `charge_first` decides whether it charges the budget
/// before building an item (as `View::project` requires) or not at all.
struct Generated {
    charge_first: bool,
    built: Arc<AtomicUsize>,
}

impl Generated {
    fn new(charge_first: bool) -> (Self, Arc<AtomicUsize>) {
        let built = Arc::new(AtomicUsize::new(0));
        let view = Self {
            charge_first,
            built: built.clone(),
        };
        (view, built)
    }
}

impl View<Seed> for Generated {
    const NAME: &'static str = "test.seed.generated";
    type Request = usize;
    type Response = Vec<String>;

    fn source(&self, _request: &usize) {}
    fn max_items(&self) -> usize {
        10_000
    }
    fn max_response_bytes(&self) -> usize {
        GENERATED_MAX_BYTES
    }
    fn project(
        &self,
        seed: &u8,
        count: usize,
        budget: &mut ResponseBudget,
    ) -> Result<Vec<String>, ViewError> {
        let mut items = Vec::new();
        for _ in 0..count {
            if self.charge_first {
                budget.take(GENERATED_ITEM)?;
            }
            items.push(char::from(*seed).to_string().repeat(GENERATED_ITEM));
            self.built.fetch_add(1, Ordering::SeqCst);
        }
        Ok(items)
    }
    fn items(response: &Vec<String>) -> usize {
        response.len()
    }
    fn response_bytes(response: &Vec<String>) -> usize {
        response.iter().map(String::len).sum()
    }
}

fn generated_runtime(view: Generated) -> Runtime {
    Runtime::builder(config())
        .unwrap()
        .register(Seed, budget(1024))
        .unwrap()
        .view::<Seed, _>(view)
        .unwrap()
        .build()
}

#[tokio::test]
async fn a_view_that_charges_first_stops_building_at_the_byte_limit() {
    let (view, built) = Generated::new(true);
    let runtime = generated_runtime(view);
    let generated = runtime.view::<Seed, Generated>().unwrap();
    let main = window("main");

    let fits = generated.get(&main, 8, NO_OPTIONS).await.unwrap();
    assert_eq!(fits.len(), 8);
    assert_eq!(built.swap(0, Ordering::SeqCst), 8);

    // Asks for 1000 items, about 1 MiB; only the 8 that fit are built.
    let refused = generated.get(&main, 1000, NO_OPTIONS).await;
    assert!(
        matches!(
            refused,
            Err(ViewCallError::View(ViewError::TooManyBytes {
                bytes,
                max_bytes: GENERATED_MAX_BYTES,
            })) if bytes == 9 * GENERATED_ITEM
        ),
        "{:?}",
        refused.as_ref().map(|r| r.len())
    );
    assert_eq!(
        built.load(Ordering::SeqCst),
        8,
        "items were built after the budget refused one"
    );
}

#[tokio::test]
async fn a_view_that_ignores_the_budget_is_refused_after_building() {
    // Documents the backstop: the response is refused, but only after the
    // view built all of it. Its peak memory is not bounded by the runtime.
    let (view, built) = Generated::new(false);
    let runtime = generated_runtime(view);
    let generated = runtime.view::<Seed, Generated>().unwrap();

    let refused = generated.get(&window("main"), 1000, NO_OPTIONS).await;
    assert!(
        matches!(
            refused,
            Err(ViewCallError::View(ViewError::TooManyBytes {
                bytes,
                max_bytes: GENERATED_MAX_BYTES,
            })) if bytes == 1000 * GENERATED_ITEM
        ),
        "{:?}",
        refused.as_ref().map(|r| r.len())
    );
    assert_eq!(built.load(Ordering::SeqCst), 1000);
}

#[test]
fn response_budget_charges_nothing_on_a_refused_item() {
    let mut budget = ResponseBudget::new(3, 10);
    budget.take(4).unwrap();
    assert_eq!(
        budget.take(7),
        Err(ViewError::TooManyBytes {
            bytes: 11,
            max_bytes: 10
        })
    );
    assert_eq!((budget.items(), budget.bytes()), (1, 4));
    budget.take(6).unwrap();
    assert_eq!(budget.remaining_bytes(), 0);
    budget.take(0).unwrap();
    assert_eq!(
        budget.take(0),
        Err(ViewError::TooManyItems {
            items: 4,
            max_items: 3
        })
    );
    assert_eq!((budget.items(), budget.bytes()), (3, 10));
    assert_eq!(budget.remaining_items(), 0);

    // Saturates instead of overflowing on a huge charge.
    let mut budget = ResponseBudget::new(1, usize::MAX);
    budget.take(usize::MAX).unwrap();
    let mut budget = ResponseBudget::new(2, 1);
    budget.take(1).unwrap();
    assert_eq!(
        budget.take(usize::MAX),
        Err(ViewError::TooManyBytes {
            bytes: usize::MAX,
            max_bytes: 1
        })
    );
}

// --------------------------------------------------------- window lifecycle

#[tokio::test]
async fn forget_window_drops_only_that_windows_entries() {
    let op = Load::new(ScopeRule::PerWindow);
    let runtime = runtime_with(op.clone(), 1024);
    let load = runtime.operation::<Load>().unwrap();
    let (a, b) = (window("a"), window("b"));

    load.get(&a, 8, NO_OPTIONS).await.unwrap();
    load.get(&a, 9, NO_OPTIONS).await.unwrap();
    load.get(&b, 8, NO_OPTIONS).await.unwrap();
    assert_eq!(stats(&runtime).cache_entries, 3);

    assert_eq!(runtime.forget_window(&a), 2);
    let s = stats(&runtime);
    assert_eq!((s.cache_entries, s.cache_weight_bytes), (1, 8));
    assert_eq!(runtime.forget_window(&a), 0, "forgetting twice is a no-op");

    // b is untouched; a window reopened under the label "a" starts empty.
    load.get(&b, 8, NO_OPTIONS).await.unwrap();
    load.get(&a, 8, NO_OPTIONS).await.unwrap();
    let s = stats(&runtime);
    assert_eq!((s.cache_hits, op.executions()), (1, 4));

    // invalidate still reaches every window's entry.
    assert!(load.invalidate(&8));
    assert_eq!(stats(&runtime).cache_entries, 0);
    assert_balanced(&stats(&runtime));
}

#[tokio::test]
async fn forget_window_ignores_shared_operations() {
    let op = Load::new(ScopeRule::Shared);
    let runtime = runtime_with(op, 1024);
    let load = runtime.operation::<Load>().unwrap();
    load.get(&window("a"), 8, NO_OPTIONS).await.unwrap();
    assert_eq!(runtime.forget_window(&window("a")), 0);
    assert_eq!(stats(&runtime).cache_entries, 1);
}

#[tokio::test(start_paused = true)]
async fn result_of_a_forgotten_window_in_flight_is_not_cached() {
    let (op, gate) = Load::gated(ScopeRule::PerWindow);
    let runtime = Arc::new(runtime_with(op.clone(), 1024));
    let load = runtime.operation::<Load>().unwrap();
    let call = {
        let load = load.clone();
        tokio::spawn(async move { load.get(&window("a"), 8, NO_OPTIONS).await })
    };
    settle().await;
    assert_eq!(op.executions(), 1);

    runtime.forget_window(&window("a"));
    let reopened = {
        let load = load.clone();
        tokio::spawn(async move { load.get(&window("a"), 8, NO_OPTIONS).await })
    };
    settle().await;
    assert_eq!(
        op.executions(),
        2,
        "the reopened window must not join the destroyed window's execution"
    );

    gate.add_permits(1);
    let old = call.await.unwrap().unwrap();
    assert_eq!(old.len(), 8, "the original caller still gets its result");
    assert_eq!(stats(&runtime).cache_entries, 0);

    gate.add_permits(1);
    let new = reopened.await.unwrap().unwrap();
    assert!(!Arc::ptr_eq(&old, &new));
    let cached = load.get(&window("a"), 8, NO_OPTIONS).await.unwrap();
    assert!(Arc::ptr_eq(&cached, &new));
    assert_balanced(&stats(&runtime));
}

// ------------------------------------------------------ projection limit

struct LoadLength;

impl View<Load> for LoadLength {
    const NAME: &'static str = "test.load.length";
    type Request = u32;
    type Response = usize;
    fn source(&self, request: &u32) -> u32 {
        *request
    }
    fn max_items(&self) -> usize {
        1
    }
    fn max_response_bytes(&self) -> usize {
        size_of::<usize>()
    }
    fn project(
        &self,
        output: &Vec<u8>,
        _: u32,
        budget: &mut ResponseBudget,
    ) -> Result<usize, ViewError> {
        budget.take(size_of::<usize>())?;
        Ok(output.len())
    }
    fn items(_: &usize) -> usize {
        1
    }
    fn response_bytes(_: &usize) -> usize {
        size_of::<usize>()
    }
}

mod projection_queue {
    use super::*;
    use std::{
        future::Future,
        pin::Pin,
        task::{Context, Poll, Waker},
    };

    struct TrackedLength(Arc<AtomicUsize>);

    impl View<Load> for TrackedLength {
        const NAME: &'static str = "test.tracked-length";
        type Request = u32;
        type Response = usize;
        fn source(&self, request: &u32) -> u32 {
            self.0.fetch_add(1, Ordering::SeqCst);
            *request
        }
        fn max_items(&self) -> usize {
            1
        }
        fn max_response_bytes(&self) -> usize {
            size_of::<usize>()
        }
        fn project(
            &self,
            output: &Vec<u8>,
            request: u32,
            budget: &mut ResponseBudget,
        ) -> Result<usize, ViewError> {
            LoadLength.project(output, request, budget)
        }
        fn items(_: &usize) -> usize {
            1
        }
        fn response_bytes(_: &usize) -> usize {
            size_of::<usize>()
        }
    }

    fn setup(queue: usize) -> (Runtime, Load, Arc<Semaphore>, Arc<AtomicUsize>) {
        let (op, gate) = Load::gated(ScopeRule::Shared);
        let sources = Arc::new(AtomicUsize::new(0));
        let runtime = Runtime::builder(RuntimeConfig {
            max_concurrent_projections: 1,
            max_queued_projections: queue,
            ..config()
        })
        .unwrap()
        .register(op.clone(), budget(1024))
        .unwrap()
        .view::<Load, _>(TrackedLength(Arc::clone(&sources)))
        .unwrap()
        .build();
        (runtime, op, gate, sources)
    }

    fn poll<F: Future>(future: Pin<&mut F>) -> Poll<F::Output> {
        future.poll(&mut Context::from_waker(Waker::noop()))
    }

    #[tokio::test]
    async fn full_queue_refuses_before_source_derivation_and_cancellation_releases_capacity() {
        let (runtime, op, gate, sources) = setup(1);
        let view = runtime.view::<Load, TrackedLength>().unwrap();
        let caller = window("main");
        let mut first = Box::pin(view.get(&caller, 1, NO_OPTIONS));
        let mut queued = Box::pin(view.get(&caller, 2, NO_OPTIONS));
        let mut excess = Box::pin(view.get(&caller, 3, NO_OPTIONS));
        assert!(poll(first.as_mut()).is_pending());
        assert!(poll(queued.as_mut()).is_pending());
        assert!(
            matches!(
                poll(excess.as_mut()),
                Poll::Ready(Err(ViewCallError::Source(CallError::Overloaded)))
            ),
            "a full projection queue must reject immediately, not wait for a deadline"
        );
        let snapshot = runtime.stats();
        assert_eq!(
            (
                snapshot.active_projections,
                snapshot.queued_projections,
                snapshot.projection_overloads
            ),
            (1, 1, 1)
        );
        assert_eq!(
            sources.load(Ordering::SeqCst),
            2,
            "refused calls must not derive source parameters"
        );
        assert_eq!(op.executions(), 1);
        assert_eq!(stats(&runtime).requests, 1);

        drop(queued);
        assert_eq!(runtime.stats().queued_projections, 0);
        let mut replacement = Box::pin(view.get(&caller, 4, NO_OPTIONS));
        assert!(
            poll(replacement.as_mut()).is_pending(),
            "cancelled queue seat must be reusable"
        );
        drop(first);
        gate.add_permits(1);
        assert_eq!(replacement.await.unwrap(), 4);
        let snapshot = runtime.stats();
        assert_eq!(
            (
                snapshot.active_projections,
                snapshot.queued_projections,
                snapshot.projection_overloads
            ),
            (0, 0, 1)
        );
        // Cancellation after the semaphore assigned a permit, before the
        // waiter is polled again, must release both admission and its seat.
        let mut holder = Box::pin(view.get(&caller, 5, NO_OPTIONS));
        let mut waking = Box::pin(view.get(&caller, 6, NO_OPTIONS));
        assert!(poll(holder.as_mut()).is_pending());
        assert!(poll(waking.as_mut()).is_pending());
        drop(holder);
        drop(waking);
        assert_eq!(runtime.stats().active_projections, 0);
        assert_eq!(runtime.stats().queued_projections, 0);
        gate.add_permits(1);
        assert_eq!(view.get(&caller, 7, NO_OPTIONS).await.unwrap(), 7);
        assert_balanced(&stats(&runtime));
    }

    #[tokio::test]
    async fn zero_queue_allows_immediate_calls_and_refuses_waiting_calls() {
        let (runtime, _, gate, sources) = setup(0);
        let view = runtime.view::<Load, TrackedLength>().unwrap();
        let caller = window("main");
        let mut first = Box::pin(view.get(&caller, 1, NO_OPTIONS));
        assert!(poll(first.as_mut()).is_pending());
        assert!(matches!(
            view.get(&caller, 2, NO_OPTIONS).await,
            Err(ViewCallError::Source(CallError::Overloaded))
        ));
        assert_eq!(sources.load(Ordering::SeqCst), 1);
        gate.add_permits(1);
        assert_eq!(first.await.unwrap(), 1);
        assert_eq!(
            view.get(&caller, 1, NO_OPTIONS).await.unwrap(),
            1,
            "cache hits still need only immediate admission"
        );
        assert_eq!(runtime.stats().queued_projections, 0);
    }

    #[tokio::test(start_paused = true)]
    async fn queue_deadline_releases_capacity_without_requesting_a_source() {
        let (runtime, _, _, _) = setup(1);
        let view = runtime.view::<Load, TrackedLength>().unwrap();
        let caller = window("main");
        let mut first = Box::pin(view.get(&caller, 1, NO_OPTIONS));
        let mut queued = Box::pin(view.get(
            &caller,
            2,
            CallOptions {
                deadline: Some(Duration::from_millis(10)),
            },
        ));
        assert!(poll(first.as_mut()).is_pending());
        assert!(poll(queued.as_mut()).is_pending());
        tokio::time::advance(Duration::from_millis(10)).await;
        assert!(matches!(queued.await, Err(ViewCallError::DeadlineExceeded)));
        assert_eq!(runtime.stats().queued_projections, 0);
        assert_eq!(stats(&runtime).requests, 1);
        let mut replacement = Box::pin(view.get(&caller, 3, NO_OPTIONS));
        assert!(poll(replacement.as_mut()).is_pending());
        assert_eq!(runtime.stats().queued_projections, 1);
        drop(replacement);
        drop(first);
        assert_eq!(runtime.stats().active_projections, 0);
        assert_eq!(runtime.stats().queued_projections, 0);
    }

    #[tokio::test(start_paused = true)]
    async fn shutdown_releases_full_projection_queue_and_admission() {
        let (runtime, _, _, _) = setup(1);
        let view = runtime.view::<Load, TrackedLength>().unwrap();
        let caller = window("main");
        let mut first = Box::pin(view.get(&caller, 1, NO_OPTIONS));
        let mut queued = Box::pin(view.get(&caller, 2, NO_OPTIONS));
        assert!(poll(first.as_mut()).is_pending());
        assert!(poll(queued.as_mut()).is_pending());
        let (_, first, queued) = tokio::join!(runtime.shutdown(), first, queued);
        assert!(matches!(
            first,
            Err(ViewCallError::Source(CallError::ShuttingDown))
        ));
        assert!(matches!(
            queued,
            Err(ViewCallError::Source(CallError::ShuttingDown))
        ));
        let snapshot = runtime.stats();
        assert_eq!(
            (snapshot.active_projections, snapshot.queued_projections),
            (0, 0)
        );
        assert!(matches!(
            view.get(&caller, 3, NO_OPTIONS).await,
            Err(ViewCallError::Source(CallError::ShuttingDown))
        ));
        assert_balanced(&stats(&runtime));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn contending_windows_never_admit_more_than_the_queue_limit() {
        const CALLS: u32 = 64;
        const QUEUE: usize = 3;
        let (runtime, op, gate, sources) = setup(QUEUE);
        let runtime = Arc::new(runtime);
        let view = runtime.view::<Load, TrackedLength>().unwrap();
        let caller = window("holder");
        let mut first = Box::pin(view.get(&caller, 1, NO_OPTIONS));
        assert!(poll(first.as_mut()).is_pending());
        let started = Arc::new(Semaphore::new(0));
        let resume = Arc::new(Semaphore::new(0));
        let mut workers = Vec::new();
        for index in 0..CALLS {
            let view = view.clone();
            let started = Arc::clone(&started);
            let resume = Arc::clone(&resume);
            workers.push(tokio::spawn(async move {
                let caller = window(&format!("w{index}"));
                let mut future = Box::pin(view.get(&caller, index + 2, NO_OPTIONS));
                let initial =
                    std::future::poll_fn(|cx| Poll::Ready(future.as_mut().poll(cx))).await;
                started.add_permits(1);
                match initial {
                    Poll::Ready(result) => result,
                    Poll::Pending => {
                        resume.acquire().await.unwrap().forget();
                        future.await
                    }
                }
            }));
        }
        tokio::time::timeout(LIMIT, started.acquire_many(CALLS))
            .await
            .unwrap()
            .unwrap()
            .forget();
        let snapshot = runtime.stats();
        assert_eq!(
            (
                snapshot.active_projections,
                snapshot.queued_projections,
                snapshot.projection_overloads
            ),
            (1, QUEUE, u64::from(CALLS) - QUEUE as u64)
        );
        assert_eq!(sources.load(Ordering::SeqCst), QUEUE + 1);
        assert_eq!(op.executions(), 1);
        gate.add_permits(QUEUE + 1);
        resume.add_permits(CALLS as usize);
        assert_eq!(first.await.unwrap(), 1);
        let mut admitted = 0;
        let mut refused = 0;
        for worker in workers {
            match tokio::time::timeout(LIMIT, worker).await.unwrap().unwrap() {
                Ok(_) => admitted += 1,
                Err(ViewCallError::Source(CallError::Overloaded)) => refused += 1,
                other => panic!("unexpected outcome: {other:?}"),
            }
        }
        assert_eq!((admitted, refused), (QUEUE, CALLS as usize - QUEUE));
        let snapshot = runtime.stats();
        assert_eq!(
            (snapshot.active_projections, snapshot.queued_projections),
            (0, 0)
        );
        assert_eq!(op.executions(), QUEUE + 1);
        assert_balanced(&stats(&runtime));
    }
}

#[tokio::test]
async fn forgotten_window_queued_view_cannot_repopulate_its_cache() {
    use std::{
        future::Future,
        task::{Context, Waker},
    };
    let (op, gate) = Load::gated(ScopeRule::PerWindow);
    let runtime = Runtime::builder(RuntimeConfig {
        max_concurrent_projections: 1,
        ..config()
    })
    .unwrap()
    .register(op.clone(), budget(1024))
    .unwrap()
    .view::<Load, _>(LoadLength)
    .unwrap()
    .build();
    let view = runtime.view::<Load, LoadLength>().unwrap();
    let holder = window("holder");
    let closing = window("closing");
    let mut first = std::pin::pin!(view.get(&holder, 1, NO_OPTIONS));
    let mut queued = std::pin::pin!(view.get(&closing, 2, NO_OPTIONS));
    let mut cx = Context::from_waker(Waker::noop());
    assert!(first.as_mut().poll(&mut cx).is_pending());
    assert!(queued.as_mut().poll(&mut cx).is_pending());
    assert_eq!(op.executions(), 1, "queued view must not load its source");
    assert_eq!(runtime.forget_window(&closing), 0);
    gate.add_permits(2);
    assert_eq!(first.await.unwrap(), 1);
    assert_eq!(queued.await.unwrap(), 2, "old call still gets its result");
    assert_eq!(
        stats(&runtime).cache_entries,
        1,
        "closed window repopulated its cache after admission"
    );
    assert_balanced(&stats(&runtime));
}

#[tokio::test]
async fn old_queued_view_cannot_read_or_replace_a_reopened_windows_cache() {
    use std::{
        future::Future,
        task::{Context, Waker},
    };
    let (op, gate) = Load::gated(ScopeRule::PerWindow);
    let runtime = Runtime::builder(RuntimeConfig {
        max_concurrent_projections: 1,
        ..config()
    })
    .unwrap()
    .register(op.clone(), budget(1024))
    .unwrap()
    .view::<Load, _>(LoadLength)
    .unwrap()
    .build();
    let view = runtime.view::<Load, LoadLength>().unwrap();
    let holder = window("holder");
    let closing = window("closing");
    let mut first = std::pin::pin!(view.get(&holder, 1, NO_OPTIONS));
    let mut old = std::pin::pin!(view.get(&closing, 2, NO_OPTIONS));
    let mut cx = Context::from_waker(Waker::noop());
    assert!(first.as_mut().poll(&mut cx).is_pending());
    assert!(old.as_mut().poll(&mut cx).is_pending());
    runtime.forget_window(&closing);
    // A new window reuses the label while its predecessor is still queued.
    let source = runtime.operation::<Load>().unwrap();
    let reopened = window("closing");
    let mut fresh = std::pin::pin!(source.get(&reopened, 2, NO_OPTIONS));
    assert!(fresh.as_mut().poll(&mut cx).is_pending());
    gate.add_permits(3);
    let new_output = fresh.await.unwrap();
    assert_eq!(first.await.unwrap(), 1);
    assert_eq!(old.await.unwrap(), 2);
    assert_eq!(
        op.executions(),
        3,
        "old view consumed the reopened window's cache"
    );
    let current = source.get(&reopened, 2, NO_OPTIONS).await.unwrap();
    assert!(
        Arc::ptr_eq(&new_output, &current),
        "old view replaced the new cache"
    );
    assert_eq!(stats(&runtime).cache_entries, 2);
    assert_balanced(&stats(&runtime));
}

#[tokio::test]
async fn clear_covers_shared_views_waiting_for_projection_admission() {
    use std::{
        future::Future,
        task::{Context, Waker},
    };
    let (op, gate) = Load::gated(ScopeRule::Shared);
    let runtime = Runtime::builder(RuntimeConfig {
        max_concurrent_projections: 1,
        ..config()
    })
    .unwrap()
    .register(op, budget(1024))
    .unwrap()
    .view::<Load, _>(LoadLength)
    .unwrap()
    .build();
    let view = runtime.view::<Load, LoadLength>().unwrap();
    let a = window("a");
    let b = window("b");
    let mut first = std::pin::pin!(view.get(&a, 1, NO_OPTIONS));
    let mut queued = std::pin::pin!(view.get(&b, 2, NO_OPTIONS));
    let mut cx = Context::from_waker(Waker::noop());
    assert!(first.as_mut().poll(&mut cx).is_pending());
    assert!(queued.as_mut().poll(&mut cx).is_pending());
    runtime.clear();
    gate.add_permits(2);
    assert_eq!(first.await.unwrap(), 1);
    assert_eq!(queued.await.unwrap(), 2);
    assert_eq!(
        stats(&runtime).cache_entries,
        0,
        "queued view repopulated a cleared cache"
    );
    assert_balanced(&stats(&runtime));
}

/// A large shared blob; each response copies `params` bytes of it.
struct Blob;

impl Operation for Blob {
    const NAME: &'static str = "test.blob";
    type Params = ();
    type Output = Vec<u8>;
    type Error = String;

    fn policy(&self) -> CachePolicy {
        CachePolicy::Forever
    }
    fn weight(&self, output: &Vec<u8>) -> usize {
        output.len()
    }
    async fn run(&self, _ctx: OpContext, _: ()) -> Result<Vec<u8>, String> {
        Ok(vec![7; 4 << 20])
    }
}

/// Copies a large chunk; records how many projections run at once. While
/// `hold` is set, a projection waits until a second one is running (or the
/// hold is released, or 2 s pass), so projections overlap whenever the
/// limit allows it and the peak shows the limit.
struct Chunk {
    active: Arc<AtomicUsize>,
    peak: Arc<AtomicUsize>,
    hold: Arc<std::sync::atomic::AtomicBool>,
}

impl View<Blob> for Chunk {
    const NAME: &'static str = "test.blob.chunk";
    type Request = usize;
    type Response = Vec<u8>;

    fn source(&self, _: &usize) {}
    fn max_items(&self) -> usize {
        1 << 20
    }
    fn max_response_bytes(&self) -> usize {
        1 << 20
    }
    fn project(
        &self,
        output: &Vec<u8>,
        len: usize,
        _: &mut ResponseBudget,
    ) -> Result<Vec<u8>, ViewError> {
        let now = self.active.fetch_add(1, Ordering::SeqCst) + 1;
        self.peak.fetch_max(now, Ordering::SeqCst);
        let until = std::time::Instant::now() + Duration::from_secs(2);
        while self.hold.load(Ordering::SeqCst)
            && self.active.load(Ordering::SeqCst) < 2
            && std::time::Instant::now() < until
        {
            std::thread::yield_now();
        }
        let response = output[..len].to_vec();
        self.active.fetch_sub(1, Ordering::SeqCst);
        Ok(response)
    }
    fn items(response: &Vec<u8>) -> usize {
        response.len()
    }
    fn response_bytes(response: &Vec<u8>) -> usize {
        response.len()
    }
}

fn chunk_runtime(
    projections: usize,
) -> (
    Runtime,
    Arc<AtomicUsize>,
    Arc<std::sync::atomic::AtomicBool>,
) {
    let peak = Arc::new(AtomicUsize::new(0));
    let hold = Arc::new(std::sync::atomic::AtomicBool::new(true));
    let runtime = Runtime::builder(RuntimeConfig {
        max_concurrent_projections: projections,
        ..config()
    })
    .unwrap()
    .register(Blob, budget(4 << 20))
    .unwrap()
    .view::<Blob, _>(Chunk {
        active: Arc::default(),
        peak: Arc::clone(&peak),
        hold: Arc::clone(&hold),
    })
    .unwrap()
    .build();
    (runtime, peak, hold)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
async fn concurrent_windows_build_at_most_the_limit_of_large_responses() {
    let (runtime, peak, _hold) = chunk_runtime(2);
    let runtime = Arc::new(runtime);
    let chunk = runtime.view::<Blob, Chunk>().unwrap();
    // Load the source first. Eight windows racing for a cold source may
    // execute it twice: a call that misses the cache just before the insert
    // and reaches the coalescer just after the operation ended starts a new
    // execution (runtime-core `CachedService`, G6). This test is about the
    // projection limit, so it takes that race out.
    let blob = runtime.operation::<Blob>().unwrap();
    blob.get(&window("main"), (), NO_OPTIONS).await.unwrap();
    let mut calls = Vec::new();
    for i in 0..8 {
        let chunk = chunk.clone();
        calls.push(tokio::spawn(async move {
            chunk
                .get_with(&window(&format!("w{i}")), 1 << 20, NO_OPTIONS, |r| r.len())
                .await
        }));
    }
    for call in calls {
        let len = tokio::time::timeout(Duration::from_secs(60), call)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(len.unwrap(), 1 << 20);
    }
    assert_eq!(
        peak.load(Ordering::SeqCst),
        2,
        "projections ran beyond the limit (or never in parallel)"
    );
    let s = runtime.stats();
    let blob = s.operation(Blob::NAME).unwrap();
    assert_eq!(blob.executed, 1, "source shared by all windows");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn waiting_for_a_projection_slot_respects_the_deadline() {
    let (runtime, _peak, hold) = chunk_runtime(1);
    let runtime = Arc::new(runtime);
    let chunk = runtime.view::<Blob, Chunk>().unwrap();
    // Load the source first so the second call reaches the slot quickly.
    let blob = runtime.operation::<Blob>().unwrap();
    blob.get(&window("a"), (), NO_OPTIONS).await.unwrap();

    let first = {
        let chunk = chunk.clone();
        tokio::spawn(async move { chunk.get(&window("a"), 16, NO_OPTIONS).await })
    };
    tokio::time::sleep(Duration::from_millis(100)).await; // first holds the slot
    let short = CallOptions {
        deadline: Some(Duration::from_millis(50)),
    };
    let late = chunk.get(&window("b"), 16, short).await;
    assert!(
        matches!(late, Err(ViewCallError::DeadlineExceeded)),
        "{late:?}"
    );
    hold.store(false, Ordering::SeqCst);
    assert_eq!(first.await.unwrap().unwrap().len(), 16);
    assert_eq!(
        chunk.get(&window("b"), 16, NO_OPTIONS).await.unwrap().len(),
        16
    );
}

#[test]
fn zero_projection_slots_is_rejected() {
    let bad = RuntimeConfig {
        max_concurrent_projections: 0,
        ..config()
    };
    assert!(matches!(
        Runtime::builder(bad),
        Err(RegistryError::Config(_))
    ));
}

#[test]
fn configuration_rejects_limits_above_semaphore_capacity() {
    let max = Semaphore::MAX_PERMITS;
    assert!(
        Runtime::builder(RuntimeConfig {
            max_concurrent_operations: max,
            max_concurrent_projections: max,
            ..config()
        })
        .is_ok()
    );
    for bad in [
        RuntimeConfig {
            max_concurrent_operations: max + 1,
            ..config()
        },
        RuntimeConfig {
            max_concurrent_projections: max + 1,
            ..config()
        },
    ] {
        assert!(matches!(
            Runtime::builder(bad),
            Err(RegistryError::Config(_))
        ));
    }
}

// ------------------------------------------------ shutdown during a view

/// A view call is in flight from its start until `get_with` returns,
/// `finish` (the adapter's serialization) included. Shutdown waits for it;
/// a call waiting for a projection slot gives up when the grace ends.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn shutdown_waits_for_a_view_in_progress_and_ends_one_waiting_for_a_slot() {
    let hold = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let runtime = Arc::new(
        Runtime::builder(RuntimeConfig {
            max_concurrent_projections: 1,
            shutdown_grace: Duration::from_millis(100),
            ..config()
        })
        .unwrap()
        .register(Blob, budget(4 << 20))
        .unwrap()
        .view::<Blob, _>(Chunk {
            active: Arc::default(),
            peak: Arc::default(),
            hold,
        })
        .unwrap()
        .build(),
    );
    let chunk = runtime.view::<Blob, Chunk>().unwrap();
    // The source output is cached: the operation itself is no longer running.
    runtime
        .operation::<Blob>()
        .unwrap()
        .get(&window("a"), (), NO_OPTIONS)
        .await
        .unwrap();

    // A holds the only projection slot inside `finish`.
    let (entered_tx, entered_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel::<()>();
    let first = {
        let chunk = chunk.clone();
        tokio::spawn(async move {
            chunk
                .get_with(&window("a"), 16, NO_OPTIONS, move |response| {
                    entered_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                    response.len()
                })
                .await
        })
    };
    tokio::task::spawn_blocking(move || entered_rx.recv().unwrap())
        .await
        .unwrap();
    // B waits for the slot.
    let second = {
        let chunk = chunk.clone();
        tokio::spawn(async move { chunk.get(&window("b"), 16, NO_OPTIONS).await })
    };
    tokio::time::sleep(Duration::from_millis(20)).await;

    let shutdown = {
        let runtime = Arc::clone(&runtime);
        tokio::spawn(async move { runtime.shutdown().await })
    };
    // Past the grace: B is ended, but shutdown still waits for A.
    let late = tokio::time::timeout(LIMIT, second).await.unwrap().unwrap();
    assert!(
        matches!(late, Err(ViewCallError::Source(CallError::ShuttingDown))),
        "a call waiting for a slot ends with the grace: {late:?}"
    );
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(
        !shutdown.is_finished(),
        "shutdown returned while a view was still serializing"
    );
    // New view calls are refused at once.
    assert!(matches!(
        chunk.get(&window("c"), 16, NO_OPTIONS).await,
        Err(ViewCallError::Source(CallError::ShuttingDown))
    ));

    release_tx.send(()).unwrap();
    assert_eq!(
        tokio::time::timeout(LIMIT, first)
            .await
            .unwrap()
            .unwrap()
            .unwrap(),
        16,
        "work already in finish completes"
    );
    tokio::time::timeout(LIMIT, shutdown)
        .await
        .expect("shutdown ends once the view returns")
        .unwrap();
}
