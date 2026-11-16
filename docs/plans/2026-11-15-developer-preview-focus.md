# Developer preview completion scope
Date: 2026-11-15. Supersedes the first-release priorities in the November 14
completion plan; historical findings and measurement evidence stay unchanged.

## Product decision

Ship a practical Tauri v2 development framework for application-owned shared
data, cached/coalesced operations, bounded views, queues and window lifecycle.
Developer convenience is the first-release outcome. Measured whole-app RAM/CPU
savings are optional follow-up research, not release prerequisites. Existing
cache/response budgets and concurrency bounds remain supported functionality.

No whole-process-memory cap, automatic safe-data detection or Chromium-process
deduplication is promised. The frozen pilot remains descriptive historical
evidence on its recorded framework SHA. Do not revise its protocol or findings.

## Finite release path

1. Review SDK fixes #66/#67/#68/#70 and fix confirmed release-blocking defects.
   Avoid further unbounded audit rounds without new evidence.
2. Verify one fresh external consumer at the selected SDK revision: anonymous
   source access, independent project/target/profile, matching lock identity,
   native assertions and complete owned-job cleanup/accounting. Preserve the
   historical unknown-process failure without guessing its identity.
3. Provide a small optional JS/TypeScript client for the existing JSON-byte
   command protocol. Inject Tauri invoke; retain command-specific capabilities
   and Rust validation. Support typed requests/responses and stable framework
   errors without retries, frontend caching or cancellation claims.
4. Finish installation instructions and three runnable recipes: shared source,
   per-window state/cleanup and coalesced IO with bounded admission. Retain
   explicit resource limits; no unmeasured universal presets or new macros.
5. Assemble a release packet at one final SHA: CI, native/consumer evidence,
   license/version/support matrix, quick start and honest release notes.
6. Merge, tag and publish only after the separate release decisions. Git-based
   distribution is sufficient for this preview; registry publication is optional.

Deferred: Blink/CSS/GC optimization, new performance pilots, cross-app production
broker, mobile/macOS support claims, Rust-to-TypeScript code generation, UI
framework bindings and plugin/ORM expansion. Confirmed correctness regressions
remain actionable even when memory research is deferred.

## Ownership and verification

The active implementation owns `packages/runtime-client`, its CI and this scope
document. The second group owns independent SDK review, fresh consumer evidence,
recipes and the release packet. Coordinate shared docs before editing them.
The large Russian work package is #70 comment 6893982670.

Frontend-client acceptance: JSON-object requests compatible with custom IPC and
postMessage fallback; ArrayBuffer and byte
view/array responses; stable errors with original cause; unchanged transport/ACL
errors; refusal of malformed bytes/JSON and unrepresentable requests; required
and void request typing; clean package installation and browser-safe imports.
Use Node's built-in test runner, strict TypeScript consumer fixtures and a packed
package check. Rust sources remain unchanged by this client work.

Preview acceptance: installation and the three recipes are reproducible; all
required checks pass; no known unresolved P1/P2 defect remains; one reviewable
release packet is ready. No new features are required merely to keep working.
