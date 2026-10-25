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

## 4. CI

Filled in after the Draft PR's first run. The workflow `cross-app-spike.yml` runs fmt, clippy `-D warnings`, the tests, and 5 repeats of the cross-process suite on ubuntu (stable, 1.89) and windows (stable).

## 5. Not verified

- A native Windows 10/11 run (hosted Windows CI is not native evidence).
- Cross-user refusal (needs a second OS account), fake-broker squatting on Windows, fork/fd-passing impersonation.
- Any timing, CPU or memory property. `--op-delay-ms` only orders events in tests.
- macOS (identity is not implemented there).
