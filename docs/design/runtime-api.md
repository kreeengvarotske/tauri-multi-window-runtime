# Proposal: stable Rust API for the in-process runtime

Status: **shape approved in principle** (review on #32, 2026-10-26; roadmap
Phase 3, see `docs/ROADMAP.md` in #30). The decisions are recorded in §10 and
the implementation is split into small Draft PRs (§12). No existing public
IPC command, SDK type, capability or error envelope changes as part of this
work; any such change is its own reviewable step.

## 1. Goals and non-goals

Goals:

- One place in a Tauri application where shared data, caches and background
  work live, used by every window.
- Typed operations registered in Rust. The WebView sees only the commands the
  adapter exposes, never the runtime itself.
- Bounded memory and work: cache budget, concurrency limit, deadlines,
  request size limits, clean shutdown.
- Large data stays in Rust. Windows receive pages, aggregates or summaries.

Non-goals: a generic channel for copying large objects between windows,
cross-application sharing (that is the conditional broker), network access,
authentication of users, a plugin platform.

## 1a. Short contract

What an application developer can rely on once this is agreed:

1. **One runtime per application.** Built once in Rust at startup, shared by
   every window. Windows never construct it and cannot reach it except
   through the commands the adapter generates.
2. **Operations are typed and registered in Rust.** Name, parameters, output,
   cache policy, scope and weight are fixed by the developer. Nothing a
   window sends can change the policy, scope or visibility of a call.
3. **Same key, same work.** Concurrent calls with the same
   `(operation, scope, params)` share one execution; a stored result serves
   later calls until TTL, invalidation, clear or eviction. Errors are never
   cached or handed to calls that start after the error was published.
4. **Large outputs stay in Rust.** Windows read them through views with
   enforced size limits; there is no command that copies a whole output to a
   window unless a view explicitly returns it within its limit.
5. **Bounded.** Cache weight, concurrent executions, parameter size, view
   size and per-call deadline are limited; a call that hits a limit fails
   with a stable error code instead of waiting forever or growing memory.
6. **Clean stop.** On application exit the runtime stops accepting calls,
   waits a bounded time for in-flight work and drops its caches.
7. **Safe diagnostics.** Stats contain counts and sizes only, never keys,
   parameters, values or window identities.
8. **Errors** keep the current `{ code, message }` shape.

## 1b. Examples

Registering an operation and a view (Rust, application side):

```rust
struct Catalog;                       // loads and decodes a large data set once

impl Operation for Catalog {
    const NAME: &'static str = "catalog.load";
    type Params = CatalogId;          // validated newtype
    type Output = CatalogIndex;       // stays in Rust
    type Error = CatalogError;

    fn policy(&self) -> CachePolicy { CachePolicy::Ttl(Duration::from_secs(300)) }
    fn weight(&self, out: &CatalogIndex) -> usize { out.retained_bytes() }
    async fn run(&self, ctx: OpContext, id: CatalogId) -> Result<CatalogIndex, CatalogError> {
        load_and_index(&ctx, id).await
    }
}

struct CatalogPage;                   // what a window actually renders

impl View<Catalog> for CatalogPage {
    const NAME: &'static str = "catalog.page";
    type Request = PageRequest;       // { catalogId, offset, limit, sort }
    type Response = Page<Row>;        // ≤ max_items rows, ≤ max_response_bytes + total
    fn max_items(&self) -> usize { 200 }
    fn max_response_bytes(&self) -> usize { 256 << 10 }
    fn project(&self, idx: &CatalogIndex, req: PageRequest, budget: &mut ResponseBudget)
        -> Result<Page<Row>, ViewError> {
        idx.page(req.offset, req.limit, req.sort, budget) // charges each row before copying it
    }
}

fn main() {
    let runtime = Runtime::builder(RuntimeConfig {
            cache_budget_bytes: 256 << 20,
            max_concurrent_operations: 4,
            default_deadline: Duration::from_secs(10),
            max_params_bytes: 16 << 10,
            shutdown_grace: Duration::from_secs(2),
        })
        .register(Catalog).unwrap()
        .build();

    tauri::Builder::default()
        .plugin(tauri_runtime_adapter::init(runtime, adapter_commands![CatalogPage]))
        .run(tauri::generate_context!())
        .unwrap();
}
```

Calling it from a window (TypeScript, through the SDK; the window never
holds the whole catalog):

```ts
const page = await runtime.views.get("catalog.page", { catalogId: "main", offset: 0, limit: 100, sort: "name" });
render(page.rows, page.total);
```

Two windows asking for page 1 at the same time trigger one `catalog.load`
(if not cached) and two cheap `project` calls; each window receives only its
100 rows.

## 2. Building blocks that already exist

`runtime-core` (#3, #8, #12, #14) already provides `PolicyCache`,
`TaskCoalescer` and `CachedService` with these verified semantics: the
completion point is the publication of the result; errors are never cached
or shared with later callers; `invalidate` is per key and `clear` is
service-wide, both without cancelling in-flight work and without letting it
repopulate the cache; a cancelled initializer is re-run by a remaining
waiter. The proposal keeps these semantics and wraps them; it does not
rewrite them.

Gaps found in review (Phase 1, 2026-10-26):

| Gap | Effect | Addressed by |
|---|---|---|
| Cache has no size or entry limit; expired entries are removed only on lookup or `len` | Memory grows with distinct keys | §4 budget and eviction |
| No deadline or concurrency limit | A slow operation holds callers indefinitely; a burst of distinct keys runs all at once | §5 |
| No shutdown | In-flight work is dropped with the process | §5 |
| A cancelled client increments `requestsReceived` but no outcome counter, so `requests = executed + coalesced + hits` stays off by one even at quiescence | Diagnostics mislead | §6 `cancelled` counter (contract change, needs agreement; related to C-1 in #13) |
| Release profile uses `panic = "abort"` | A panic in one operation ends the whole application, every window included | §5 panic policy (decision) |
| Access context is not part of keys (V6) | Per-window or private results must not use a shared key | §3 `Scope` |

## 3. Types

```rust
/// Built once at startup and managed by Tauri as state.
pub struct Runtime { /* registry, services, limits, stats */ }

pub struct RuntimeConfig {
    pub cache_budget_bytes: usize,      // total weight of cached values
    pub max_concurrent_operations: usize,
    pub default_deadline: Duration,
    pub max_params_bytes: usize,        // checked before an operation runs
    pub shutdown_grace: Duration,
}

impl Runtime {
    pub fn builder(config: RuntimeConfig) -> RuntimeBuilder;
    pub fn handle<O: Operation>(&self) -> OperationHandle<O>;
    pub fn stats(&self) -> RuntimeStats;           // §6
    pub async fn shutdown(&self);                  // §5
}

impl RuntimeBuilder {
    pub fn register<O: Operation>(self, op: O) -> Result<Self, RegistryError>; // duplicate NAME is an error
    pub fn build(self) -> Runtime;
}

/// A typed, named operation. Visibility and policy are set by the developer
/// in Rust, never by the caller.
pub trait Operation: Send + Sync + 'static {
    const NAME: &'static str;                      // "projects.metadata"
    type Params: Eq + Hash + Clone + Send + Sync;  // already validated
    type Output: Send + Sync;                      // stays in Rust
    type Error: Send + Sync;

    fn policy(&self) -> CachePolicy;
    fn scope(&self) -> ScopeRule { ScopeRule::Shared }
    /// Approximate retained bytes of one output, used for the cache budget.
    fn weight(&self, output: &Self::Output) -> usize;
    fn run(&self, ctx: OpContext, params: Self::Params)
        -> impl Future<Output = Result<Self::Output, Self::Error>> + Send;
}

pub enum ScopeRule {
    /// One result for every window (public, deterministic data).
    Shared,
    /// Results are keyed by the calling window as identified by Tauri.
    PerWindow,
}

pub struct OperationHandle<O: Operation> { /* … */ }

impl<O: Operation> OperationHandle<O> {
    pub async fn get(&self, caller: Caller, params: O::Params, opts: CallOptions)
        -> Result<Arc<O::Output>, CallError<O::Error>>;
    pub fn invalidate(&self, params: &O::Params);  // all scopes of these params
    pub fn clear(&self);
}

/// Built only by the adapter from what Tauri injects (window label), never
/// from a frontend argument.
pub struct Caller { /* window label, internal */ }

pub struct CallOptions { pub deadline: Option<Duration> }

pub enum CallError<E> {
    Operation(Arc<E>),     // the operation's own error, never cached
    DeadlineExceeded,
    Overloaded,            // concurrency or queue limit
    InvalidArgument,
    ShuttingDown,
}
```

Differences in the implementation (#35), kept deliberately:

- The cache budget has two levels: `RuntimeConfig::cache_budget_bytes`
  bounds the whole runtime, and each operation reserves a share of it
  (`OperationConfig::cache_budget_bytes`, passed to `register`), so one large
  operation cannot evict another's outputs and the total stays checkable.
  `RuntimeConfig` adds `max_queued_operations`.
- `max_params_bytes` and `InvalidArgument` belong to the adapter (R3): params
  are validated before a request reaches the runtime, so `CallError` has no
  `InvalidArgument`.
- `Runtime::operation::<O>()` and `Runtime::view::<O, V>()` return
  `Result<_, RegistryError>` instead of panicking on an unregistered type.
- `get` borrows the `Caller`.

The cache key is `(O::NAME, scope, params)`, where `scope` is `()` for
`Shared` and the window label for `PerWindow`. This closes V6/T-1/T-2 by
construction: a caller cannot choose its scope.

## 4. Large results: views instead of copies

An operation's output (for example a decoded data set or an index) stays in
Rust as `Arc<Output>`. Windows read it through **views** that return only
what they render:

```rust
pub trait View<O: Operation>: Send + Sync + 'static {
    const NAME: &'static str;                      // "projects.list.page"
    type Request: DeserializeOwned;                // e.g. { offset, limit, sort }
    type Response: Serialize;                      // e.g. one page + total
    fn max_items(&self) -> usize;                  // items per response
    fn max_response_bytes(&self) -> usize;         // bytes per response, view's own measure
    fn project(&self, output: &O::Output, req: Self::Request, budget: &mut ResponseBudget)
        -> Result<Self::Response, ViewError>;      // charges each item before building it
    fn items(response: &Self::Response) -> usize;
    fn response_bytes(response: &Self::Response) -> usize;
}
```

**What the response limits guarantee (#35, b65177d).** The view calls
`ResponseBudget::take(bytes)` before it builds each item; `take` fails,
charging nothing, once the item would pass `max_items` or
`max_response_bytes`, and the view stops. For views that do this, as
`View::project` requires, transient response memory is about
`max_concurrent_projections × max_response_bytes` plus each response's fixed
fields. The runtime cannot stop a view from allocating: it checks `items` and
`response_bytes` again after `project`, but that check runs after the
allocation, so a view that builds first and charges later (or not at all) is
refused without its memory being bounded. This is a per-view contract,
checked by tests, not a strict bound enforced by the runtime.

Typical views: a page (`offset`, `limit` ≤ max), an aggregate (count, sum,
histogram), a lookup by id, a summary. The adapter serializes only the view
response.

**Cache budget.** Each cached value carries its declared `weight`. When the
total exceeds `cache_budget_bytes`, least recently used entries are evicted
(TTL still applies). A value larger than the whole budget is returned but not
cached. Eviction never affects in-flight operations or their waiters.

## 5. Work control

- **Concurrency limit**: a semaphore around execution (not around waiting).
  Coalesced waiters do not take a permit. When the queue is full the call
  fails fast with `Overloaded`.
- **Deadlines**: a per-call deadline bounds how long *this caller* waits. The
  shared operation keeps running while any caller still waits (current
  semantics); when the last caller leaves, it is dropped, as today.
- **Cancellation**: dropping the call future is the cancellation signal, as
  today, and is counted as `cancelled`. The execution runs in the task of the
  caller that started it; if that caller leaves before the result is
  published, one remaining caller restarts it (core semantics B3).
  `OpContext::is_shutting_down()` lets long operations stop early between
  steps during shutdown.
- **Shutdown**: `shutdown()` stops new calls (`ShuttingDown`), waits up to
  `shutdown_grace` for in-flight operations, then drops them and clears the
  caches. A view call is in flight from start to return, its `finish`
  (serialization) included; one still waiting for a projection slot after
  the grace returns `ShuttingDown`. A projection or serialization already
  running is synchronous and is waited for, not interrupted, so `shutdown`
  returns only after it ends. The adapter calls it on `RunEvent::Exit` and
  bounds the wait with its own `abort_wait`.
- **Panics (decided: no change in v1)**: the global panic profile stays as it
  is (`panic = "abort"` in release) and v1 promises no panic isolation. An
  operation panic in a release build ends the application. No `catch_unwind`
  is added until a state-recovery strategy is proven. Options for a later
  decision are in §13.

## 6. Diagnostics

`RuntimeStats` contains only aggregate numbers: per operation `requests`,
`cache_hits`, `executed`, `coalesced`, `overloaded`, `deadline_exceeded`,
`shutting_down`, `cancelled`, `failed`, `in_flight`; and `cache_entries`,
`cache_weight_bytes`, `cache_budget_bytes`, `evictions`. No keys, params,
values or window labels, so stats are safe to show in any window.

Every counted request ends in exactly one terminal outcome, so at quiescence
(`in_flight = 0`):

`requests = cache_hits + executed + coalesced + overloaded + deadline_exceeded
+ shutting_down + cancelled`

| Outcome | Caller receives | In `failed`? |
|---|---|---|
| `cache_hits` | cached value | no |
| `executed`, `coalesced` | the operation's value or its own error | only when the operation returned an error |
| `overloaded` | `Overloaded` | yes |
| `deadline_exceeded` | `DeadlineExceeded` | yes |
| `shutting_down` | `ShuttingDown` | yes |
| `cancelled` | nothing (caller dropped the call) | no |

Invalid arguments are rejected by the adapter before a request is counted, as
today. Implemented in #35 (`crates/shared-runtime/src/stats.rs`) and checked
by every test there.

Exposure of stats and of `invalidate`/`clear` to windows is an adapter
setting (default: stats to all windows, admin to `main` only, enforced in Rust
from the Tauri-provided label, as today).

## 7. Tauri adapter

A separate crate (working name `tauri-runtime-adapter`) owns everything
WebView-facing:

- registers the runtime as Tauri state and calls `shutdown` on exit;
- builds `Caller` from the injected `WebviewWindow`; never reads identity,
  scope or visibility from command arguments;
- exposes **one hand-written Tauri command per exposed operation or view**
  (decided: no macro in v1), so Tauri capabilities can allow or deny each one
  per window. A single generic `call(op, params)` command is rejected because
  it would bypass per-command permissions;
- bounds bytes on the IPC boundary, where only it sees them: the raw
  request payload is checked against a per-command `max_request_bytes`
  before it is deserialized, and the serialized response against
  `max_response_bytes` before it is sent to the WebView (the runtime's view
  limits are checked first, on the view's own measure);
- builds and serializes view responses inside `ViewHandle::get_with`, so the
  runtime's `max_concurrent_projections` also bounds the serialized copies;
- calls `Runtime::forget_window` when Tauri reports a window destroyed, so
  that a closed window's `PerWindow` outputs are dropped;
- maps `CallError` to the existing `{ code, message }` error shape with
  stable codes (`INVALID_ARGUMENT`, `DEADLINE_EXCEEDED`, `OVERLOADED`,
  `SHUTTING_DOWN`, `OPERATION_FAILED`, `INTERNAL`, `ACCESS_DENIED`);
- emits invalidation hints only from Rust, without data.

The existing `runtime-ipc` demo and Runtime Lab become one example
application of the adapter; the framework does not depend on them.

## 8. Where memory lives, per decision

| Decision | Rust process | WebView renderer | IPC / serialization |
|---|---|---|---|
| Shared operation output (`Arc<Output>`) | once per application, bounded by the budget | none | none |
| View response | transient while serializing | the page the window keeps | one JSON copy per call in each process, transient |
| `PerWindow` scope | once per window (by design) | as above | as above |
| Coalesced waiters | one `Arc` clone each (pointer) | none | one response per waiter |
| Returning a whole large output to a window (allowed only through a view with a limit) | transient | full copy per window | full copy per call |
| Stats | fixed, small | small object per refresh | small |

The rule that follows: an operation is worth sharing when its retained
output or working memory is large and windows need projections of it. If
every window needs the whole output, sharing saves working memory and
computation only, and the break-even model in the roadmap decides.

## 9. Compatibility with the current code and IPC

Rust library: `CachedService`, `PolicyCache` and `TaskCoalescer` keep their
current public API and semantics; the runtime is a new layer on top.

Current IPC contract (`docs/frontend-backend-contract.md`, #2/#7/#28) and
what happens to each part:

| Current item | Shape today | Under this proposal |
|---|---|---|
| `runtime_get_project_metadata` | `{ projectId }` → `ProjectMetadata` | unchanged name and payload; implemented as operation `projects.metadata` (`Shared`, TTL 30 s) through the adapter |
| `runtime_get_debug_stats` | → `RuntimeDebugStats` (5 counters, `cachedEntries`, `cachePolicy`) | unchanged until the counter decision (C-1). If agreed, new fields are **added** (`cancelledRequests`, `deadlineExceeded`, `overloaded`, `cacheWeightBytes`); no field is removed or renamed |
| `runtime_invalidate_project` | `{ projectId }` → `{ invalidated }`, main window only | unchanged; the main-only check stays in Rust |
| `runtime_clear_cache` | → `()`, main window only | unchanged |
| `runtime://cache-invalidated` | `{ projectId: string \| null }`, emitted from Rust | unchanged; still a hint without data |
| Errors | `{ code, message }`; codes `INVALID_ARGUMENT`, `PROJECT_NOT_FOUND`, `ACCESS_DENIED`, `OPERATION_FAILED`, `INTERNAL` | same shape. New codes (`DEADLINE_EXCEEDED`, `OVERLOADED`, `SHUTTING_DOWN`) can appear only once limits are enabled for a command. The SDK already keeps unknown codes as strings (`contract.ts`), so older frontends do not break, but they show them as generic errors |
| Capabilities | `default` (main, secondary) and `runtime-main` (main) | unchanged; new view commands get their own permission entries, added per window by the application |

Migration is one later PR that moves the demo onto the adapter without
changing any row above; anything that would change a row needs its own
review.

## 10. Decisions (review on #32, 2026-10-26)

| # | Question | Decision | Where it is implemented |
|---|---|---|---|
| 1 | API shape (§3–§7) | Approved in principle. Implemented in small Draft PRs; existing public IPC/SDK are not migrated in one general change. | §12 |
| 2 | Macro vs hand-written commands | v1: one hand-written Tauri command per exposed operation or view. No macros. | R3 |
| 3 | `Shared` / `PerWindow` | Both in model and tests. Scope is computed only in Rust from the Tauri context. A window label separates data; it is not proof of access rights. | #35 (`ScopeRule`, `Caller`) |
| 4 | Counters | Explicit terminal outcomes for cancelled, overloaded, deadline and shutdown, so stats balance (§6). `failed` subsets documented. DTO changes, if any, are additive only. | #35 (Rust); R4 (DTO) |
| 5 | Limits | All configurable. No library defaults. Values for the sample app are example config, marked temporary, validated by memory and load (§12a). | #34, #35 (`RuntimeConfig`, `OperationConfig`) |
| 6 | Panics | Global profile unchanged; no panic isolation promised in v1; no `catch_unwind` without a proven recovery strategy. Options described for a later decision (§13). | nothing to implement |
| 7 | IPC compatibility | Current command names and shapes, capability boundaries and the `{ code, message }` envelope stay. Counter exposure over IPC is a separate reviewable step. | R3 keeps §9; R4 |

The cross-app broker is not part of this work; it stays a separate,
conditional research stage (roadmap §5, experiments/).

## 11. Acceptance criteria for the implementation

- Unit tests for budget eviction (including a value larger than the budget),
  deadline, overload, shutdown during in-flight work, scope separation (same
  params, two windows, `PerWindow` → two executions, no cross-scope hit),
  cancellation and the outcome invariant, view size limit, and that a
  frontend argument cannot change the scope (adapter test, R3). These tests
  must exist and pass before the demo migration (R5).
- Existing Phase 1 tests keep passing unchanged.
- The adapter exposes no runtime internals; a test lists the generated
  commands.
- fmt, clippy `-D warnings`, workspace tests; a native Windows run recorded.

## 12. Implementation plan

Each step is a separate Draft PR, stacked on the previous one, reviewed on
its own. No step changes the current IPC contract (§9) unless the step says
so and is reviewed for exactly that.

| Step | PR | Content | Public contract change | Tests required |
|---|---|---|---|---|
| R1 | #34 | `runtime-core`: optional weight budget with LRU eviction (`CacheBudget`). Existing constructors unchanged. | none (additive Rust API) | eviction order, oversize value, invalidate/clear, in-flight unaffected |
| R2 | #35 | New crate `shared-runtime`: registry, `Shared`/`PerWindow`, execution slots + bounded queue, per-caller deadline, shutdown, bounded views, terminal-outcome stats. No Tauri dependency. | none (new crate) | budget/eviction, scope separation, cancellation, overload, deadline, shutdown, view size limit, registry, invariant |
| R3 | not started (mandatory criteria in `docs/ROADMAP.md`, Phase 3) | Tauri adapter: `Caller` from the injected window, hand-written commands, error mapping to `{ code, message }`, `shutdown` on exit. The existing `runtime_*` commands are reimplemented on it with identical names, payloads and capabilities. | none; new error codes only appear where limits are enabled (§9) | contract tests for every existing command; a frontend argument cannot change scope; capability checks unchanged |
| R4 | not started | Optional: additive fields in `RuntimeDebugStats` (`cancelledRequests`, `deadlineExceeded`, `overloaded`, `shuttingDown`, `cacheWeightBytes`, `cacheBudgetBytes`, `evictions`). | additive DTO fields only; separate review | DTO compatibility test (old fields unchanged) |
| R5 | not started | Sample migration: a realistic Rust-owned catalog operation and page view in the demo, used by the memory benchmark (#33). | new commands for the new view only | as R3, plus view limit end to end |

### 12a. Limits: what is configured where

| Limit | Config field | Library default | Sample app value | How to validate it |
|---|---|---|---|---|
| Cache size, whole runtime | `RuntimeConfig::cache_budget_bytes` | none | temporary, the sum of the operation budgets below plus headroom | Private Bytes of the host process at idle after the #33 load; Σ cache weight in stats stays within it |
| Cache size per operation | `OperationConfig::cache_budget_bytes` (reserved from the runtime total; registration fails if the sum exceeds it) | none | temporary, set from the benchmark data size (e.g. 2× one D64 catalog) | Private Bytes of the app process at idle after N windows load (#33, scenario M); evictions in stats must stay 0 for the intended working set |
| Concurrent executions | `RuntimeConfig::max_concurrent_operations` | none | temporary, e.g. number of logical CPUs | CPU and latency guardrails under the #33 load; peak RAM during cold load |
| Queue length | `RuntimeConfig::max_queued_operations` | none | temporary, e.g. 4× concurrency | `overloaded` must stay 0 at the intended load and rise only under deliberate overload |
| Caller deadline | `RuntimeConfig::default_deadline` / `CallOptions::deadline` | none | temporary, above the p99 cold-load latency measured in #33 | `deadline_exceeded` stays 0 at intended load |
| Shutdown grace | `RuntimeConfig::shutdown_grace` | none | temporary, e.g. 2 s | time from close to process exit on Windows |
| View response size | `View::max_items` and `View::max_response_bytes` | none (per view) | temporary, e.g. 200 rows and 256 KiB per page | serialized response bytes per call (§12b), renderer memory per window; a test with one huge item checks that the byte limit applies when the item count does not; a generated oversized response stops after the items that fit (build counter) |
| Concurrent view projections | `RuntimeConfig::max_concurrent_projections` | none | temporary, e.g. 2 | transient host Private Bytes when N windows request the largest page at once ≈ limit × `max_response_bytes` for views that charge their budget before building; p95 latency guardrail |
| IPC request / response bytes | adapter, per command: `max_request_bytes`, `max_response_bytes` (R3) | none | temporary, e.g. 16 KiB request, 512 KiB response | largest legitimate request and page in the sample, times a margin |
| Closed windows | `Runtime::forget_window`, called by the adapter on window destroy | always on | n/a | PerWindow cache entries and weight return to the pre-open value after a window closes (R3 test) |

"Temporary" means the value is a starting point for the sample application
only; it is replaced by the measured value and is not a recommendation for
other applications.

### 12b. Memory and serialization per step

| Step | Where data lives | What is serialized to a window |
|---|---|---|
| R1 | Cached outputs in the Rust process, at most `cache_budget_bytes` (estimated) per service; eviction drops the cache's `Arc`. | nothing (no IPC change) |
| R2 | One `Arc<Output>` per scope key in Rust (`Shared`: one per app; `PerWindow`: one per window until it closes). Coalesced callers share it. Total cached weight ≤ `RuntimeConfig::cache_budget_bytes`. No per-window bookkeeping besides cached outputs. | nothing (no IPC) |
| R3 | As R2. Existing commands return the same DTOs as today. | same bytes per call as today (`ProjectMetadata`, stats) |
| R4 | As R2. | stats DTO grows by about seven numbers |
| R5 | Catalog output once in Rust, bounded by its budget. | one page per call, at most `max_items` rows; size recorded per run in the benchmark |

## 13. Panic handling: options for a later decision

Not decided for v1 (decision 6). Recorded so that a later decision has the
facts.

| Option | Behaviour | Consequences | Tests a decision would need |
|---|---|---|---|
| A. Keep `panic = "abort"` (current) | Any panic ends the process. | Simple, no inconsistent state; one buggy operation closes every window. | none beyond today |
| B. `panic = "unwind"`, no catching | A panic unwinds the task that runs the execution; the coalescer drops the entry and a remaining caller re-runs it (seen under the test profile). | The same panic can repeat for each waiter; mutex poisoning is tolerated (`into_inner`) but state an operation left half-written is not repaired. Binary size and code generation change. | repeated panic is bounded; no stale cache entry; stats still balance |
| C. `unwind` + `catch_unwind` around `Operation::run`, mapped to an `Internal` error | Callers get an error instead of a crash. | Requires every operation's shared state to be safe after a partial run, which the runtime cannot check. Not adopted without a proven recovery strategy. | per operation: state after an injected panic is consistent; error not cached; waiters released |
