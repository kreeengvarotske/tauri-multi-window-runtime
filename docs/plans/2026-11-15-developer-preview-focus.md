# Developer preview completion scope
Date: 2026-11-15; ownership and release-status update 2026-11-16. Supersedes the
first-release priorities in the November 14 completion plan; historical
findings and measurement evidence stay unchanged.

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

1. The dependent SDK/client stack #66 → #67 → #68 → #70 → #72 → #73 → #74 → #75
   has a qualified candidate. Candidate `3e132fa` is superseded
   by the confirmed P2 in `NoStore` and overweight-result key `Drop` under
   generation state. Runtime-core fix `0267a775679f4f554151ca4997520d55dfb74082`
   is recorded in [#74](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/74)
   and qualified in `e0c09b0db5788a83bc89881b0df3682f36dac1fa` (#75).
   Integration and the final release identity remain pending execution.
   Avoid further unbounded audit rounds without new evidence.
2. The fresh external consumer at `e0c09b0` verifies anonymous
   source access, independent project/target/profile, matching lock identity,
   native assertions and strict application Job cleanup/accounting. Preserve the
   historical unknown-process failure without guessing its identity.
   The consumer includes the key-drop fix. Build success, build-environment
   cleanup and strict application cleanup are recorded separately. On November
   16, under the user's delegation of remaining decisions/actions, the release
   owner adopted the measured MSVC VCTIP build-only cleanup exception. This
   explicitly changes the original combined-cleanup acceptance requirement.
   Both raw combined observations remain FAIL; the same-artifact application
   Job passes without leftovers or forced cleanup.
3. The small optional JS/TypeScript client supports the existing JSON-byte
   command protocol. The application injects Tauri invoke; command-specific
   capabilities and Rust validation remain required. Typed requests/responses and stable
   framework errors add no retries, frontend caching or cancellation claims.
4. Installation instructions and three runnable recipes are verified: shared source,
   per-window state/cleanup and coalesced IO with bounded admission. Retain
   explicit resource limits; no unmeasured universal presets or new macros.
5. The release packet records the qualified candidate: CI, native/consumer evidence,
   license/version/support matrix, quick start and honest release notes.
   Use [the current packet](../windows-preview-release-packet.md); results from
   the superseded candidate remain historical rather than final qualification.
   The integrated/tagged identity and release receipts remain pending.
6. Execute the delegated dependency-ordered merge, preview tag and GitHub
   prerelease actions. They are authorized; completion is pending execution.
   Git-based distribution from the public repository is sufficient; registry publication
   is outside this preview. Merge dependencies in order. After each parent
   lands, retarget the next child to `main` before merging it and recheck its
   expected head, remaining diff and actual required CI. Include the separate
   key-drop fix and the recipe/release-doc changes before choosing the final SHA.
   After final-main CI passes, create the immutable annotated preview tag at
   that exact SHA. One fresh anonymous `-Tag` consumer with a matching resolved
   SHA qualifies both main source and the remote tag; no second consumer build
   is required. Publish the prerelease after tag CI, that consumer and strict
   same-artifact application cleanup pass.

Deferred: Blink/CSS/GC optimization, new performance pilots, cross-app production
broker, mobile/macOS support claims, Rust-to-TypeScript code generation, UI
framework bindings and plugin/ORM expansion. Confirmed correctness regressions
remain actionable even when memory research is deferred.

## Ownership and verification

The original split gave the active implementation `packages/runtime-client`,
its CI and this scope document, and gave the second group independent SDK
review, fresh consumer evidence, recipes and the release packet. On November 16
the active session took over the remaining work while the second group is
unavailable for the next four days. Work proceeds without waiting for its return.
The active session coordinates runtime fixes, recipe/CI work and release-doc
ownership so concurrent edits do not overlap.
The large Russian work package is #70 comment 6893982670.

Observed checks at the qualified candidate: both key-drop regressions failed
before the fix; 82 core tests and one doctest passed after it. Debug and Release
each passed 171 workspace unit/integration tests and four doctests. Both Clippy
profiles, formatting and Rustdoc with warnings denied passed. All 12 JS tests,
strict TypeScript, demo-sync, offline packed installation/import/call and all
three recipes passed. Exact-head Windows/Ubuntu CI and the fresh consumer
including #74 passed under the adopted policy. The combined consumer remains
FAIL with 553 NEW / 552 EXIT and one compiler helper forcibly cleaned; its
unchanged app/lock passed a new strict Job with 9 NEW / 9 EXIT / active-zero 1
and no leftovers or forced cleanup. The [#75 evidence receipt](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/75#issuecomment-6931159120)
records exact source and checks. Final integrated/tagged identities and their
required CI/release receipts remain pending execution.

Frontend-client acceptance: JSON-object requests compatible with custom IPC and
postMessage fallback; ArrayBuffer and byte
view/array responses; stable errors with original cause; unchanged transport/ACL
errors; refusal of malformed bytes/JSON and unrepresentable requests; required
and void request typing; clean package installation and browser-safe imports.
Use Node's built-in test runner, strict TypeScript consumer fixtures and a packed
package check. Rust sources remain unchanged by this client work.

Preview acceptance: installation and the three recipes are reproducible; the
candidate's required checks pass under the adopted build/runtime policy; no
known unresolved P1/P2 remains in its review; one reviewable release packet is
ready. The key-drop defect is fixed and qualified. Integration, tag verification
and prerelease publication remain distinct authorized actions, pending their
completion receipts. No new features or further RAM research are required.
