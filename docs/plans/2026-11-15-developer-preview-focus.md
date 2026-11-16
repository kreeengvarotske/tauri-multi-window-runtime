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

1. Review the dependent SDK/client stack #66 → #67 → #68 → #70 → #72 → #73 → #74 and
   fix confirmed release-blocking defects. Candidate `3e132fa` is superseded
   by the confirmed P2 in `NoStore` and overweight-result key `Drop` under
   generation state. Runtime-core fix `0267a775679f4f554151ca4997520d55dfb74082`
   is open as [#74](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/74);
   integration and the final release SHA remain pending.
   Avoid further unbounded audit rounds without new evidence.
2. Verify one fresh external consumer at the selected SDK revision: anonymous
   source access, independent project/target/profile, matching lock identity,
   native assertions and complete owned-job cleanup/accounting. Preserve the
   historical unknown-process failure without guessing its identity.
   The final consumer must include the new key-drop fix. Record build success,
   build-environment cleanup and strict application cleanup separately. The
   November 16 combined gate remains failed even though the same binary passes
   an application-only Job; acceptance of the reproduced MSVC VCTIP exception
   requires an explicit release-policy decision. This proposed separation does
   not waive the original complete-cleanup requirement.
3. Provide a small optional JS/TypeScript client for the existing JSON-byte
   command protocol. Inject Tauri invoke; retain command-specific capabilities
   and Rust validation. Support typed requests/responses and stable framework
   errors without retries, frontend caching or cancellation claims.
4. Finish installation instructions and three runnable recipes: shared source,
   per-window state/cleanup and coalesced IO with bounded admission. Retain
   explicit resource limits; no unmeasured universal presets or new macros.
5. Assemble a release packet at one final SHA: CI, native/consumer evidence,
   license/version/support matrix, quick start and honest release notes.
   Use [the current packet](../windows-preview-release-packet.md); results from
   the superseded candidate remain historical rather than final qualification.
6. Merge, tag and publish only after the separate release decisions. Git-based
   distribution from the public repository is sufficient; registry publication
   is outside this preview. Merge dependencies in order. After each parent
   lands, retarget the next child to `main` before merging it and recheck its
   expected head, remaining diff and actual required CI. Include the separate
   key-drop fix and the recipe/release-doc changes before choosing the final SHA.

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

Observed local checks: both key-drop regressions failed before the fix; 82 core
tests and one doctest passed after it. The default-profile (Debug) workspace
passed 171 unit/integration tests and four doctests. All 12 JS tests, strict
TypeScript checking and the demo-sync check passed. Final Release checks,
required CI and the fresh consumer including #74 remain pending. Record the
recipe/release-document branch through its reviewed PR head and PR evidence
receipt; do not put that commit's own SHA into its tracked packet.

Frontend-client acceptance: JSON-object requests compatible with custom IPC and
postMessage fallback; ArrayBuffer and byte
view/array responses; stable errors with original cause; unchanged transport/ACL
errors; refusal of malformed bytes/JSON and unrepresentable requests; required
and void request typing; clean package installation and browser-safe imports.
Use Node's built-in test runner, strict TypeScript consumer fixtures and a packed
package check. Rust sources remain unchanged by this client work.

Preview acceptance: installation and the three recipes are reproducible; all
required checks pass; no known unresolved P1/P2 defect remains; one reviewable
release packet is ready. The compiler-helper exception decision must be
recorded before declaring these checks satisfied. The new key-drop defect
remains a blocker until its fix and final verification are complete. No new
features or further RAM research are required merely to keep working.
