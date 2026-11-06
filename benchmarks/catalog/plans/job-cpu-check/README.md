# Plan: short native check of the job CPU runner (not run)

Written before the run, for review on #45 (comment 6693108403) together
with the §7 draft in #46. Nothing in this directory is a result. This is
**not** the smoke: one N4D64 triplet with short phases, no schedule file, no
pilot or confirmatory phase. The full smoke and the pilot wait for their own
review.

## Fixed before the run

| | |
|---|---|
| Scenario (#45) | the #45 head that contains this file, after its hosted CI is green, checked out clean in a new worktree; recorded as `gitHead`, `gitDirty` false |
| Monitor (#43) | `c5a4f16b54fb4c14dc79c21a2d52d227fc0dfff9`, the existing clean worktree; recorded as `monitorGitHead` and `monitorSha256` |
| Executables | `bin\arm-A.exe`, `arm-B.exe`, `arm-C.exe` of smoke 3 (`smoke-abc-7e98440-monc5a4f16`), copied with `-ExecutablesFrom`. #45 changes no app source since `7e98440` (`git diff 7e98440 <head> -- benchmarks/catalog/src benchmarks/catalog/src-tauri crates Cargo.lock` is empty); their SHA-256 is recorded in `configuration.json` and compared with smoke 3's |
| Machine | Maxim's PC, Windows 10 22H2 (19045), Windows PowerShell 5.1, no elevation |
| Output | a new directory `tmwr-results\<date>\job-cpu-check-<scenario sha>`; nothing existing is touched |
| Duration | ≈ 10 min of tests + ≈ 3 × (≈ 75 s + 10 s pause) ≈ 15 min in total |

## Steps (Windows PowerShell 5.1, from `benchmarks\catalog`)

1. Pre-run checks, written to `precheck.txt`: both worktrees at the SHAs
   above with `git status --porcelain` empty; new output directory; no heavy
   process running.
2. Native job checks, 3 times:
   `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-CatalogJobCpu.ps1 -OutputPath <out>\job-checks-N.json`
   (completion, short process between samples vs a handle held from
   creation, failed assignment, foreign process, kill on close, **CPU after
   endedAt**, leftovers).
3. Script checks: `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-CatalogScripts.ps1`.
4. Runner end to end, one N4D64 triplet with short phases:
   ```powershell
   .\scripts\Run-CatalogTriplets.ps1 -Phase Smoke -Arms A,B,C -Cells N4D64 -Triplets 1 -ScheduleSeed 1 -DataSeed 1 `
     -IdleBeforeSeconds 5 -WarmupSeconds 10 -LoadSeconds 40 -IdleAfterSeconds 10 -PauseSeconds 10 `
     -ExecutablesFrom <smoke-abc-7e98440-monc5a4f16> `
     -MonitorScript <tmwr-pr43>\benchmarks\windows\Measure-ProcessTree.ps1 -OutputDirectory <out>\runner
   .\scripts\Summarize-CatalogRuns.ps1 -ResultsDirectory <out>\runner
   ```

## How each point is fixed and checked

- **The `endedAt` boundary.** `endedAt` is the app's own timestamp for the
  end of the idle-after phase (report `phases.endedAt`, UTC). The whole-run
  value is the job CPU at the last job row at or before it. CPU after it is
  never counted: synthetic case "artificial CPU after endedAt" (100 s added
  after the end, whole-run value unchanged) and native case 6 (a real busy
  loop after a boundary set in the idle part; whole-run ≤ 0.2 s while the
  job's final CPU is ≥ 0.5 s higher).
- **Age of the last CPU sample.** `JobEndGapSeconds` = `endedAt` minus the
  time of that row; it must be ≤ 0.5 s (rows every 250 ms). Reported per run
  with `JobMaxRowIntervalSeconds` (≤ 1 s up to the first row after the end)
  and `JobMaxClockDriftSeconds` (wall clock vs the runner's stopwatch, ≤ 0.1 s).
- **RAM, separately.** RAM keeps every check of its own on the monitor data
  (load coverage ≥ 80 %, median interval within 20 % of 1 s, no gap over 5 s,
  no unverified process in a load row, no WebView2 process of the app outside
  the tree, private memory complete in every load row). None of them reads
  job data, and the job checks never make a RAM failure pass. Synthetic case:
  a complete job and a missing private value give an invalid run for RAM only.
- **Failed assignment.** The runner stops that run before the app executes:
  the process is created suspended, the assignment fails, the process is
  terminated before any instruction, and `runs.log` records `jobError`;
  the summarizer marks the run invalid (`runner: …`). Native case 3.
- **A missing message.** The messages count only if complete (new-process
  messages = the job's total, exit messages = exited processes, an
  active-zero message). Otherwise membership is "not verified" and the run's
  CPU is invalid. Synthetic case "lost membership message".
- **Missing job artifacts.** With `cpuSource = job` in `configuration.json`
  a run without its job CSV or messages file is invalid, whatever its monitor
  data (#45 review 6692969411).
- **Leftover processes and timeouts.** Processes of the app still running
  30 s after it exits, or an app over the timeout: the runner terminates its
  own job (never a process by name or PID), records `jobTerminated` and
  `jobLeftoverProcesses`, and the run is invalid. Native case 7 (2 s grace
  in the test).

## Pass criteria (all, else the check fails and is reported as such)

1. Steps 2 and 3 pass in every repetition.
2. Step 4: three runs with exit code 0, `CpuSource = job` for all, every
   job check passing (end gap ≤ 0.5 s, row interval ≤ 1 s, drift ≤ 0.1 s,
   messages complete, every monitor-tree process a member, nothing left
   running, no termination by the runner), and the RAM checks evaluated as
   before. A run invalid for RAM is reported with its reason, not hidden.
3. Reported per run: `RunCpuSeconds` (job), `MonitorRunCpuSeconds`,
   `JobProcesses`, `JobProcessesNeverSeenByMonitor`, `MonitorCpuNotes`,
   `JobEndGapSeconds`.

## Stop conditions

- Any pre-run check fails: nothing is run.
- A test step fails: the runner step is not started.
- The runner stops by itself on a failed job creation or an existing
  output directory.
- Nothing is repeated or topped up after a failure; every file stays.

## After the check

The results and a proposal on readiness for **one** full A/B/C smoke on the
job runner (a new plan with its own schedule file, as for smoke 3) go to
#45/#36 for review. The full smoke and the pilot are not started from this
plan.
