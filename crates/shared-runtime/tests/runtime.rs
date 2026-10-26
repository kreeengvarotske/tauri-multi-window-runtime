//! Behaviour of the runtime: cache budget and eviction, scope separation,
//! cancellation, overload, deadlines, shutdown, view size limits and the
//! terminal-outcome invariant of the counters.

use shared_runtime::{
    CachePolicy, CallError, CallOptions, Caller, OpContext, Operation, OperationConfig,
    OperationStats, RegistryError, Runtime, RuntimeConfig, ScopeRule, View, ViewCallError,
    ViewError,
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
        default_deadline: Duration::from_secs(30),
        shutdown_grace: Duration::from_secs(1),
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
        max_items: usize,
    ) -> Result<Vec<u32>, ViewError> {
        if request.offset > output.len() {
            return Err(ViewError::InvalidRequest("offset past the end".into()));
        }
        let limit = request.limit.min(max_items);
        Ok(output
            .iter()
            .skip(request.offset)
            .take(limit)
            .copied()
            .collect())
    }
    fn items(response: &Vec<u32>) -> usize {
        response.len()
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
    fn project(&self, output: &Vec<u32>, _: (), _: usize) -> Result<Vec<u32>, ViewError> {
        Ok(output.clone())
    }
    fn items(response: &Vec<u32>) -> usize {
        response.len()
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
            Err(ViewCallError::View(ViewError::TooLarge {
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
