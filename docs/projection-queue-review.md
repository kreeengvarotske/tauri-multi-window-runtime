# Bounded view admission

## Behavior

Projection concurrency bounds source outputs and responses held by admitted
views. It did not bound how many other views could wait. A burst could retain
arbitrarily many requests and invalidation registrations until deadlines or
cancellation. A regression against the implementation before this change
confirmed that an excess view stayed pending instead of returning overload.

`RuntimeConfig::max_queued_projections` is now an explicit runtime-wide count
limit, independent of operation execution queues. A view reserves an available
projection slot or one queue position before deriving its source parameters.
When both are full, it returns `ViewCallError::Source(CallError::Overloaded)`.
The adapter maps this to its existing fixed `OVERLOADED` envelope. No command,
capability or error code is added.

A queued view still registers invalidation identity before awaiting admission,
as required by the queued-window lifecycle fix. It retains no source output.
Cancellation, deadline expiry and shutdown release the queue position through
the same guard; successful admission releases it before fetching the source.
Semaphore admission preserves the order of already waiting callers.

## Configure and handle overload

This is a source configuration change before the first preview release:
add `max_queued_projections` to each `RuntimeConfig` literal. There is no hidden
default. Zero permits immediate admission but refuses any call that would wait.
For example, the demo chooses four active projections and 32 waiting calls:

```rust
use shared_runtime::RuntimeConfig;
use std::time::Duration;
let config = RuntimeConfig {
    max_concurrent_operations: 4,
    max_queued_operations: 64,
    max_concurrent_projections: 4,
    max_queued_projections: 32,
    default_deadline: Duration::from_secs(10),
    shutdown_grace: Duration::from_secs(2),
    cache_budget_bytes: 16 << 20,
};
```

These numbers are demo choices. Select limits for the actual workload. On
`OVERLOADED`, keep or cancel the current UI request and retry only while it
remains relevant, using bounded backoff. Avoid immediately retrying every
refused call or launching multiple copies of the same pending UI request.

`Runtime::stats()` exposes `active_projections`, `queued_projections` and the
cumulative `projection_overloads`. A full-queue refusal happens before source
lookup, so it is not an operation request or operation overload. Gauges are
separate observations; an assigned semaphore permit may be counted active
before the queued future resumes and releases its queue position. Do not sum
these gauges as an atomic count of callers. Counters contain no parameters,
window labels or values.

## Scope

This bounds waiting calls, not their byte size, and does not bound the incoming
Tauri transport or futures an application creates without polling. Keep adapter
request limits, per-view response budgets, cache budgets and UI cancellation.
An admitted source or synchronous projection may still take too long if the
application does unbounded work. The change does not deduplicate Chromium
processes and does not establish a RAM/CPU performance effect. The frozen
benchmark packet, binaries and pilot results are unchanged.

## Validation

The initial full-queue regression failed before the admission change: the extra
future was pending when it should have returned overload immediately. Runtime
coverage checks overload before source derivation, queue capacity reuse after
cancellation/deadline, zero-queue behavior, shutdown cleanup and 64 contending
windows with only three queue positions. Existing close/reopen, clear, response
budget and operation-counter tests remain applicable.

An adapter regression checks the exact error envelope while serialization holds
the only projection slot. The native demo self-test fills the queue on the real
application, verifies overload and cancellation without fetching sources, then
runs the existing real-window close/reopen check. Both new queue report flags
are required by CI and the clean Git-consumer script. Exact-SHA verification
results are recorded in the PR; local checks do not replace hosted CI.
