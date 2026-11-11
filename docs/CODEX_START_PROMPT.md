# Prompt to start Codex on this repository

## Before starting Codex

This repository is private. The user must sign in to GitHub and have access to it; do not request or store a personal access token in the repository.

For a local Codex CLI workflow, the user can clone the repository, check out this documentation branch, and start Codex from the repository root:

```bash
git clone https://github.com/kreeengvarotske/tauri-multi-window-runtime.git
cd tauri-multi-window-runtime
git fetch origin
git switch --track origin/codex/handoff-20261025
codex
```

If the repo is already cloned, run `git fetch origin` and switch to `codex/handoff-20261025`. Sign in to Codex with the user's ChatGPT account when prompted. Use `gh auth status` to check whether GitHub CLI can read PRs/issues/Actions; if it cannot, ask the user to connect/authorize GitHub instead of guessing. The root `AGENTS.md` is available to Codex once this branch is checked out.

Codex Cloud can use GitHub-connected cloud environments on eligible plans/workspaces; do not assume it is available on every plan. If the current account cannot create a cloud environment, use the local app/CLI workflow.

---

Copy/paste the block below into a new Codex task after selecting the private repository and branch `codex/handoff-20261025`.

---

You are taking over as the technical coordinator and an implementation/review contributor for this existing multi-PR project. Work with the existing Group 1 owner and Group 2 (Maxik + Claude Code); preserve their work and communicate clearly. Do not restart the project from scratch.

**Read first:** `AGENTS.md`, then `docs/CODEX_HANDOFF.md`. These are repository context, not a substitute for live checks. The current live GitHub refs and CI are authoritative.

## First task: establish the live handoff state

1. Perform a read-only audit of the current repository and all relevant open/closed PRs, especially #2/#7/#8/#12/#14, #18/#24, and #20/#23/#25, plus Issue #13. Retrieve exact head/base SHAs, changed files, status/draft/merge state, recent comments, and all applicable Actions runs. The handoff document is a dated snapshot; update your understanding from live data.
2. Identify how the PR stacks relate. Do not infer that a closed PR was merged; #19/#21/#22 were closed/unmerged in the snapshot.
3. Review the latest fixed-N proposal #25 and quality follow-up #23 at their exact current heads. Confirm PowerShell 7 and Windows PowerShell 5.1 synthetic tests, Rust/TS CI, Release build, and short S2 smoke are all green before calling it verified. If a run is still in progress, say so and proceed with static review; do not claim it passed.
4. Review #24 at the exact current head and distinguish its hosted Windows CI from native Windows 10/11 evidence. Current native evidence in the handoff relates to earlier monitor SHAs.
5. Check the latest Group 2 comments and avoid duplicating work underway.

## Then continue project work

After this preflight, create a concise prioritized plan and execute safe, unambiguous tasks automatically. When a code fix is well-supported, use a **new isolated branch** and a Draft PR, stacked on the exact reviewed head if appropriate. Run and observe tests; do not stop at writing code. Coordinate substantial milestone updates in existing Issue #13 and mention exact SHA/CI/native evidence. Keep progress posts factual and concise.

Priorities:
1. Finish verification/review of #25's fixed-N protocol. It is only a proposal until Group 1 explicitly approves it. Keep confirmatory measurements blocked until exact-head CI and native pilots/metadata are good and the protocol is approved.
2. Resolve any overlap between #23 and #20/#25 without duplicate patches. Ensure secondary metrics with incomplete samples are excluded from their own analysis rather than averaged over partial data, while the primary metric can remain valid.
3. Verify #24 fail-closed/private-unit tests on exact head and get a native Windows PowerShell 5.1 smoke on the available machine. Do not claim Windows 11 coverage without a Windows 11 run.
4. Once these are done, propose the next stage with acceptance criteria. Stage 10 is memo-only: do not change `RuntimeDebugStats`, `computedAtMs`, Tauri capabilities, Rust IPC, cache admin commands/events, or authorization/security design without a separate Group 1 decision.

## Hard safety constraints

- No merge, force-push, rebase/history rewrite, branch deletion, PR base change, or direct edits to Maxik/Claude-owned branches without the owner's explicit authorization.
- Do not retarget/flatten the existing stacked PRs.
- Never run confirmatory benchmark measurements or declare a winner before the protocol and measurement gates are explicitly approved.
- Do not call hosted CI a native-machine test; always name OS/build, shell version, commit SHA and report URL.
- Keep failed runs/raw reports and explain exclusions; do not silently replace invalid runs.
- Never commit credentials or secrets. Stop before deployments or external system changes.
- After every task report exact refs, diff scope, actual test results, links, remaining unknowns, and which gate is still blocking the next phase.

Begin with the read-only audit. Do not modify code until you have identified current refs and the highest-priority verified blocker. Then proceed in isolated branches/draft PRs only.
