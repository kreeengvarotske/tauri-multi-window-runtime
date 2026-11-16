# Runtime identity follow-up

The whole-project review found two defects beyond the queued-view fixes in
#66/#67. Both were reproduced by regressions before changing the implementation.

## Registered source identity

View storage previously retained only `TypeId<V>`. If V implemented both
`View<A>` and `View<B>`, registering A/V allowed lookup of B/V when B existed.
`RegisteredView` now retains the selected source TypeId, and lookup refuses
the unregistered pairing. The existing duplicate-view-type rule and public
error variants remain unchanged. The new regression failed before the fix;
the runtime suite then passed 41 tests.

## Identity before parameter preparation

A view or direct operation call was counted in flight before its parameter
derivation/cloning, but the core did not yet know its key. Window destruction,
clear or invalidation in that interval could be missed. The old call could
then read or populate a newer cache generation. Five deterministic concurrent
regressions reproduced this, including direct parameter cloning and shared
source preparation; they do not rely on sleeps to guess the interleaving.

A private preparation registry now captures scope identity before the runtime
counts the call in flight. Its lock contains only framework-owned scope and
epoch metadata; source callbacks and parameter Clone/Hash code run outside it.
Once parameters are known, identity transfers to the existing keyed core
registration. Invalidation after that point uses the existing core generations.

An already-invalidated preparation uses an isolated discarded scope and an
invalidated core registration. It may return its own result but cannot read,
join or overwrite a current scope's cached work. These newly protected stale
preparations may execute separately. They never retain an output in cache.
No core public API or IPC error code changes.

The registry removes a scope when its last pending preparation leaves. It
keeps no history of window labels. Tests cover old/reopened/other scope
isolation, invalidation and reclamation of 1,000 completed window labels.
Queued views still retain no source output, and existing admission/deadline/
shutdown behavior applies. Deadline accounting includes preparation setup;
synchronous application code remains cooperative.

Key-specific invalidation conservatively marks still-unkeyed preparations of
that operation, since their parameter identity is not known yet. It does not
invalidate unrelated keys already registered with the core. This deliberately
favors correctness over a cache hit during the short preparation interval;
it is not a measured RAM/CPU optimization.

Exact final-candidate Release, native, independent-consumer and hosted-CI
evidence belongs in the follow-up PR. Earlier results and the frozen pilot
are not relabeled as verification of this source revision.
