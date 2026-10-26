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
| **B. Complete, verified natively and in CI, waiting for review or merge** | exact head has green CI and a native run | #8, #12, #14, #16, #24, #28, #31, #29 (research only); #34 (R1, native evidence reported in its PR) |
| **C. Verified in CI only** | exact head has green CI, no native run at that head | #7, #10, #11, #17, #20, #23, #25, #36 (A/B scenario, smoke pending) |
| **C′. CI green, native run fails** | exact head has green CI, the native run found a defect fixed in a follow-up | #27 (fixed in #29) |
| **D. No verification at the exact head** | no CI run and no native run at the head | #2, #9, #18, #37 (`9e8c4eb`, no workflow result recorded); documentation-only PRs #1, #26, #30, #32, #33 (no build checks apply; #33 protocol is being revised) |

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
| #31 | `29adfed` | CI 40374808849 green | 2026-10-26: 87/87 vitest, tsc, build, fmt, clippy, 63 Rust tests, Release build, two-window run and forged events (see §3) | tests red on `85f2937` (commit `0ab78a9`) |
| #9 | `1f71b84` | none | stage 4 runs on 2026-10-25 used this stack | head has no CI |
| #18 | `1d57f6f` | none | native report exists for an earlier head `0784578` only | |
| #24 | `6952886` | Windows smoke 40220356939 green | 2026-10-26: fail-closed tests and smoke pass; median interval 0.214 s at 0.2 s, 0.9995 s at 1.0 s | another machine (Windows 10 Home 25H2, build 26200) measured 0.310 s at 0.2 s |
| #10 | `f73fe04` | baseline workflow 40127662239 green | stage 4 paired runs, 2026-10-25 | superseded as evidence |
| #17 | `1cb4bc0` | hosted Windows Release 40204930981 green | none at this head | superseded as evidence |
| #11 | `ee5f475` | CI 40124635438 green | stage 4 paired runs, 2026-10-25 | superseded as evidence |
| #16 | `ea8014b` | CI 40203656477 green | native report published at this head (2026-10-25) | superseded as evidence |
| #20 | `9c40dd5` | CI 40218090430 and Windows Release 40218090495 green | none | |
| #23 | `3f70b7d` | CI 40219219157 and Windows Release 40219219142 green | none | |
| #25 | `ed756a8` | CI 40224027381 and Windows Release 40224027347 green | none | its pilot must not run with old parameters; #33 revision 2 is also being revised for co-primary RAM and CPU |
| #27 | `491486b` | CI 40231896110 and spike workflow 40231896114 green (Linux) | 2026-10-26: fmt and clippy pass; tests fail 3/3 (see §3) | |
| #29 | `4e6d19b` | CI 40367216064 and spike workflow 40367215939 green, including hosted `windows-latest` | 2026-10-26: fmt and clippy pass; 9/9 unit and 12/12 cross-process tests in 9/9 runs (see §3) | |
| #32 | `bfe8399` | documentation-only; no checks apply | — | API shape and decisions recorded; open for review |
| #33 | `e79aca1` | documentation-only; no checks apply | — | Revision 2 is not current: it assumes RAM-primary and CPU guardrails; Group 1 has corrected to co-primary RAM + CPU. Recalculate statistics and parameters before any run |
| #34 | `d8106fa` | CI 40390472644 green | Native Windows evidence reported by the group in the PR | R1: cache budget and overflow-safe eviction; open, stacked on #14 |
| #35 | `b65177d` | CI 40414428677 in progress | Native Windows run was reported at earlier head `4d2b5ce`; no native result at `b65177d` recorded | R2 adds `ResponseBudget` and full view-call shutdown tracking; this head supersedes review follow-up #38 (closed, not merged) |
| #36 | `d0b2893` | CI 40395314459, catalog benchmark 40395314302 and symmetric benchmark 40395314370 green | Native Win10 smoke pending; no measurement run | Scenario M A/B only; pilot is blocked on arm C, revised #33 protocol and native smoke |
| #37 | `9e8c4eb` | no exact-head workflow result recorded | no native run recorded at this head | R3 adapter; based on #35 at `b65177d`; includes ResponseBudget integration, but operation-error sanitization is in #39 |
| #38 | `353bba5` | not applicable | Windows tests passed at its base-era change; PR closed without merge | Superseded by the group's #35 `b65177d` implementation of full view lifecycle tracking plus ResponseBudget |
| #39 | `272c408` | CI 40415000619 and Runtime adapter workflow 40415000620 in progress | Local Windows: adapter tests 13/13 and clippy pass; demo IPC test process failed to start (`STATUS_ENTRYPOINT_NOT_FOUND`) | Sanitizes operation error details; exact base #37 `9e8c4eb` |

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

### #31 @ `29adfed` (Runtime Lab: repeated and malformed window events)

Windows 10 Home 22H2 (19045.6466), Node 24.22.1, 2026-10-26. Logs:
`C:\Users\maxim\Projects\tmwr-logs\2026-10-26\pr31\`. Windows were driven by
script through the WebView2 DevTools protocol (`--remote-debugging-port`
bound to 127.0.0.1): real DOM clicks, no mouse.

| Check | Result |
|---|---|
| `npm test`, `tsc --noEmit`, `npm run build` | 87/87, pass, pass |
| fmt, clippy `-D warnings`, `cargo test --workspace` | pass, pass, 63 tests |
| `tauri build` (Release, exe + MSI + NSIS) | pass |
| Two windows, project-42 × 20 in both | 40 requests, 1 execution, 39 coalesced, 0 cache hits; one `computedAtMs`; both windows in one process |
| Forged `lab://run-series` (size 1000, "20", 21, missing, null payload, numeric projectId) | ignored |
| 5 identical valid `lab://run-series` events | exactly one series (+50 requests) |
| Valid event emitted by the secondary window to itself | series runs (+10): events carry no sender identity; the guard checks shape only |
| projectId of 10 000 characters | passes the frontend guard; Core rejects it with `INVALID_ARGUMENT` before counting |
| Forged `runtime://cache-invalidated` from secondary to main | Core cache unchanged; malformed payload (`123`) ignored; a well-formed `{projectId}` or `{projectId:null}` still shows the "dropped" hint in main (known limit, C-2) |
| `runtime_clear_cache` / `runtime_invalidate_project` from secondary | denied by the capability ACL |
| Final counters | 100 requests = 3 executions + 97 coalesced + 0 hits; 50 failed |

Not run: closing the secondary window during a series.

### #29 @ `4e6d19b` (cross-app spike hardening, research)

Windows 10 Home 22H2 (19045.6466), 2026-10-26. Logs:
`C:\Users\maxim\Projects\tmwr-logs\2026-10-26\` (pr29 files).

| Check | Result |
|---|---|
| At `ece3341`: cross-process tests | 11/12; `only_one_broker_owns_an_endpoint_and_it_exits_when_idle` failed 6/6: the 300 ms idle window was shorter than a cold process start (race inherited from #27) |
| At `4e6d19b` (test fix): cross-process tests | 12/12 in 6/6 runs, no hang; repeated in a separate worktree: 3/3 runs, 9/9 unit tests, ~7 s each (logs `stage6-broker\`) |
| At `491486b` (#27, before the fix) | fmt, clippy pass; `only_one_broker_owns_an_endpoint_and_it_exits_when_idle` fails in 3/3 runs (`brokerUnavailable`, os error 2: the first broker had already exited on idle). In one run the test's own 60 s timeout did not fire and the run hung until an external 600 s timeout killed it; the other 10 cross-process tests pass |
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
- Native runs of #20, #23 and #25 at their exact heads.
- Closing the secondary window while a series is running.
- Any pilot/confirmatory memory or CPU measurement under the co-primary plan; #33 revision 2 is superseded and must be recalculated before any run.
- Native Windows smoke for #36 and exact-head native verification for #35/#37/#39.
- Windows 11.
