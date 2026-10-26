# Verification status

Status as of 2026-10-26. This file records what has been checked, at which
exact commit, on which platform, and what has not been checked. An open pull
request is **not** an integrated feature: only commits on `main` are
integrated. Hosted CI is not native verification.

Native machine for every "native" entry below unless stated otherwise:
Windows 10 Home 22H2, build 19045.6466 (not Windows 11), AMD Ryzen 7 9800X3D,
31 GB RAM, WebView2 155, Rust stable 1.99.1 `x86_64-pc-windows-msvc`. Logs are
on that machine under `C:\Users\maxim\Projects\tmwr-logs\<date>\`.
Linux entries: container with rustc 1.97.0 and Node 22.

## 1. Categories

| Category | Meaning | PRs |
|---|---|---|
| **A. Integrated and verified** | merged into `main`, tests pass at the `main` commit | #3, #4, #5 (`main` @ `4bf7da3`) |
| **B. Complete, verified natively and in CI, waiting for review or merge** | exact head has green CI and a native run | #8, #12, #14, #16, #24, #28, #29 (research only) |
| **C. Verified in CI only** | exact head has green CI, no native run at that head | #7, #10, #11, #17, #20, #23, #25, #27, #31 |
| **D. No verification at the exact head** | no CI run and no native run at the head | #2, #9, #18; documentation-only PRs #1, #26, #30, #32, #33 (no checks apply) |

#29 and #27 are research under `experiments/` and are not part of the product
whatever their category (see `docs/ROADMAP.md`, Phase 5).

## 2. Per pull request

| PR | Head | CI at exact head | Native at exact head | Notes |
|---|---|---|---|---|
| `main` | `4bf7da3` | no workflow on `main` | — | Linux 2026-10-26: fmt, clippy `-D warnings`, 36 tests pass |
| #2 | `37d82d5` | none (CI is added in #7) | none at this head | covered only transitively by #7's CI |
| #7 | `1bbbc4a` | CI 40016728038 green | none at this head | |
| #8 | `1434e31` | CI 40018036550 green | 2026-10-26: fmt, clippy, 44 tests pass | Linux same day: same result |
| #12 | `c728538` | CI 40190883397 green | 2026-10-25 (#12 comment 6397626213) and 2026-10-26: 55 tests pass | approved by the owner; must follow #8 |
| #14 | `772155d` | CI 40193472340 green | 2026-10-26: 62 tests pass; `runtime-core` + `runtime-ipc` tests 10/10 debug, 5/5 release | |
| #28 | `85f2937` | CI 40305176144 green | 2026-10-26: all checks, Release build, manual two-window run (see §3) | |
| #31 | `29adfed` | CI 40374808849 green | none yet | tests red on `85f2937` (commit `0ab78a9`) |
| #9 | `1f71b84` | none | stage 4 runs on 2026-10-25 used this stack | head has no CI |
| #18 | `1d57f6f` | none | native report exists for an earlier head `0784578` only | |
| #24 | `6952886` | Windows smoke 40220356939 green | 2026-10-26: fail-closed tests and smoke pass; median interval 0.214 s at 0.2 s, 0.9995 s at 1.0 s | another machine (Windows 10 Home 25H2, build 26200) measured 0.310 s at 0.2 s |
| #10 | `f73fe04` | baseline workflow 40127662239 green | stage 4 paired runs, 2026-10-25 | superseded as evidence |
| #17 | `1cb4bc0` | hosted Windows Release 40204930981 green | none at this head | superseded as evidence |
| #11 | `ee5f475` | CI 40124635438 green | stage 4 paired runs, 2026-10-25 | superseded as evidence |
| #16 | `ea8014b` | CI 40203656477 green | native report published at this head (2026-10-25) | superseded as evidence |
| #20 | `9c40dd5` | CI 40218090430 and Windows Release 40218090495 green | none | |
| #23 | `3f70b7d` | CI 40219219157 and Windows Release 40219219142 green | none | |
| #25 | `ed756a8` | CI 40224027381 and Windows Release 40224027347 green | none | its pilot must not run with the old parameters (RAM is now primary) |
| #27 | `491486b` | CI 40231896110 and spike workflow 40231896114 green (Linux) | see §3 | |
| #29 | `4e6d19b` | CI 40367216064 and spike workflow 40367215939 green, including hosted `windows-latest` | 2026-10-26: 12/12 cross-process tests in 6/6 runs (see §3) | |

## 3. Native results for #28 and #29

### #28 @ `85f2937` (Runtime Lab: window events, invariant wording)

Windows 10 Home 22H2 (19045.6466), 2026-10-26. Logs:
`C:\Users\maxim\Projects\tmwr-logs\2026-10-26\` (pr28 files).

| Check | Result |
|---|---|
| `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test --workspace` | pass |
| `npm ci`, `npm test` (vitest 85/85), `npm run build` | pass |
| `tauri build` (Release) | pass |
| Manual: two real Tauri windows, series of 20 in both windows | 40 requests, 1 execution, 39 coalesced; invariant adds up once both series finish |
| Manual: forged `lab://run-series` with `size: 100000` from a window | ignored |

Limits: the repeated-event and malformed-invalidation cases fixed in #31 were
not part of this run. `tauri build` rewrites `src-tauri/Cargo.toml`
(`features = []`) and converts four generated permission files to CRLF; the
content is unchanged and the files were restored.

### #29 @ `4e6d19b` (cross-app spike hardening, research)

Windows 10 Home 22H2 (19045.6466), 2026-10-26. Logs:
`C:\Users\maxim\Projects\tmwr-logs\2026-10-26\` (pr29 files).

| Check | Result |
|---|---|
| At `ece3341`: cross-process tests | 11/12; `only_one_broker_owns_an_endpoint_and_it_exits_when_idle` failed 6/6: the 300 ms idle window was shorter than a cold process start (race inherited from #27) |
| At `4e6d19b` (test fix): cross-process tests | 12/12 in 6/6 runs, no hang |
| Pipe DACL | owner-only confirmed |
| Broker keeps serving after a failed accept | covered by `a_failed_accept_does_not_stop_the_broker` (300 connect-and-drop on Windows) |

Not verified, needs a special environment:

| Check | Why not run | Needs |
|---|---|---|
| Another local user cannot connect (DACL denial seen from the other side) | no second account | a second local Windows account |
| A squatting pipe owned by another user is refused by the client (SID check) | no second account | a second local Windows account |
| Elevated vs non-elevated process of the same user | not attempted | an elevated run; same SID, different integrity level |
| A real `accept` failure on Windows (descriptor exhaustion) | Windows has no `prlimit`; the test uses connect-and-drop | a fault-injection setup |
| Windows 11 | no machine | a Windows 11 machine |

## 4. What has not been verified anywhere

- #2, #9 and #18 at their exact heads.
- Native runs of #20, #23, #25 and #31 at their exact heads.
- Any memory measurement under the RAM-primary plan (`docs/ROADMAP.md`).
- Windows 11.
