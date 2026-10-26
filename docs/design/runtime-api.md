# Proposal: stable Rust API for the in-process runtime

Status: **proposal for review** (roadmap Phase 3, see `docs/ROADMAP.md` in
#30). Nothing here is implemented yet. No existing public type, IPC command,
SDK type or capability changes until this proposal is agreed.

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
    type Response = Page<Row>;        // ≤ max_response_items rows + total
    fn max_response_items(&self) -> usize { 200 }
    fn project(&self, idx: &CatalogIndex, req: PageRequest) -> Result<Page<Row>, ViewError> {
        idx.page(req.offset, req.limit, req.sort)
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
    fn max_response_items(&self) -> usize;         // enforced by the adapter
    fn project(&self, output: &O::Output, req: Self::Request)
        -> Result<Self::Response, ViewError>;
}
```

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
  today. `OpContext` exposes `is_cancelled()` for long operations that want to
  stop early between steps.
- **Shutdown**: `shutdown()` stops new calls (`ShuttingDown`), waits up to
  `shutdown_grace` for in-flight operations, then drops them and clears the
  caches. The adapter calls it on `RunEvent::Exit`.
- **Panic policy (decision)**: either keep `panic = "abort"` and document that
  an operation panic ends the app, or switch to `unwind` and turn an operation
  panic into `CallError::Operation`-like `Internal` for its callers with the
  operation's waiters released. The second is recommended for a framework;
  verified today only under the test profile (a waiter re-runs after the
  initializer panics).

## 6. Diagnostics

`RuntimeStats` contains only aggregate numbers: per operation `requests`,
`executed`, `coalesced`, `cache_hits`, `failed`, `cancelled`,
`deadline_exceeded`, `overloaded`, `in_flight`; and `cache_entries`,
`cache_weight_bytes`, `cache_budget_bytes`, `evictions`. No keys, params,
values or window labels, so stats are safe to show in any window. Every
counted request ends in exactly one outcome, so at quiescence
`requests = executed + coalesced + cache_hits + cancelled + deadline_exceeded
+ overloaded`; `failed` is a subset of `executed + coalesced`. Invalid
arguments are rejected before a request is counted, as today.

Exposure of stats and of `invalidate`/`clear` to windows is an adapter
setting (default: stats to all windows, admin to `main` only, enforced in Rust
from the Tauri-provided label, as today).

## 7. Tauri adapter

A separate crate (working name `tauri-runtime-adapter`) owns everything
WebView-facing:

- registers the runtime as Tauri state and calls `shutdown` on exit;
- builds `Caller` from the injected `WebviewWindow`; never reads identity,
  scope or visibility from command arguments;
- exposes **one command per registered view and operation** (generated by a
  macro), so Tauri capabilities can allow or deny each one per window. A
  single generic `call(op, params)` command is rejected because it would
  bypass per-command permissions;
- validates request size (`max_params_bytes`) and view limits before work
  starts;
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

## 10. Decisions needed

1. Accept the shape in §3–§7 (or amend it) before implementation starts.
2. `cancelled` and `rejected` counters in stats (changes the invariant; C-1).
3. Panic policy (§5).
4. Per-command generation by macro vs a hand-written command per operation.
5. Default limits for the sample application (budget, concurrency, deadline).
6. Whether `PerWindow` is needed in the first version or only `Shared`.

## 11. Acceptance criteria for the implementation

- Unit tests for budget eviction (including a value larger than the budget),
  deadline, overload, shutdown during in-flight work, scope separation (same
  params, two windows, `PerWindow` → two executions, no cross-scope hit), and
  that a frontend argument cannot change the scope.
- Existing Phase 1 tests keep passing unchanged.
- The adapter exposes no runtime internals; a test lists the generated
  commands.
- fmt, clippy `-D warnings`, workspace tests; a native Windows run recorded.
