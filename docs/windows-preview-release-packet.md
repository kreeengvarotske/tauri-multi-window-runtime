# Windows developer preview release packet

Date: November 16, 2026. Status: awaiting integration of the key-drop fix, final
qualification and separate release decisions. This packet does not authorize
merging, tagging or publication.

## Release identity and scope

| Item | State |
|---|---|
| Version and tag name | `0.1.0-preview.1`; planned tag `v0.1.0-preview.1` is absent |
| License | `MIT OR Apache-2.0` |
| Distribution | Public Git repository; anonymous exact-SHA access verified. Rust crates retain `publish = false`; crates.io and npm registry publication are outside this preview |
| Supported platform | Windows, Tauri v2 and WebView2; no Linux/macOS/mobile support claim |
| Main at review | `7244a5cbccbe37a96ac67c69f374d9de383eb2d5` |
| Unmerged dependency stack | #66 → #67 → #68 → #70 → #72 → #73 → #74 |
| Superseded consumer candidate | `3e132fa6833eedede4cc9ea9dc7122ad0b1669a1` (#73) |
| Runtime-core key-drop fix PR / SHA | Open [#74](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/74), `0267a775679f4f554151ca4997520d55dfb74082`; must be included |
| Recipe/CI and release-document change set | `codex/preview-release-packet` against `codex/rejected-cache-key-drop`; its PR evidence receipt records the exact reviewed head |
| Final release SHA | Pending integration and final exact-SHA verification |

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

## Confirmed runtime blocker

User key `Drop` can run while generation state is locked in `NoStore` and
overweight-result cleanup paths. This is a confirmed P2, separate from the
compiler-helper finding. Both regressions failed before the fix; 82 core tests
and one doctest passed after it. The fix is open as
[#74](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/74),
`0267a775679f4f554151ca4997520d55dfb74082`, on `codex/rejected-cache-key-drop`,
based on the #73 client branch. The recipe/release-document branch
`codex/preview-release-packet` descends from #74. Its separate PR against the
fix branch records the reviewed head and evidence receipt.

Local validation passed 171 default-profile (Debug) workspace unit/integration
tests and four doctests, default-profile Clippy with warnings denied, 12 JS
tests, strict TypeScript checking, demo-sync, an offline packed-client install
and all three runnable recipes. Final Release checks, hosted CI and fresh consumer
qualification including #74 remain pending. These local results do not qualify
a different final source revision.

## Superseded consumer evidence

The following evidence qualifies only `3e132fa`, not the pending fixed revision.
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

## Build/runtime acceptance decision

The original scope requires complete owned-job cleanup/accounting. The combined
run fails that requirement and retains `passed: false`. Final active zero after
forced termination is containment, not natural-cleanup success.

Recommended policy, pending explicit release acceptance: require successful
installation/build identity and strict application-only lifecycle/accounting
as distinct gates. Retain combined build-environment cleanup as its own result
and document the measured compiler-helper exception. No SDK runtime defect was
reproduced by this tooling finding; no SDK workaround should terminate compiler
services. This recommendation does not waive the original requirement.

Record one release-policy decision before declaring qualification complete:

- Accept the attributed build-toolchain cleanup exception while keeping the
  combined gate failed and requiring strict final application cleanup; or
- Retain completely clean combined compilation as mandatory and obtain bounded
  qualification in a suitable toolchain/environment before release.

An unbounded global-system repair or new RAM study is not a release prerequisite.
Any different leftover or failed application cleanup in final verification
requires its own attribution and disposition.

## Finite integration and verification checklist

1. Review the final key-drop fix and the remaining expected heads/diffs in
   dependency order: #66 → #67 → #68 → #70 → #72 → #73 → #74, followed by
   recipe/CI and release-document changes. Record actual PR numbers
   and heads; the pending labels above are not approval receipts.
2. Obtain the separate merge decision. After each parent lands, retarget the
   next child to `main` before merging it. Recheck its expected head, remaining
   diff against `main` and actual required CI for that head/base. Resolve any
   new conflict or failure before continuing. Earlier CI results do not approve
   a changed diff or source revision.
3. Select one final SHA containing the complete stack and key-drop fix. Record
   its actual Windows/Ubuntu CI links and required checks. Historical spending
   restrictions and old successful runs do not determine current CI status.
4. Record formatting, default-profile workspace tests/Clippy, full Release
   workspace tests/doctests and Release Clippy with warnings denied at the
   reviewed head. Retain the focused key-drop regression receipt, client tests,
   strict TypeScript fixtures, packed installation and demo-copy checks, and
   each runnable recipe. Record check commands/results in the PR evidence
   receipt; no duplicate run is required for unchanged sources.
5. Run one fresh external consumer through the public source at the final SHA.
   Retain independent project/target/profile, exact three-package lock identity,
   `revisions.json`, `Cargo.lock`, executable hash and native `self-test.json`.
   Record source access, Release build, functionality, build-environment cleanup
   and strict application cleanup separately. The latter must reconcile Job
   accounting/messages with zero leftovers and no forced cleanup.
6. Record the compiler-helper policy decision, final supported versions,
   installation/recipe review, [release notes](windows-preview-release-notes.md)
   and confirmation that no unresolved P1/P2 remains. Complete the final evidence
   fields below. Performance research and registry readiness add no gate.
7. Obtain the separate tag decision. Create `v0.1.0-preview.1` only for the
   selected SHA, verify the remote peeled commit, anonymous tag consumer and tag
   CI, and retain the tag evidence. A local test tag is not this check.
8. Obtain the separate publication decision. Publish the GitHub Release with
   the actual tag SHA, approved scope and evidence links. Do not infer tag or
   publication approval from the merge decision.

## Final evidence and decision record

| Required field | Current value |
|---|---|
| Key-drop fix PR / exact SHA and focused regression receipt | Open [#74](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/74), `0267a775679f4f554151ca4997520d55dfb74082`; two red-before regressions, 82 core tests and one doctest green after |
| Recipe/CI and release-document PR / reviewed-head evidence receipt | See the PR for `codex/preview-release-packet` against the #74 fix branch |
| Reviewed stack expected heads and merge decision | Pending |
| Final integrated release SHA and required CI links | Pending |
| Local workspace check receipt | PASS: 171 default-profile (Debug) unit/integration tests, four doctests and Clippy with warnings denied; final Release receipts pending |
| Final formatting/tests/doctests/Clippy receipt | Pending in the reviewed PR evidence receipt |
| Client, packed installation and three recipe receipts | PASS locally: 12 JS tests, strict TypeScript, demo-sync, offline packed installation and all three recipes; CI and final-head receipts belong to the PR |
| Final external source/build/identity/native/runtime artifacts | Pending; `3e132fa` artifacts remain superseded |
| Build-toolchain cleanup exception decision | Pending; original combined observation remains FAIL |
| Final support matrix, installation and release-note approval | Pending |
| Tag decision, remote peeled SHA, tag consumer and tag CI | Pending |
| GitHub Release publication decision and URL | Pending |

## Historical evidence index

The [preview review appendix](windows-preview-review.md#appendix-earlier-release-review)
preserves earlier main/stack verification, packaging checks and benchmark
context. Those records remain scoped to their recorded revisions. They do not
qualify the fixed final candidate or change the frozen pilot's conclusions.
