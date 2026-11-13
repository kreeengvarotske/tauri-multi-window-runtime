# Queued view invalidation: preview fix review

## Problem

On main `7244a5cbccbe37a96ac67c69f374d9de383eb2d5`, a view waiting
for projection admission has not yet registered a source service call.
`forget_window` therefore cannot invalidate that queued source. After the
window closes and a slot becomes available, the old view can load and cache
data for the closed window. The same gap affects `clear` and can let an old
queued view consume a reopened window's cache under the reused label.

The new `forgotten_window_queued_view_cannot_repopulate_its_cache` test was
first run against the unchanged main implementation. It failed with two
cache entries instead of one. The test polls the queued future explicitly;
it uses no wall-clock sleep to guess whether admission has happened.

## Change

`CachedService::prepare_call` captures the existing invalidation generations
without looking up or holding an output. Its single-use `PreparedServiceCall`
keeps key registration alive until it is run or dropped. A current prepared
call can still read a current cache entry or coalesce with ordinary calls.
An invalidated one cannot read a newer cached entry, join a newer generation,
or insert its own result into the cache. It may finish and return its own
result to its original caller, preserving existing invalidation semantics.

Views derive source parameters and prepare this registration before waiting
for their projection slot. Cache lookup and operation execution still occur
after admission. Ordinary operation calls retain their original registration
and cache lookup path. Both paths share the existing execution/publication
logic; no new error variant or IPC error code is introduced.

| Scenario | Required behavior |
|---|---|
| Close a window with a queued view | Old call may finish; closed window's output is not cached |
| Reopen a window under the same label | Old call cannot consume or replace the new generation's cache |
| Clear while a shared view waits | Old output cannot repopulate the cleared cache |
| Cancel before or after admission | Registration and coalescer state are released |
| Wait behind a slot with a cached source | Registration retains no source output |
| Admit without invalidation | Normal cache hit and coalescing behavior remain available |

## Limits and compatibility

`View::source` now runs before admission and must be cheap parameter
derivation. It must not load data or perform expensive work. Its time is
subtracted before starting the projection wait. Like other synchronous
application code, it cannot be preempted by an async timeout.

Queued registrations retain keys/parameters and generation metadata, not
operation outputs or response buffers. Metadata entries disappear when the
last associated call is dropped. This does not impose a new bound on the
number or size of incoming requests and does not claim an OS RAM limit.
Existing adapter input limits and response/projection bounds still apply.

The core API addition is additive. Custom implementations of `View::source`
must be reviewed for their earlier execution point. This change is not yet
a tagged release and does not modify the frozen benchmark or its framework
pin. It is a cache/lifecycle correctness fix, not a measurement of RAM/CPU
savings.

## Verification and remaining checks

On the collection Windows machine, the normal debug suites passed:

- `runtime-core`: 75 unit tests, including five prepared-call regressions.
- `shared-runtime`: 35 integration tests, including queued window close,
  same-label reopen and clear regressions.
- Clippy with `--all-targets -- -D warnings` for both crates passed.
- Workspace formatting passed. No Tauri application or WebView was launched.

Commands (offline, locked; the skip filter matched no tests in this run):

```text
cargo test --offline --locked -p runtime-core -p shared-runtime -- --skip stress
cargo clippy --offline --locked -p runtime-core -p shared-runtime --all-targets -- -D warnings
cargo fmt --all --check
```

The combined test log is retained locally under this checkout's
`target/lifecycle-tests.log`. These unit checks establish behavior and state
cleanup, not comparative performance. A current full Windows Release build,
adapter/demo tests, external-consumer check and native close/reopen smoke
remain to be run on an idle machine. The operator is using the laptop for
gaming, so no such run was started. Hosted CI also needs a successful run;
earlier unrelated diagnostic jobs reported an account payment/spending-limit
problem, and local checks do not replace CI.
