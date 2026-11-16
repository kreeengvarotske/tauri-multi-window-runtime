# Windows developer preview release packet

Date: November 16, 2026. Status: candidate technically qualified under the
adopted build/runtime policy. Dependency-ordered integration, preview tag and
GitHub prerelease publication are authorized under the user's delegation of
remaining decisions and actions. Their completion is pending; this document
does not claim they have happened.

## Release identity and scope

| Item | State |
|---|---|
| Version and tag name | `0.1.0-preview.1`; creating and verifying `v0.1.0-preview.1` is a pending release action |
| License | `MIT OR Apache-2.0` |
| Distribution | Public Git repository; anonymous exact-SHA access verified. Rust crates retain `publish = false`; crates.io and npm registry publication are outside this preview |
| Supported platform | Windows, Tauri v2 and WebView2; no Linux/macOS/mobile support claim |
| Main before integration | `7244a5cbccbe37a96ac67c69f374d9de383eb2d5`; final integrated identity belongs in the release receipt |
| Dependency order | #66 → #67 → #68 → #70 → #72 → #73 → #74 → #75 |
| Superseded consumer candidate | `3e132fa6833eedede4cc9ea9dc7122ad0b1669a1` (#73) |
| Runtime-core key-drop fix PR / SHA | [#74](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/74), `0267a775679f4f554151ca4997520d55dfb74082`; fixed and qualified in the consumer candidate |
| Recipe/CI and release-document change set | [#75](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/75), `codex/preview-release-packet` against the #74 fix branch; exact-head evidence is in its PR receipt |
| Qualified consumer candidate | `e0c09b0db5788a83bc89881b0df3682f36dac1fa` (#75), containing #74 |
| Final integrated/tagged release SHA | Pending integration; record the actual identity and required CI in the release receipt |

The preview provides application-owned shared data, cached/coalesced operations,
bounded views and queues, window cleanup and an optional JS/TypeScript command
client. The [quick start](../examples/runtime-adapter-demo/README.md),
[client guide](../packages/runtime-client/README.md) and [three runnable
recipes](recipes.md) are the installation and usage entry points. Application
code supplies operation types, access checks and explicit workload limits.
There is no measured whole-app RAM/CPU saving claim. The frozen pilot remains
unchanged; new performance research, a production cross-app broker and
Rust-to-TypeScript code generation are deferred.

The active session took over the remaining review, consumer, recipe and
release-packet work on November 16 while the second group is unavailable for
the next four days. The [completion scope](plans/2026-11-15-developer-preview-focus.md)
records that ownership; release work does not wait for the group's return.

## Runtime fix and completed candidate checks

User key `Drop` can run while generation state is locked in `NoStore` and
overweight-result cleanup paths. This is a confirmed P2, separate from the
compiler-helper finding. Both regressions failed before the fix; 82 core tests
and one doctest passed after it. The fix is recorded in
[#74](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/74),
`0267a775679f4f554151ca4997520d55dfb74082`, on `codex/rejected-cache-key-drop`,
based on the #73 client branch. The recipe/release-document branch
`codex/preview-release-packet` descends from #74. Its separate PR #75 against the
fix branch records the reviewed head and evidence receipt.

Local validation passed 171 workspace unit/integration tests and four doctests
in both default (Debug) and Release profiles, Clippy in both profiles with
warnings denied, formatting and Rustdoc with warnings denied. All 12 JS tests,
strict TypeScript, demo-sync, an offline packed-client installation/import/call
and all three runnable recipes passed. Independent source reviews retained no
blocker. The confirmed runtime defect is fixed and qualified in `e0c09b0`.

Hosted Windows and Ubuntu CI passed on the exact heads of
[#74, run 43966505824](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/43966505824)
and [#75, run 43967276469](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/43967276469).
The [#75 evidence receipt](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/75#issuecomment-6931159120)
and retained `target/preview-final-evidence.md` record qualification of
`e0c09b0db5788a83bc89881b0df3682f36dac1fa`. This policy update does not change
that source/evidence identity or claim qualification of an unrecorded final
integrated revision.

## Qualified fresh consumer at `e0c09b0`

| Gate | Result and retained observation |
|---|---|
| Anonymous exact-SHA source | PASS: fresh bare Git fetch, isolated global/system config, empty helper and prompts/askpass disabled |
| Independent installation/identity | PASS: fresh project, target, lock and profile; all three runtime packages resolve once to `e0c09b0` at `0.1.0-preview.1` |
| Release compilation | PASS: 5m59s; Git/registry download caches could be reused; cold downloads are not claimed |
| Native functionality | PASS: real WebView IPC, validation/errors, capabilities, shared catalog, old/new window isolation, projection queue bounds and shutdown |
| Combined build/application cleanup | **FAIL:** exit 0, no timeout; one leftover after 30-second grace; 553 NEW / 552 EXIT / active-zero 1; owned Job forcibly cleaned to final active zero |
| Strict same-artifact application cleanup | PASS: new profile, unchanged executable and lock; exit 0, no timeout, leftovers or forced termination; 9 NEW / 9 EXIT / active-zero 1, final active zero |

Observed versions were Windows 10.0.26200.0, Rust 1.99.1, WebView2
157.0.4341.46, Tauri 2.12.6, tauri-build 2.7.5, tauri-utils 2.10.3 and
tauri-runtime-wry 2.12.4. The independent consumer resolved newer compatible
Tauri patches than the unchanged repository lock. These are observed versions,
not a broader support or MSRV guarantee.

- Consumer Cargo.lock SHA256: `eda1285850b0b95d72356e9a28af92453bce1c1f1b6011bfd1ab3076f375d5cf`.
- Consumer EXE SHA256: `498bd4eab7ccc84d5e8323f7d4be2bd62d81eb54364b80f1bf9172acfcfd91e2`.
- Combined evidence: `target/consumer-gate-20261116-23186edd`.
- Separate application evidence: `target/native-queued-view-d1097057`.
- Packed-client evidence: `client-package-d95b5617`.

Both hashes were unchanged after the separate application run. The first app's
fresh profile is recorded in consumer `revisions.json`; the separate app Job
used its own new profile. `wrapperInheritedProfile` records the parent launch
environment separately and is not the application profile.

The final nonempty combined snapshots contained only `vctip`, identity
`4000@639304639174276590`, parent `link.exe` PID 4376, first observed at
`2026-11-16T23:11:57.9932594+01:00` during compilation before the application.
Its NEW message has no matching EXIT. Sampling retained 304 PID/creation
identities with 35 identity-read misses. It is incomplete; Job message totals
are checked independently. The final run recorded name, creation and parent,
not the retained image path or executable hash. The earlier controlled
compiler-only reproduction below supplies attribution context; it is not a
claim that the final run recaptured that image hash.

## Historical consumer at superseded `3e132fa`

The following evidence applies only to `3e132fa`, not the fixed revision.
The external demo was extracted at that SHA into a new independent project,
target and profile. All three runtime packages resolved once to that exact Git
SHA at version `0.1.0-preview.1`. Cargo and registry download caches could be
reused; cold registry downloads were not claimed. There was no frontend npm or
bundler step.

| Gate | Result and retained observation |
|---|---|
| Anonymous source access | PASS: fresh bare exact-SHA Git fetch with isolated global/system config, empty credential helper and prompts/askpass disabled |
| Independent project and dependency identity | PASS: new project, target, lock and profile; exactly three runtime Git packages at the selected SHA |
| Release compilation | PASS: Cargo completed in 6m54s |
| Native assertions | PASS: shared catalog, IPC validation/errors, capabilities, queued close/reopen isolation, bounded projection queue and shutdown |
| Combined build/application cleanup | **FAIL:** exit 0, no execution timeout; one process survived the 30-second grace; 557 NEW / 556 EXIT / active-zero 1; owned Job forcibly cleaned to final active zero |
| Same-artifact application-only cleanup | PASS: fresh profile, exit 0; no timeout, leftovers or forced termination; 9 NEW / 9 EXIT / active-zero 1; final active zero and all native assertions pass |
| Compiler-only attribution | Empty `fn main() {}` compiled with `rustc`, without Cargo/Tauri/SDK, reproduced an installed MSVC VCTIP helper that remained after compiler exit and a 10-second diagnostic grace |

Artifact identities:

- Cargo.lock SHA256: `ae4d9e92380406c0b6f7e017babad037ed5c09f562038a00f90c00ef0dc0ed61`.
- Consumer EXE SHA256: `c6afecaa7872af6edf61c5caa475927d9bf7e3dcadcca1241f2eee3d04bf1c2b`.
- Observed versions: Windows build 26200; Rust/Cargo 1.99.1; Tauri 2.12.5;
  tauri-build 2.7.4; tauri-utils 2.10.2; WebView2 157.0.4341.46.

Retained local evidence, to attach or preserve with release approval:

- `target/consumer-verification-20261116.md`: evidence summary and attribution.
- `target/consumer-gate-20261116-5683b971`: original failed combined gate,
  including `evidence.json` and `runner.json`.
- `target/native-queued-view-b0154930`: same-artifact runtime inputs,
  `runner.json`, `self-test.json` and process-accounting evidence.
- `target/compiler-helper-b3505169` and
  `target/compiler-helper-8fa863c1`: compiler-only reproduction and metadata.

The retained combined-job identity was
`14856@639304242795518695`, name `vctip`, parent `link.exe` PID 13308.
It was created at `2026-11-16T11:11:19.5520372Z`, early in compilation before
the application started. The observer retained 320 PID/creation identities
and 29 identity-read misses. Sampling is incomplete; completion-message totals
are checked separately against Job accounting.

The reproduced image was
`C:/Program Files (x86)/Microsoft Visual Studio/18/BuildTools/VC/Tools/MSVC/14.51.36231/bin/HostX64/x64/VCTIP.EXE`,
version `14.51.36260.0`, SHA256
`41fe46f8a0b41f6dd94c68c85fba20a10aacb662a9ef04784a632e37f3692371`.
Its natural lifetime was not measured. The earlier sandboxed probe
`target/compiler-helper-80d09363` lacked an identified leftover; historical
PID 17056 also remains unidentified. Neither is retrospectively renamed.
System settings and installed binaries were unchanged; no opt-out workaround
was used. Forced cleanup stayed within each owned diagnostic Job.

## Adopted build/runtime release policy

On November 16, under the user's delegation of remaining decisions and actions,
the release owner adopted separate build and runtime gates. The measured MSVC
VCTIP build-only cleanup exception is accepted for this preview. This is an
explicit change to the original combined-cleanup acceptance requirement.

Source/install identity, Release compilation, native functionality and strict
application-only cleanup must pass. The qualified `e0c09b0` candidate satisfies
those gates. Both raw combined runs remain **FAIL** with `passed: false`, the
unmatched completion message, one leftover and forced owned-Job cleanup.
Final active zero after termination is containment, not natural cleanup.

The exception covers the attributed build-toolchain helper only. Any different
leftover or failed application cleanup requires its own disposition. No SDK
runtime cleanup defect was reproduced by this tooling finding; the SDK must
not terminate compiler services. System settings and installed binaries remain
unchanged. A global-system repair or new RAM study is not required.

The retained raw evidence predates this policy disposition and remains
unchanged. It does not itself claim that the exception was accepted. Historical
raw evidence is also preserved in `consumer-evidence-20261116.zip`, SHA256
`3ffc19640a2464d492b6f98ab65251c953c925d55faeeeb91095d89d2fea8f86`.

## Finite integration and verification checklist

1. Candidate review, local Debug/Release checks, exact-head Windows/Ubuntu CI,
   recipes/client packaging and the fresh consumer are complete at the recorded
   `e0c09b0` identity. Keep the PR evidence receipt and raw failed observations.
2. Execute the authorized dependency order
   #66 → #67 → #68 → #70 → #72 → #73 → #74 → #75. After each parent lands, retarget the
   next child to `main` before merging it. Recheck its expected head, remaining
   diff against `main` and actual required CI for that head/base. Resolve any
   new conflict or failure before continuing. Earlier CI results do not approve
   a changed diff or source revision.
3. Record the final integrated SHA containing the complete stack and key-drop fix,
   its actual Windows/Ubuntu CI links and green required checks. Historical spending
   restrictions and old successful runs do not determine current CI status.
4. Retain completed formatting, Debug/Release workspace tests/Clippy, Rustdoc,
   key-drop regressions, client/TypeScript/packed installation/demo-copy and
   recipe receipts. No duplicate run is required for unchanged sources.
5. Carry the adopted compiler-helper policy, observed supported versions,
   installation/recipe review, [release notes](windows-preview-release-notes.md)
   and confirmation that no unresolved P1/P2 remains. Complete the final evidence
   fields below. Performance research and registry readiness add no gate.
6. After final-main CI passes, execute the delegated tag action: create the
   immutable annotated `v0.1.0-preview.1` at that exact SHA. Verify that the
   remote tag peels to the recorded main SHA. A local test tag is not this check.
7. Run one fresh anonymous consumer with `-Tag` and require its resolved SHA to
   match that final main SHA. This single build qualifies both final main source
   and the remote tag; no separate main consumer rebuild is required. Retain the
   independent project/target/profile, three-package lock identity,
   `revisions.json`, `Cargo.lock`, executable hash and native `self-test.json`.
   Record source access, Release build, functionality, build-environment cleanup
   and strict same-artifact application cleanup separately. Require the strict
   app Job to pass with reconciled accounting/messages, zero leftovers and no
   forced cleanup. Retain the raw combined result and require tag CI to pass.
8. Execute the delegated publication action: publish a GitHub prerelease with
   the actual tag SHA, adopted scope/policy and evidence links after tag CI,
   the matching-SHA tag consumer and strict application cleanup pass. Record the
   completed release URL. Merge, tag and publication remain separate actions;
   all are authorized, and none is marked complete until its receipt exists.

## Final evidence and decision record

| Required field | Current value |
|---|---|
| Key-drop fix / regression receipt | [#74](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/74), `0267a775679f4f554151ca4997520d55dfb74082`; two red-before regressions, 82 core tests and one doctest green after; qualified in `e0c09b0` |
| Recipe/CI and release-document PR evidence | [#75 receipt](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/75#issuecomment-6931159120); qualified source `e0c09b0`, subsequent policy disposition recorded here |
| Stack integration | Authorized under delegated decisions; per-PR retarget/head/diff/CI and merge receipts pending |
| Exact-head candidate CI | PASS: [#75 Windows/Ubuntu run 43967276469](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/43967276469) |
| Final integrated release SHA and required CI | Pending integration receipt; no final main/tag identity is asserted here |
| Workspace, formatting and documentation checks | PASS: Debug/Release 171 unit/integration tests plus four doctests; both Clippy profiles, formatting and Rustdoc with warnings denied |
| Client, package and recipes | PASS: 12 JS tests, strict TypeScript, demo-sync, offline packed installation/import/call and all three recipes |
| Qualified external consumer | PASS source/install/build/native/strict app cleanup at `e0c09b0`; combined build/app cleanup remains FAIL |
| Build-toolchain exception | Adopted November 16 under delegated authority; both raw combined FAIL results preserved |
| Support/install/release scope | Windows-only observed versions and application-owned limits recorded; no remaining technical blocker retained in candidate review |
| Tag, remote peeled SHA, tag consumer and tag CI | Authorized; immutable tag and one matching-SHA `-Tag` consumer qualify final main/tag together; execution and evidence pending |
| GitHub prerelease publication | Authorized; execution and release URL pending |

## Historical evidence index

The [preview review appendix](windows-preview-review.md#appendix-earlier-release-review)
preserves earlier main/stack verification, packaging checks and benchmark
context. Those records remain scoped to their recorded revisions. They do not
qualify the fixed final candidate or change the frozen pilot's conclusions.
