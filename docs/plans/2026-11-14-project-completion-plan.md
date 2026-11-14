# Project completion plan and audit snapshot
Created: 2026-11-14 (Europe/Vienna)

## Outcome and evidence boundary

Deliver a usable Tauri v2 framework that shares Rust application data and work
between windows, then evaluate opt-in sharing between applications. The first
deliverable is an in-process Windows developer preview. Product success also
requires demonstrated RAM savings for explicitly named workloads; functional
tests alone do not establish that result.

This audit inspected the SDK at `3923b0c92c8be912d1a9facacf61ab9ff645546e`,
based on main `7244a5cbccbe37a96ac67c69f374d9de383eb2d5`. It reused existing
exact-revision test/native evidence rather than repeating long runs. Eight
review lenses covered correctness, security, test fidelity, reliability,
resource behavior, API contracts, maintainability and adversarial composition.
Two retained defects were independently validated from source. No new runtime
reproduction was executed during this audit. Production code was not changed.

The framework shares application-owned data and work. Chromium/WebView2 process
deduplication, automatic discovery of arbitrary duplicate application processes,
and automatic identification of safe public data are not implemented features.
Developers choose operations, scope, caller access and bounded views explicitly.

## What has been achieved

| Area | State | Evidence and limit |
|---|---|---|
| Shared Rust data and coalesced execution | Implemented on main | Core cache/coalescer, typed operation registry; real two-WebView demo observes one catalog execution and cache entry |
| Cache retention | Implemented | Estimated-weight budgets, LRU, TTL/NoStore, invalidation; not a total OS RAM bound |
| Bounded views | Implemented | Item/byte budgets, admission held through source lookup, projection and serialization |
| Window scopes and shutdown | Implemented, follow-up required | Shared/PerWindow, destroy/exit hooks, deadlines and cancellation; source-derivation race below remains |
| Adapter and IPC | Implemented | Injected caller identity, typed commands, capabilities, bounded decoding/encoding, sanitized fixed errors |
| Queued close/reopen fix | Review, not on main | [#66](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/66), `f877114`; covers invalidation after source registration |
| Bounded waiting-view queue | Review, not on main | [#67](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/67), `3923b0c`; explicit queue limit, overload and gauges |
| Local final-candidate verification | Passed with a retained consumer cleanup failure | 156 Release unit/integration tests, 4 doctests, Clippy/Rustdoc warnings denied; native checks for repository and consumer locks passed |
| Hosted final-candidate CI | Blocked before execution | [Run 43521641035](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/43521641035), payment/spending-limit annotations; no Windows/Ubuntu steps ran |
| Independent Git consumption | Build/assertions work; cleanup investigation open | First fresh combined job left one process; isolated app and cached repeat exited cleanly; repeat was not a second fresh build |
| Measurement infrastructure | Implemented on separate review branches | Whole-run Job Object CPU, RAM monitoring, frozen inputs, schedules, reports and analysis; completion-accounting follow-ups remain separate |
| Pilot | Completed, descriptive only | [#64](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/64): 72/72 valid runs, 4 h 43 min 54 s, older framework `2dac921` |
| Renderer/text/IPC optimization | Experimental | [#63](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/63), [#65](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/65); no accepted RAM improvement |
| Installation and license | Prepared | MIT OR Apache-2.0, Git consumer script, example and draft notes; preview tag/release not published, crates.io disabled |
| Cross-app sharing | Design and historical spike | [#27](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/27), #29, #59, #61; not a production remote SDK |

## What remains unproven or unsuccessful

- General RAM savings are not established. The pilot's C-minus-A paired median
  RAM differences were +7.1 MiB at N2D0, +74.4 MiB at N2D16, +8.0 MiB at N2D64,
  and -52.0 MiB at N4D64. Only the four-window D64 cell consistently favored C
  in both observed RAM and CPU pair ranges. These are descriptive observations
  on the older frozen framework, not conclusions about the current SDK.
- Bounded DOM reuse controlled node counts but did not establish removal of the
  renderer memory plateau. Daytime comparisons overlapped uncontrolled gaming
  load. JSON transport isolation did not establish a fix either. The text cache
  is off by default and has no accepted native performance result.
- Current measurements cannot be relabeled as tests of a future merged SDK.
  The frozen protocol retains RAM and CPU as co-primary outcomes. A product
  focus on memory does not retrospectively change that statistical contract.
- The first fresh consumer job's remaining process has not been identified.
  Its start preceded the demo; assuming it is a compiler/Git helper is not proof.
- Linux integration and any Windows version not tested at the final chosen SHA
  remain coverage gaps. Earlier Windows 10 checks do not validate later fixes.

## Verified code findings

| ID | Priority | Problem | Required outcome |
|---|---|---|---|
| F1 | P2 | `Runtime::view` indexes only by view TypeId. A type implementing `View<A>` and `View<B>` can be retrieved for B after registration only for A | Preserve and check the registered source operation identity; reject unregistered `(O,V)` pairings |
| F2 | P2 | A view enters the runtime's in-flight lifetime before `View::source`, but captures invalidation identity afterward. Destruction during ordinary thread preemption in that interval can be missed | Capture lifecycle identity before parameter derivation and preserve invalidation through later keyed preparation |

Source anchors: `crates/shared-runtime/src/runtime.rs:341` and
`crates/shared-runtime/src/runtime.rs:768` at the reviewed SHA. F1 predates the
recent follow-ups; F2 leaves the documented in-flight cleanup promise incomplete.
Both were independently validated by source trace, not new executable tests.

## Ordered work to completion

### 0. Open-source publication check

The local publication audit fetched 70 remote branches, 65 PR heads and 52 PR
merge refs. There are 446 reachable commits; Gitleaks 8.30.1 reported scanning
445 commits. A separate scan covered all 989 historical text blobs plus commit
messages, independent of patch enumeration. Its archive and checksum manifest were verified.
Four alerts are the same artificial Node/VM transport-test constant across four
commits, not an external credential. Historical `.env` files contain only
`VITE_RUNTIME_MODE`. Scans of 67 issue/PR bodies, 170 conversation comments and
eight inline comments found no secrets. These are detection results, not a
guarantee that arbitrary private material cannot exist.

All 98 available Actions artifacts were downloaded (317,115,436 bytes; 1,126
members: JSON, CSV and compiled executables). All 242 workflow log archives
were downloaded (662 log members, 39,403,950 uncompressed bytes). Gitleaks found
no secrets in the scanned archive contents or logs. Compiled binaries are not
a source-level guarantee against embedded information. No artifact or log was
deleted or changed on GitHub. Keep the redacted local audit evidence.
Changing visibility is separate from publishing a release. After opening, check
anonymous source access and run the required final-candidate CI once; a billing
lock on the account may still need resolution.

### 1. Finish SDK correctness before accepting a release candidate

1. Fix F1 with the smallest registry identity change. Preserve the intended
   duplicate-view rule and existing public error envelopes.
2. Add a regression: one type implements two source-specific View traits; both
   operations exist but only one pairing is registered. Wrong-pair lookup fails.
3. Fix F2 without retaining historical window labels or holding application code
   under a reentrant internal lock. A bounded active lifecycle token is one
   possible approach, subject to implementation review.
4. Add a deterministic concurrent test: pause parameter derivation, destroy the
   caller, reopen its label and fill the new cache, then resume the old call.
   The old call cannot read or populate the new generation. Check ordinary
   operation registration for the analogous interval too.
5. Retain cancellation, clear, per-window separation, queue saturation and
   post-wakeup permit cancellation coverage. Add the adapter timeout-expiry case
   identified by review: blocked serialization exceeds grace + abort_wait,
   shutdown returns false, later calls are refused, then retry cleanup succeeds.

Done: focused regressions fail before the relevant fix and pass afterward;
no leak of lifecycle metadata/permits, unintended error-contract change or
unsupported compatibility promise is introduced.

### 2. Consolidate and verify one candidate

Review #66, #67 and the new fixes in dependency order. Test the actual resulting
candidate/merge SHA, not an earlier branch head. Record versions, lockfiles,
build profile, hashes and every failed attempt.

- Workspace formatting, Release tests and Clippy; Rustdoc warnings denied.
- Native queue/close/reopen/exit checks with fresh profiles and owned jobs.
- One fresh independent Git consumer with dependency/source identity checked.
- Instrument process name, creation time and parent PID inside the consumer's
  own job to classify the earlier leftover. Do not increase grace or discard
  failure solely because a cached repeat passes.
- Successful hosted Windows and Linux/Xvfb CI at the chosen candidate. Resolve
  billing/public-runner access once, rather than repeatedly dispatching blocked jobs.
- State the supported Windows versions and tested Rust/WebView2 combinations.
  Verify every claimed platform; do not silently broaden support or promise MSRV.

### 3. Finish the Git developer preview

Keep version `0.1.0-preview.1` and the selected license unless a deliberate
version decision changes them. Review the quick start, config migration, known
limits and draft notes. After separate merge/publication decisions, verify the
remote tag's peeled commit, tag CI and anonymous tag-based consumer installation.
Describe proven functionality without presenting the pilot as general savings.
crates.io publication is a separate optional distribution track.

### 4. Consolidate measurement work without rewriting history

Review #58 against #60 and the protocol update #62; select one coherent accounting
implementation and report path. Do not merge overlapping implementations blindly.
Preserve #64, its 72 runs, failed exploratory attempts and original freeze bytes.
Resolve the pilot's host-retention deviation from nominal data weights before
choosing a confirmatory matrix. Keep A/B/C workload, UI and cadence comparable;
C-A is the product comparison and C-B is framework cost.

### 5. Establish useful memory savings

On an idle, recorded machine, evaluate the prewritten bounded-text-cache
experiment only after its configuration and stopping rules are reviewed. Verify
unchanged displayed data, scheduled steps and checksums. Keep an optimization
only if measured whole-tree RAM improves without unacceptable CPU, latency or
error regression. Do not use forced GC, disabled rendering or a changed primary
measurement window to manufacture a win. If text reuse does not help, use
symbolicated allocation evidence to choose the next change.

After diagnostic review, freeze the selected SDK and statistical protocol anew.
Smoke, pilot and confirmatory executions each retain their separate approval
and provenance. State the workload/window-count range that supports a claim;
report unfavorable cells and overhead as well as favorable results.

Done: an approved report supports the intended claim on the released code,
with reproducible inputs, guardrails, uncertainty and supported scenarios.

### 6. Bring cross-app sharing to a bounded prototype

After the in-process preview, settle #59/#61 design questions and build only the
limited experimental prototype. Include per-user/session identity, peer/server
verification, immutable public/app resources, bounded broker-side views,
per-app quotas, cancellation/deadline propagation, disconnect cleanup, mandatory
local fallback and a bounded circuit breaker. Keep user-private data excluded.

Run the threat-specific tests, including second-user/session checks when their
required system setup is separately authorized. First target one vendor with a
common registered broker installation; cross-vendor interoperability is not yet
solved. Measure the cost against local operation before making it production.

Done: security/recovery tests pass and a reviewed measurement supports break-even.
Then decide whether to productize a separate remote crate. The old spike alone
does not satisfy this gate.

### 7. Maintain one current project record

Map older open PRs to implemented, superseded, historical or still-required work
by content, not by open/closed status alone. Main already contains the selected
SDK integration; blindly merging old stacked branches could restore unrelated
Lab/benchmark content. Keep experimental tracks and release lineage clear.
Refresh status after accepted results; avoid duplicate tasks and repeated tests
without a source change, failure or unresolved concern.

## Completion definitions

- **Working developer preview:** SDK defects fixed, the final candidate verified,
  installation usable, scope/support explicit, and release/tag gates completed.
- **Validated memory product:** reviewed comparative evidence supports the stated
  savings range on released code; convenience and functional sharing alone do not
  satisfy this definition.
- **Cross-app product:** separate identity, recovery, resource and break-even
  gates passed. This is not required to ship the first in-process preview.

## Evidence references

- SDK follow-ups and exact-SHA evidence: #66 and #67.
- Existing local QA archive: `target/final-3923b0c-eb96cebf.tar.gz`, SHA-256
  `00c60c630329ebe65977b60c2a23b2227053aa84fb503eba968ea421664675c0`.
- Review artifacts: `target/project-audit-20261114/`.
- Publication scan and discussion snapshots: `target/publication-audit-20261114/`.
- Descriptive pilot report: #64; diagnostic candidates: #63 and #65.
- This plan is a local project artifact; it does not authorize merge, release,
  account changes or new statistical runs.
