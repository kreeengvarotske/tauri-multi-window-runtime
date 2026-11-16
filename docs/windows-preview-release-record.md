# Windows developer preview release record

The Windows developer preview is complete and published as
[v0.1.0-preview.1](https://github.com/kreeengvarotske/tauri-multi-window-runtime/releases/tag/v0.1.0-preview.1).
Publication was `2026-11-16T23:06:12Z`, November 17 in Europe/Vienna.
The GitHub Release is a prerelease, not a draft; release ID is `447724287`.
The [final completion receipt](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/75#issuecomment-6932033732)
and this record supersede pending-action status in the earlier release documents.

## Immutable release identity

| Item | Recorded value |
|---|---|
| Version / public Git tag | `0.1.0-preview.1` / `v0.1.0-preview.1` |
| Annotated tag object | `9ef5c16170ca65dcddd29122a9a06a898bf62079` |
| Remote peeled commit / final main source | `f44028c48afde938ef12a16bc7cc4a668ae8da50` |
| Release tree | `64b55fddfe52af291a34711e8e06ea6eda9911ce` |
| Reviewed integration head with that tree | `ec80c88c148be70166b0e525bf1e1aef2560ce9a` (#75) |
| Distribution / license | Public Git; `MIT OR Apache-2.0`; no crates.io or npm registry publication |

All eight PRs merged in dependency order: #66 → #67 → #68 → #70 → #72 → #73 →
#74 → #75. Each next child was retargeted to main and merged with an expected-head
guard. The annotated tag is immutable. This later completion record and README
corrections do not move the tag or change the release source SHA.

## Completed checks

| Exact-source CI | Result |
|---|---|
| [Final-main Runtime adapter, Windows/Ubuntu, run 43973429038](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/43973429038) | PASS |
| [Final-main client, run 43973429113](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/43973429113) | PASS |
| [Tag Runtime adapter, Windows/Ubuntu, run 43974418066](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/43974418066) | PASS |
| [Tag client, run 43974417851](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/43974417851) | PASS |

The rejected-key regressions failed before [#74](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/74)
and passed after its fix; 82 core tests and one doctest passed. At baseline
`e0c09b0`, Debug and Release each passed 171 workspace unit/integration tests and
four doctests. Both Clippy profiles, formatting and Rustdoc with warnings denied
passed. Runtime, consumer and client sources are unchanged in the release;
subsequent differences were documentation and CI grouping.

All 12 JS tests, strict TypeScript, demo-copy checking, offline packed-client
installation/import/call and the three Rust recipes passed. Independent review
retained no blocker in the fix, recipes, guides or release checklist.

## Final anonymous tag consumer

One fresh anonymous `-Tag v0.1.0-preview.1` consumer verified both final main
source and the remote tag at the exact release SHA. It used isolated global/system
Git configuration, an empty credential helper, disabled prompts/askpass and a new
project, target, lock and application profile. All three runtime crates resolved
once to that tag/SHA. Download caches could be reused; cold downloads are not claimed.

Release compilation passed in 5m50s. Real WebView assertions passed shared catalog,
IPC validation/errors, capabilities, queued close/reopen isolation, projection
queue bounds and shutdown. The separate strict app Job used a new profile and
the unchanged consumer executable and lock.

| Process gate | Raw result |
|---|---|
| Combined build/application Job | **FAIL:** exit 0, no timeout; 574 NEW / 573 EXIT / active-zero 1; one leftover after the 30-second grace; forced owned-Job cleanup; final active zero after termination |
| Strict same-artifact application Job | **PASS:** exit 0; 9 NEW / 9 EXIT / active-zero 1; final active zero; no timeout, leftovers or forced termination; all assertions pass |

| Artifact, unchanged after the strict app run | SHA256 |
|---|---|
| Consumer Cargo.lock | `8b4443c85d1cca4680ba7770955ce913f002822894a4a180eca3178978ba0532` |
| Consumer EXE | `213147b5ebeaa4c30be6d7585f7676a101bbc4cde12df6c18e162e898796690a` |

Observed versions were Windows 10.0.26200.0, Rust 1.99.1, WebView2 157.0.4341.46,
Tauri 2.12.6, tauri-build 2.7.5, tauri-utils 2.10.3 and tauri-runtime-wry 2.12.4.
The external consumer did not change the repository lock. These observations
establish neither broader platform compatibility nor an MSRV guarantee.

## Adopted build-only exception

On November 16, under delegated release authority, the release owner adopted the
measured MSVC VCTIP build-only cleanup exception. Source/install identity, Release
build, native functionality and strict application cleanup passed. This explicitly
changes the original combined-cleanup acceptance rule; the raw combined result
above remains FAIL. Historical candidate failures also remain unchanged.

The sole final leftover was `vctip`, identity `21228@639304664871972228`, parent
`link.exe` PID 28576, created during compilation before the app. The verified
owned process handle yielded
`C:/Program Files (x86)/Microsoft Visual Studio/18/BuildTools/VC/Tools/MSVC/14.51.36231/bin/Hostx64/x64/vctip.exe`,
version `14.51.36260.0`, SHA256
`41fe46f8a0b41f6dd94c68c85fba20a10aacb662a9ef04784a632e37f3692371`.
This matches the earlier empty-rustc reproduction without Cargo, Tauri or SDK.

Sampling retained 302 PID/creation identities with 36 identity-read misses;
Job messages/accounting were checked separately. Natural helper lifetime was not
measured; historical PID 17056 remains unidentified. Forced cleanup stayed within
the owned Job. No system settings or installed compiler binaries changed. The
exception permits no application or unattributed leftover, and adds no SDK code
that terminates compiler services. Final active zero after forced cleanup records
containment, not natural-cleanup success.

## Published evidence

The [evidence ZIP](https://github.com/kreeengvarotske/tauri-multi-window-runtime/releases/download/v0.1.0-preview.1/tmwr-0.1.0-preview.1-evidence.zip),
[VERIFICATION.md](https://github.com/kreeengvarotske/tauri-multi-window-runtime/releases/download/v0.1.0-preview.1/VERIFICATION.md)
and [SHA256SUMS](https://github.com/kreeengvarotske/tauri-multi-window-runtime/releases/download/v0.1.0-preview.1/SHA256SUMS)
were anonymously downloaded and their hashes verified after publication.
The ZIP SHA256 is `6cd016234154a9f4f5ab8e2c25aa3d8c7dd2b4449cdf5400aa1ebcaa4c690d1c`.
It contains 126 payload files plus a per-file SHA256 manifest, with four
binary/container omissions explicitly recorded. Executables, PDBs, browser
profiles, credentials and binary package containers are not published. Original
archives remain unchanged locally. Final raw directories are
`target/consumer-gate-20261116-5f07edbb` and `target/native-queued-view-96237f76`.

## Delivered scope and continuation

The preview delivers shared/per-window cached and coalesced operations, explicit
cache/admission/deadline limits, bounded views and queues, window cleanup/shutdown,
and typed Tauri commands with capabilities and fixed framework error envelopes.
Use the [backend quick start](../examples/runtime-adapter-demo/README.md), optional
[JS/TypeScript client](../packages/runtime-client/README.md) and [three recipes](recipes.md).
The client accepts injected Tauri `invoke`; it adds no retries, frontend cache or
cancellation layer. Preview support is Windows with Tauri v2 and WebView2.

RAM/CPU savings, Chromium deduplication, a production cross-app broker, code
generation, frontend bindings, plugin/ORM expansion and macOS/mobile support
remain deferred. The frozen pilot's protocol and findings are unchanged.
The returning second group should use this completed record and immutable tag;
superseded pending checklists are historical, not work to restart.
