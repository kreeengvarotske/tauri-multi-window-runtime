# Stable 0.1.0 release record

Stable `v0.1.0` is [published](https://github.com/kreeengvarotske/tauri-multi-window-runtime/releases/tag/v0.1.0)
as a GitHub Release with draft=false, prerelease=false and marked latest.
Publication was `2026-11-18T22:46:06Z`, November 18 at 23:46 Europe/Vienna.
Release ID is `450643793`. This receipt is generated from the published release,
verified downloads and qualification records. It supersedes pending status in
[the candidate snapshot](stable-release-qualification.md).

## Immutable source

| Item | Recorded value |
| --- | --- |
| Tag | `v0.1.0` |
| Annotated tag object | `6793e5c184ff0f161f8570bce11e6fe8a046800c` |
| Release commit | `6b87081b2da02560eb8edf098c3654e34b40b34c` |
| Source tree | `0637bc959a5066471c65f459dc3311caf2ba65fa` |
| Integration | [PR 77](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/77) |
| Completion receipt | [Final publication and anonymous download checks](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/77#issuecomment-6993889183) |
| Distribution/license | Public Git and optional locally packed client; MIT OR Apache-2.0; no registry publication or installer |

This later documentation commit does not move the release tag. The published
`v0.1.0-preview.1` tag/release remains unchanged.

## Completed qualification

- Exact-main [runtime CI](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/44409251766)
  and [client CI](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/44409251785): PASS.
- Exact-tag [runtime CI](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/44410437516)
  and [client CI](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/44410437504): PASS.
- Local Release: 174 unit/integration tests and four doctests, strict Clippy and
  Rustdoc, all three executable recipes: PASS. Client: 12 tests, TypeScript,
  demo synchronization and offline packed install/import/call/types: PASS.
- Fresh anonymous Git/tag consumer: all runtime crate identities match;
  real IPC, capabilities, close/reopen isolation, queues and shutdown: PASS.
- Combined build/application Job: 573 NEW / 573 EXIT / active-zero 1. Strict
  same-EXE/lock application: 9 NEW / 9 EXIT / active-zero 1. Both exited 0 with
  no timeout, leftovers or forced termination. No VCTIP exception was needed.
- Independent backend/native notes consumers passed on Windows and Ubuntu.
  The 600-second baseline notes soak completed 50,453 successful calls with two
  executions and 50,451 cache hits; 17 NEW / 17 EXIT, no leftovers. Its SDK was
  baseline `bf6b66c`; final production Git blobs are identical and metadata differs.
- Actual native matrix: Windows 26200, Rust 1.99.1, WebView2 157.0.4341.60;
  repository Tauri 2.12.5 and fresh external Tauri 2.12.7. Older qualification
  also exercised 2.12.6. Ubuntu CI does not establish production Linux support.

The local final check recorded CS2 running with explicit functional-only
allowance and sufficient free memory. No performance conclusion is drawn.
An earlier incomplete build cache failure remains in the evidence; a fresh
Release target passed. Chromium notes-exit diagnostic 1412 has an unconfirmed
cause; successful lifecycle checks do not claim a fix.

## Public evidence

All three assets were downloaded without authorization and matched local/server
SHA256 and the published [SHA256SUMS](https://github.com/kreeengvarotske/tauri-multi-window-runtime/releases/download/v0.1.0/SHA256SUMS).
The archive has 94 text payloads plus its manifest, with per-file hash read-back.
It excludes EXEs, PDBs, profiles, credentials and release API helpers.

| Asset | Bytes | SHA256 |
| --- | ---: | --- |
| [tmwr-0.1.0-evidence.zip](https://github.com/kreeengvarotske/tauri-multi-window-runtime/releases/download/v0.1.0/tmwr-0.1.0-evidence.zip) | 404277 | `9d769e08048ec8f646da82561f163be73e0f27f2f47a62ad792a8bcdae4c23b5` |
| [VERIFICATION.md](https://github.com/kreeengvarotske/tauri-multi-window-runtime/releases/download/v0.1.0/VERIFICATION.md) | 7290 | `3b3ff112b10a53a7e73c3830a963f44058235bb1edc27eeacbcb9146af0690d2` |
| [SHA256SUMS](https://github.com/kreeengvarotske/tauri-multi-window-runtime/releases/download/v0.1.0/SHA256SUMS) | 172 | `49aff0452dcff9ab343a9f63f41a92010bbc2c01707381f4eb88d3e3b9b7b495` |

The release covers the in-process SDK, Tauri adapter and optional JSON/TypeScript
client. Cache weights do not cap process RAM, and Arc holders can retain values.
Applications own validation/authorization and honest weights. General RAM/CPU
benefits, Chromium deduplication, production cross-app sharing, generated bindings
and registry publishing remain deferred. See the [stable guide](stable-release.md).
