# 06. Implementation plan, acceptance criteria, and questions for Group 1

## 1. Phases

Each phase is its own Draft PR. A phase starts only when the previous one is accepted. Nothing here changes the existing Tauri IPC, capabilities, DTOs or security model. Those change only in phase P5, and only after the decisions below.

| Phase | Content | Acceptance criteria | Blocked by |
|---|---|---|---|
| **P0** (this PR) | ADR proposal, threat model, API spec, methodology, and a non-normative spike in `experiments/` | Spike CI green on Linux (stable + 1.89) and Windows; all tests use separate processes and synthetic data; no file outside `docs/cross-app`, `experiments/` and one new workflow is touched | — |
| **P1** | ADR decision record: accept, amend or reject O2. Answer Q1–Q8 | Written decision in #13 or as an ADR file approved by Group 1 | Group 1 |
| **P2** | Hardened broker crate (out of `experiments/`): chosen identity mechanism (Q1), manifest location and protection (Q2), Windows client-side server check (T-3), audit log, per-app quotas, spawn-on-demand from a fixed path | Threat-model tests §5 all automated; native Windows 10 run (and 11 if claimed) of the cross-process suite; cross-user refusal checked manually with a second account | P1 |
| **P3** | Measurement build: `--mode plain|shared` switch in one client binary, copy counters, monitor multi-root PID set (on top of #24) | G-X2/G-X3 met; synthetic regression for the counters; exact-head CI and a native smoke | P2, #24 accepted |
| **P4** | Pilot, then confirmatory memory runs per [05](05-memory-methodology.md) | G-X4/G-X5 met; raw data and failed runs published; break-even reported with CI | P3, Group 1 protocol approval |
| **P5** | Tauri integration: the app's Rust side uses the SDK behind its existing commands, with an in-process fallback. Typed TS wrappers only if Group 1 approves a contract change | No WebView path to the broker; fallback test with the broker absent; existing Runtime Lab tests unchanged | P4 shows a benefit; contract decision |
| **P6** | Decision: keep O2, or return to O1 if there is no benefit | Measured numbers against the R8 criterion | P4 |

If P4 finds no break-even for realistic `D` and `T`, the plan stops at P6 with O1 (the standing rule: drop the shared runtime if it is not worth it).

## 2. Definition of done for the prototype (P0), as checked

- [x] Two separately launched client processes use one broker process (`two_processes_share_one_public_execution`: 1 execution, 1 coalesced, then 1 cache hit from a third process).
- [x] Typed interface (`Operation` trait, strict params), versioned handshake.
- [x] Only synthetic data. No real apps, accounts, secrets or network.
- [x] Scope isolation, identity rejection, grants, errors not cached, cancellation, client kill, broker crash/restart, single instance, idle exit, scoped notices: all as cross-process tests.
- [ ] Windows: compiled and clippy-clean for `x86_64-pc-windows-msvc` locally; the tests run on the Windows CI runner (see [07](07-verification-report.md)). **Native Windows 10 run: not done.**
- [ ] Spawn-on-demand from the client: designed, not implemented (tests start the broker).

## 3. Questions that block Group 1

| # | Question | Options | Group 2 recommendation |
|---|---|---|---|
| **Q0** | Does the north star (#13, 6402306556) supersede the old out-of-scope list (daemon, cross-app auth)? Does `AGENTS.md` need to change? | yes / no / only as research | Yes as research up to P4; product status only after P6 |
| **Q1** | Which client identity is required? | (a) kernel pid → executable path match (spike); (b) + Authenticode/codesign signer check; (c) Windows package identity (MSIX family name); (d) broker-launched clients with inherited handles (breaks R1) | (a)+(b) for release builds, (a) for dev; document the same-user residual (T-2) |
| **Q2** | Where does the registration manifest live, and who may write it? | per-user file; per-machine read-only (installer); signed manifest | Per-machine read-only from the installer; a per-user dev override behind a flag |
| **Q3** | Which data classes may enter the broker? | Public only; Public + App; more | Public + App, with App defined as a correctness boundary, not a security one ([03 §4](03-threat-model.md#4-residual-risk)); never user-private data |
| **Q4** | Who may invalidate Public keys and read stats? | any app with a grant; an admin app only | Admin-only for Public invalidation and stats; App-scope invalidation by the same app |
| **Q5** | Which platforms are required for P2? | Windows 10/11 only; + Linux; + macOS | Windows 10/11 first; Linux as dev/CI; macOS later (`getpeereid` + `proc_pidpath`) |
| **Q6** | Panic policy in the broker | keep `panic = "abort"` + crash recovery; separate profile; `catch_unwind` per op | Separate broker profile with `panic = "unwind"` + per-op isolation; Core's profile unchanged |
| **Q7** | Behaviour without a broker | in-process fallback per op; explicit "unavailable" | Fallback by default (it is also the plain arm) |
| ~~Q8~~ | Role of CPU in cross-app measurements | **Decided 2026-10-26: co-primary with RAM** (equal confirmatory metrics) | Applied in 05; #25 already uses one family of CPU + RAM tests |
| **Q9** | Wire format beyond the spike | JSON (spike); a binary codec; shared memory for large Public data (O4) | JSON until P4 shows copy cost matters |

## 4. What this package deliberately does not do

It does not merge, rebase or retarget anything, and it changes no existing branch. It posts no GitHub comments. It changes no Core/IPC/capability/security code. It runs no measurements. It does not decide Q0–Q9.
