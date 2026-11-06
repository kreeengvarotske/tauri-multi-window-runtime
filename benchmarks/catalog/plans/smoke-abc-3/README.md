# Plan: third native A/B/C smoke of scenario M (not run)

Written before the run, for review on #36 (decision 6687069270). Nothing in
this directory is a result. The run waits for that review.

Why: the second smoke (scenario `5c05f6c`, monitor `1d967e0`, 2026-10-28)
gave 11/12 valid runs. The invalid run, `N4D64-t01-p3-C`, lost the CPU time
of a WebView2 child that exited between the monitor's snapshot and its
`Get-Process` read. The gate stays open. This smoke repeats the full A/B/C
set on the final scenario/monitor pair; a C-only repeat or a recount of the
old data does not replace it, and the old results stay as they are.

## Fixed before the run

| | |
|---|---|
| Scenario (#36) | final head after review, **to be filled in before the run** |
| Monitor (#43) | final head after its native check, **to be filled in before the run** (`167a67d` or later) |
| Phase | `Smoke` |
| Cells | `N2D0`, `N2D16`, `N2D64`, `N4D64` (as the 2026-10-28 smoke) |
| Arms | `A`, `B`, `C` |
| Triplets | 1 per cell (12 runs) |
| Schedule seed / data seed | 1 / 1 (as the 2026-10-28 smoke) |
| Phases | runner defaults: idle-before 20 s, warm-up 30 s, load 120 s, idle-after 30 s, pause 30 s, step 500 ms |
| Sampling | 1 s, `-Diagnostics`, `-UnitCheckRequireChildName msedgewebview2.exe` (set by the runner) |
| Schedule | `schedule.csv` in this directory, SHA-256 `bf9dbdae30a3b7ec59311cf90eaa622ffa854b6e2ed227d142a5260aaa2575cc` as committed (UTF-8, LF). A checkout with CRLF line endings has another hash; the runner compares the content, and `configuration.json` records the hash of the file it read. |
| Output | a new directory, e.g. `tmwr-results\<date>\smoke-abc-<scenario>-mon<monitor>`; never an existing one |
| Duration | ≈ 12 × (204–209 s + 30 s) ≈ 47–48 min, from the 2026-10-28 smoke, plus the build |

Command (Windows PowerShell 5.1, from `benchmarks\catalog`):

```powershell
.\scripts\Run-CatalogTriplets.ps1 -Phase Smoke -Arms A,B,C -Cells N2D0,N2D16,N2D64,N4D64 -Triplets 1 -ScheduleSeed 1 -DataSeed 1 `
  -ExpectedSchedule .\plans\smoke-abc-3\schedule.csv `
  -MonitorScript <monitor worktree>\benchmarks\windows\Measure-ProcessTree.ps1 `
  -OutputDirectory <new results directory>
.\scripts\Summarize-CatalogRuns.ps1 -ResultsDirectory <new results directory>
```

`-ExpectedSchedule` makes the runner stop before building if its schedule
differs from this file. `configuration.json` records the scenario and
monitor SHAs, the hashes of every script and executable, and this file's
hash.

## Gate (unchanged rules, #36 6474468768 and 6687069270)

- The gate passes only if all 12 runs are valid under protocol §7 as
  implemented by the summarizer at the scenario SHA, or each remaining
  invalid run has a proven cause independent of the arm and the load,
  submitted for separate review.
- A missing CPU value is never counted as zero: any `CpuUnreadableCount` > 0
  in the measured interval leaves that run invalid, with its reason.
- Old smoke results (2026-10-27, 2026-10-28) are kept and reported, not
  replaced.
- No pilot or confirmatory run follows from this smoke without separate
  decisions.
