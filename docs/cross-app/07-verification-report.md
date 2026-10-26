# 07. Verification report

Environment for local runs: Linux container (x86_64, kernel 6.18), rustc 1.97.0 stable and 1.89.0. **No native Windows run and no measurement was performed.**

## 1. Base and scope

- Branch `claude/project-thread-kzgcyj`, based on PR #14 head `772155def9f4baf232f43864a80add7cd3c5192c` (the stack #2 → #7 → #8 → #12 → #14).
- New files only: `docs/cross-app/*`, `experiments/cross-app-spike/*`, `.github/workflows/cross-app-spike.yml`. No existing file changed; the root `Cargo.lock` is unchanged.
- Overlap with open PRs: none. #20/#23/#25 touch `benchmarks/symmetric`, #24 the monitor, #26 `AGENTS.md`/`docs/CODEX_*`.

## 2. Commands actually run (local)

| Command (in `experiments/cross-app-spike` unless noted) | Result |
|---|---|
| `cargo test --locked` (stable 1.97.0) | 8 unit + 11 cross-process tests passed |
| `cargo +1.89 test -q` | 8 + 11 passed |
| `cargo clippy --all-targets --locked -- -D warnings` | clean |
| `cargo clippy --target x86_64-pc-windows-msvc --all-targets --locked -- -D warnings` | clean. **Type-check only**: Windows code compiled, not linked or run |
| `cargo fmt --check`; root `cargo fmt --all --check` | clean |
| `cargo test -q --test cross_process` ×20 | 20/20 passed |

One real defect was found and fixed during development: a call started after the connection had closed waited forever (the restart test hung). The client now refuses new calls once the connection is gone (`Pending = Option<HashMap>`).

## 3. Mutation checks (local, reverted after each)

| # | Mutation | Caught by |
|---|---|---|
| M1 | Cache/coalescer key ignores the scope (`(Scope::Public, params)`) | `app_scope_is_never_shared_between_applications` (beta got `coalesced`) |
| M2 | `ChecksumParams` accepts unknown fields | `grants_and_parameters_are_enforced_by_the_broker` |
| M3 | Executable check skipped | `claims_that_the_os_does_not_back_are_rejected` |
| M4 | App-scope notices broadcast to every app | `notices_reach_only_clients_that_can_read_the_scope` |
| M5 | Client keeps waiting for a cancelled id | two cancellation tests (time out) |

Error caching is guarded by Core's own tests (#12/#14), plus `errors_are_never_cached_or_shared_late` here.

## 4. CI on exact head `70fffe1c21b2a4b44754af61838b6e850691b187`

| Workflow / job | Result |
|---|---|
| Cross-app spike [40231206779](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/40231206779): `test (ubuntu-latest, stable)` | success |
| same run: `test (ubuntu-latest, 1.89)` | success |
| same run: `test (windows-latest, stable)`, which runs the named-pipe transport and the Windows exe-path identity check across real processes, plus 5 repeats | success (hosted runner, **not** a native Windows 10/11 machine) |
| General CI [40231206673](https://github.com/kreeengvarotske/tauri-multi-window-runtime/actions/runs/40231206673): `rust`, `frontend` | success (root workspace unaffected) |

## 5. Not verified

- A native Windows 10/11 run (hosted Windows CI is not native evidence).
- Cross-user refusal (needs a second OS account), fake-broker squatting on Windows, fork/fd-passing impersonation.
- Any timing, CPU or memory property. `--op-delay-ms` only orders events in tests.
- macOS (identity is not implemented there).

## 6. Independent review, 2026-10-26 (stacked follow-up on `491486b`)

Reviewed from the code, not from §1–§5. Findings and what changed:

| # | Finding at `491486b` | Severity | Change |
|---|---|---|---|
| R1 | `Broker::serve` returned on any `accept` error, so one connection that failed while being accepted (EMFILE on Linux; a client gone before `ConnectNamedPipe` on Windows) stopped the broker for every client | high (availability) | The error is logged and skipped after a 50 ms back-off. On Windows a fresh pipe instance is created even when `connect` fails. Red-then-green test `a_failed_accept_does_not_stop_the_broker` (Linux: broker under `prlimit --nofile=48`; Windows: 300 connect-and-drop) |
| R2 | Windows client did not check who runs the broker (`let _ = server`). The pipe namespace is shared by all users, so another user could create the name first and receive calls / return fake results | high (spoofing, T-3) | Client refuses a broker whose process token SID differs from its own |
| R3 | Windows broker did not check the client's user. Cross-user refusal relied on the implicit default pipe DACL (LocalSystem/Administrators/owner full, **Everyone and Anonymous read**) | medium | Explicit DACL `D:P(A;;GA;;;<current SID>)` on every instance; `identity::verify` requires same SID on Windows, mirroring the Unix uid check |
| R4 | Default endpoint name used `%USERNAME%` (caller-controlled, not unique across domains) | low | Uses the user SID |
| R5 | No limit on the number of connections; a silent client holds a connection until the Hello timeout and a partially sent frame (≤1 MiB) has no read timeout after Hello | low (same-user DoS) | Not changed; recorded under T-10 for P2 |

Still provisional and **not** a production identity: `pid → executable → manifest` (Q1). A same-user process can still pass a connected handle to another process (T-2), and the manifest is only as strong as its file ACL (T-14).
