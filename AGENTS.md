# Repository instructions for Codex and coding agents

## Project and collaboration model

This is `kreeengvarotske/tauri-multi-window-runtime`, a staged Tauri/Rust project. The team works in two groups: Group 1 owns architecture decisions and independent review; Group 2 (Maxik + Claude Code) implements and tests. Codex is a new collaborator, not a reason to discard either group's work.

Start every task with a read-only preflight:
1. Read this file and `docs/CODEX_HANDOFF.md`.
2. Fetch the live default branch, open PRs, Issue #13, PR head/base SHAs, changed files and CI runs.
3. Treat the live GitHub repository and exact commits as the source of truth. Handoff documents are dated snapshots and may be stale.
4. Report the current state and any overlaps with existing PRs before making changes.

## Git and review safety — required

- Never merge a PR, force-push, rewrite history, rebase another person's branch, change an existing PR base, delete a branch, or close a PR unless the user explicitly authorizes that exact action.
- Do not push edits directly to `main` or to a branch owned by Maxik/Claude. Use a new, isolated branch and an open **Draft PR**. For an intentionally stacked PR, use the exact reviewed HEAD of its parent as the base and record both SHAs.
- Do not duplicate or automatically port an open PR. Compare its current diff and comments first; coordinate in Issue #13 when appropriate.
- Do not claim tests, CI, native Windows runs, or Codex actions succeeded unless there is an exact-head result/link. Clearly separate source inspection, hosted CI, and native-machine evidence.
- Keep experimental/raw benchmark outputs and failed runs. Never silently omit a failed/incomplete pair or replace an invalid run.
- Never run confirmatory benchmark measurements while the protocol is unapproved, CI is failing/incomplete, or required quality checks are unverified.
- Do not publish results or declare a benchmark winner from a pilot.
- GitHub comments are project-visible messages. Only post progress/coordination comments when the user has delegated that communication or requested it; keep them factual and non-duplicative.
- Never disclose or commit tokens, credentials, signing keys, personal data, or local secrets. Do not modify repository secrets or external service configuration.

## Architecture boundaries

- The runtime is an in-process Tauri runtime shared by multiple WebView windows in the same application process. Do not describe it as a daemon shared between independent applications.
- Runtime Core/cache/coalescing, frontend/IPC integration, and benchmark harnesses live in different PR stacks. Respect those stacks and their exact bases.
- Stage 10 (debug stats, `computedAtMs`, admin cache commands/events and permissions) is analysis/memo only until Group 1 explicitly approves an architecture decision.
- Authentication and authorization for private event/data flows are unresolved design questions. Window labels are not an authorization boundary; default Tauri capabilities may allow broad event operations. Do not change capabilities, Rust IPC contracts, security model, or private-data event behavior without explicit approval.
- Keep the existing API and serialized DTO contracts stable unless a task explicitly authorizes a contract change.

## Verification and reporting

For Rust, use the repository/workspace commands actually present at the target ref; at minimum inspect `Cargo.toml`, `Cargo.lock`, and CI workflow before running commands. The root `main` can lag stacked PRs, so do not assume benchmark or frontend files exist on `main`.

For the symmetric benchmark, report exact source SHA, monitor SHA, OS/build, WebView2, PowerShell version, configuration, run order, every pair including failures, actual sample intervals, missing-data counters, monitor CPU overhead, and the CI/native report links. Treat `LoadPrivateMBMaxSample` as the maximum among captured samples, not the guaranteed true memory peak.

For every code change, provide:
- files changed and reason;
- exact base/head SHA;
- commands actually run and exit results;
- CI/native links and environment;
- what remains unverified;
- whether changes overlap with open PRs.

Stop after the requested task/phase. Do not automatically move to another architectural stage or merge your own work.
