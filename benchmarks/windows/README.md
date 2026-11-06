# Windows Process-Tree Resource Monitor

This directory contains a PowerShell script for sampling a Windows application's resource usage. It records the target process and its discoverable child processes to CSV, supporting repeatable baseline measurements of Tauri and Electron applications.

## Metrics

"MB" in column names means 2^20 bytes (PowerShell `1MB`, i.e. MiB).

- `WorkingSetMB` — the **sum of the working sets** (`Win32_Process.WorkingSetSize`) of the included processes. Pages shared between processes (DLLs, shared memory, WebView2 shared sections) are counted once per process that has them resident, so this is not the amount of unique physical RAM the application uses. Use it as a footprint of the listed PIDs, always together with `ProcessTree`.
- `PrivateBytesMB` — sum of `Win32_Process.PrivatePageCount` of the included processes, divided by 2^20. Despite its name, `PrivatePageCount` is in **bytes**: on Windows 10 22H2 (build 19045) with Windows PowerShell 5.1 it equalled `Get-Process` `PrivateMemorySize64` and `PageFileUsage × 1024` for all 9 sampled processes (median ratio 1.000000 idle and under load; the "pages" hypothesis gives 4096). The raw comparison is published in issue #13. Private bytes are committed memory that no other process shares, including pages that are not currently resident, so they are not a subset of the working set. The script re-checks the unit at startup (see below).
- `CpuPercentAllCores` — `CpuDeltaSeconds` divided by the elapsed time and by the number of logical CPUs, as a percentage (0–100%, clamped). On a 16-logical-CPU system one fully busy core is 6.25%. The first sample is blank because a previous sample is needed to calculate a delta.
- `CpuDeltaSeconds` — CPU time (user + kernel, the value `Get-Process` reports as `TotalProcessorTime`) used by the included processes since the previous sample. It is read through a process handle that the script opens once per process identity and holds until the process leaves the tree (`ProcessCpuTracker.psm1`). Each process contributes its increase since its last read. A process that exited since the previous sample contributes its final CPU time minus its last read: the held handle keeps the exited process object, so the final value stays readable and its PID cannot be reused meanwhile. A process seen for the first time contributes its whole CPU time if it was created after the previous snapshot started (all of it falls in this interval); otherwise, as at sample 0, its first read is only the baseline. It is empty, like `CpuPercentAllCores`, when no process of the row had a CPU value to compare, so an unknown value never looks like a real zero. Sum `CpuDeltaSeconds` over a run to get total CPU seconds.
- `PrivateMissingCount`, `CpuUnreadableCount` — how many processes of the row were left out of `PrivateBytesMB` or `CpuDeltaSeconds` because a value could not be read. A missing value is never counted as zero silently: a non-zero count means that row's sum is low, and the script prints a warning at the end. `CpuUnreadableCount` is the sum of these reasons, each with a `…Count` and a `…Ids` column:
  - `CpuExitedUnread` — the process was in the snapshot but no process with its PID existed when the handle was opened: it exited, and nothing kept its process object, before its CPU time was first read.
  - `CpuAccessDenied` — the handle could not be opened for lack of access.
  - `CpuIdentityChanged` — the PID already names a process with a different creation time: the original exited and its PID was reused.
  - `CpuLeftTree` — a process with a held handle is still running but the `ParentProcessId` walk no longer reaches it (an intermediate parent exited).
  - `CpuReadError` — any other failure, including a CPU time lower than the last read.
- `CpuExitedReadCount`/`Ids`, `CpuNewCountedCount`/`Ids` — counted in `CpuDeltaSeconds`, not missing: processes that exited since the previous sample and were read through their held handle, and new processes whose whole CPU time was counted. If `Win32_Process` itself cannot be queried (WMI error), the script stops with that error; the rows written so far stay in the CSV.
- `ProcessCount`, `ProcessIds`, `ProcessTree` — processes included in each sample.
- `ProcessKeys` — the identity of each included process, `PID@creation time` (UTC ticks). Windows reuses PIDs; two processes with the same PID at different times have different keys. CPU deltas are taken per key, so the CPU time of a new process is never subtracted from that of an earlier one with the same PID.
- `RejectedPidReuseCount`, `RejectedPidReuseIds` — processes whose `ParentProcessId` points at a process of the tree but which were created **before** it. Their parent was an earlier process with the same PID, so they are not descendants and are left out (see below).
- `UnverifiedProcessCount`, `UnverifiedProcessIds` — processes whose `ParentProcessId` points into the tree but whose creation time cannot be read. They are left out of the sums, together with anything below them. A non-zero value means the tree of that row may be incomplete; an analysis must not treat such a row as complete.
- `Timestamp`, `ElapsedSeconds`, `IntervalSeconds` — sample timing: `Timestamp` is the wall clock at the start of the sample, `ElapsedSeconds` the stopwatch after the processes were read.

## Which processes are included

The script walks `ParentProcessId` from the root process. This finds the WebView2 browser process and its children (GPU, renderers, utility) when they are descendants of the app.

A process is identified by PID **and** creation time (`Win32_Process.CreationDate`). A child is kept only if it was created no earlier than the process it names as parent. This removes reused PIDs exactly: a live process created before the child held that PID when the child was created, so it is the child's real parent; a process created after the child cannot be its parent. On the #36 smoke (2026-10-27) the PID-only walk attached a running Edge browser (5 processes, about 176 MB) because Edge's parent PID equalled a PID of the app's tree; Edge was created hours earlier and is now rejected. The root is checked the same way: if its PID is reused after it exits, measurement stops. A `Get-Process` object is used for `PrivateMemorySize64` only if its start time matches the snapshot's creation time (within 1 s). The CPU handle is opened only if the creation time it reports matches the snapshot within 1 ms; otherwise the reason is `CpuIdentityChanged`.

Limits: a process whose parent exited is reparented to nothing and is not found; a WebView2 browser shared with another app is not counted; a process that starts and exits between two samples is never seen, so its memory and CPU are missing from every row. Before treating a sum as the application's total, check `ProcessTree`, `UnverifiedProcessCount`, or run with `-Diagnostics` (below), which lists WebView2 processes started for this executable that the walk missed.

## Requirements

- Windows 10 or 11. Verified on Windows 10 22H2 (build 19045) with Windows PowerShell 5.1.19041; not yet verified on Windows 11 or PowerShell 7.
- Windows PowerShell 5.1 or a compatible PowerShell version
- No third-party modules

## Run by process name

Start the application first. Open PowerShell in this directory and run:

```powershell
.\Measure-ProcessTree.ps1 -ProcessName "tauri-multi-window-runtime" -DurationSeconds 300 -SampleIntervalSeconds 1 -OutputPath .\tauri-runtime.csv
```

The executable name shown above is an example. Replace it with the actual executable name, without `.exe`.

If multiple processes have the same name, the script asks you to specify a PID. Find it in Task Manager → Details, or run:

```powershell
Get-CimInstance Win32_Process |
    Where-Object { $_.Name -like "*tauri*" } |
    Select-Object ProcessId, ParentProcessId, Name
```

## Run by PID

```powershell
.\Measure-ProcessTree.ps1 -RootPid 12345 -DurationSeconds 300 -SampleIntervalSeconds 1 -OutputPath .\tauri-runtime.csv
```

Replace `12345` with the PID of the application's main process.

## Unit check and diagnostics

At startup the script compares `PrivatePageCount` with `Get-Process` `PrivateMemorySize64` and stops instead of writing wrong `PrivateBytesMB` values if the median ratio is outside 0.9–1.1.

The two values are read milliseconds apart. While a process is growing, as WebView2 processes do in their first seconds, the ratio is far from 1 even though both are bytes: the #36 smoke saw 0.87, 0.80 and 0.51 at startup and stopped in 8 of 20 runs. So a process is used for the check only when both of its values changed by at most 1 % since the previous sample of the same process (same identity). Sampling starts at once; the check runs on every sample until some process of the tree is stable, and decides on the first such sample.

With `-UnitCheckRequireChildName <name>` the check waits until at least one stable process of that name other than the root is among the stable ones, so it cannot pass on the root process alone; all stable ratios, the root's included, still decide. The catalog Scenario M passes `msedgewebview2.exe`, so its unit is verified on a WebView2 process, whose memory is what the scenario measures. The default (no name) is unchanged for other uses of the monitor. The outcome is:

- median of the stable ratios in 0.9–1.1: the unit is bytes; the rows held so far are written and sampling continues normally;
- median outside 0.9–1.1: a real unit mismatch; the script stops (exit code 1) and writes no measurement;
- no stable process (or, with `-UnitCheckRequireChildName`, no stable child of that name) within `-UnitCheckTimeoutSeconds` (default 30), or the root exits first: the unit is unverified; the script stops (exit code 1) and writes no measurement.

The acceptance band is unchanged. Until the check passes, rows are kept in memory, so `OutputPath` never holds an unverified value, and sampling from the first second is kept for a run that passes. Every evaluated process and sample (both values, the previous values, `IsRoot`, `Stable`, `Ratio`) is written to `<output>.unitcheck.csv` (or `-UnitCheckPath`), also when the check fails. The logic is in `PrivateUnitValidation.psm1` (`Get-StablePrivateUnitRatios`, `Select-PrivateUnitRatios`, `Get-VerifiedPrivateUnitRatio`) and `ProcessTreeIdentity.psm1`.

Run the deterministic regression checks (Windows PowerShell 5.1 and PowerShell 7) with:

```powershell
.\Test-PrivateUnitValidation.ps1
.\Test-ProcessTreeIdentity.ps1
.\Test-ProcessCpuTracker.ps1
```

`Test-PrivateUnitValidation.ps1` covers an empty ratio list, a list containing only non-finite values, and ratios consistent with a page-count rather than byte-count interpretation. `Test-ProcessTreeIdentity.ps1` uses synthetic snapshots: a WebView2 child that appears late, a PID reused by a process created before its claimed parent (the Edge case), a reused root PID, a child with unknown creation time, a short-lived child that is really in the tree, growing processes at startup (no false unit failure), and stable processes with a real unit mismatch (still a failure). These test the decision logic; they do not replace a native end-to-end monitor run.

`Test-ProcessCpuTracker.ps1` checks the CPU tracker with fake handles (any OS): increases per process, a new child counted whole, an exit read through a held handle, the #36 re-smoke race (a child seen once that exits before its first read, with and without another handle keeping its object), access denied, a reused PID, an older process first seen late, a process that leaves the tree alive, failed and decreasing reads, and closing all handles. It also checks the child requirement of the unit check: not ready on the root alone or on a child of another name, ready on a stable WebView2 child, still failing on wrong units. On Windows it also opens real handles: its own process (CPU matches `Get-Process`), a wrong creation time, a child that exits while its handle is held (final CPU read; `Get-Process` no longer finds it), and an exited child with no handle.

`Test-MonitorEndToEnd.ps1` runs the monitor itself, in a fresh PowerShell process per case, on a real `cmd.exe`/`ping` tree:
- unchanged: exit 0, identities recorded, root identity constant, nothing rejected or unverified;
- a controlled wrong unit (`PrivatePageCount` divided by 4096 on real, stable processes): exit 1, no measurement CSV, unit-check CSV kept;
- memory that never stabilizes, with a 3 s timeout: exit 1, no measurement CSV, unit-check CSV kept with no stable row;
- an injected process that names the root as parent but is 3 h older (PID reuse): rejected in every row and not summed;
- an injected child with no creation time: reported as unverified in every row and not summed;
- a child that exits during the run: its final CPU is read through the held handle, the next child is counted from its start, nothing unreadable;
- an injected tree process with a PID that does not exist: `CpuExitedUnread` in every row;
- an injected tree process whose PID is a real process with another creation time: `CpuIdentityChanged` in every row;
- `-UnitCheckRequireChildName PING.EXE`: passes on the stable `ping` child; with `msedgewebview2.exe` (absent) and a 3 s timeout: exit 1, no measurement CSV, unit-check CSV kept; with the wrong-unit wrapper: exit 1.

The controlled cases wrap the real `Get-CimInstance` in the child process and change one value; the real CIM instances are not modified. CI runs this script in Windows PowerShell 5.1 and PowerShell 7; run it on the measurement machine as the native check.

Add `-Diagnostics` to also write `<output>.diagnostics.csv` (or `-DiagnosticsPath`), with one row per process per sample:

```powershell
.\Measure-ProcessTree.ps1 -RootPid 12345 -DurationSeconds 60 -Diagnostics -OutputPath .\tauri-runtime.csv
```

Columns: `Pid`, `ProcessKey`, `ParentPid`, `Name`, `InTree`, `CimWorkingSetSize`, `CimPrivatePageCount`, `CimPageFileUsageKB`, `ProcPrivateMemorySize64`, `ProcWorkingSet64`, `ProcTotalProcessorSeconds`, `RatioPrivatePageCountToPrivateMemorySize64`, `CpuState`. For tree processes `ProcTotalProcessorSeconds` is the cumulative CPU time read through the held handle and `CpuState` is `Running`, `Exited` or one of the reasons above; when a process exits, one more row with `CpuState=Exited`, its final CPU time and empty memory columns is written, so the last row of each `ProcessKey` holds its total CPU time. Rows with `InTree=False` are WebView2 processes whose command line names this executable (`--webview-exe-name=`) but which are outside the `ParentProcessId` tree; they are not in the main CSV's sums. At the end the script prints the median ratio and any such processes. The CIM and `Get-Process` values are read a few milliseconds apart, so a process whose memory is changing can show a ratio slightly different from 1. Diagnostics read each process's command line and are slower; use them for checks, not for the measured runs.

## If PowerShell blocks script execution

You can allow locally created scripts in the current PowerShell process only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

This does not permanently change the system execution policy.

## Rules for fair comparisons

- Use the same duration and sampling interval for vanilla Tauri, Tauri + runtime, and Electron.
- Compare Release builds; do not mix Debug and Release builds.
- Start each run from the same state: same number of windows, same operations, and the same warm-up period.
- Do not open DevTools for one variant if they are closed for the others.
- Keep debug-stats polling consistent. Prefer an initial run with periodic stats polling disabled, followed by a separate run where all variants use the same polling frequency.
- Run each scenario at least five times and save each run as a separate CSV file.
- This script discovers child processes using Windows `ParentProcessId`. Some WebView2 or Electron broker/service processes may not be descendants of the main process and may be omitted. Inspect `ProcessTree` in the CSV. If relevant processes are missing, do not treat the sum as the application's complete memory usage; extend collection to group processes by command line or application profile identifier.
- The sampler compensates for its collection and CSV-write overhead when scheduling the next sample. `SampleIntervalSeconds` accepts fractional seconds down to 0.1 (for example, `-SampleIntervalSeconds 0.2`). The default remains 1 second. Real intervals may still vary because of Windows scheduling and the time needed to query each process; inspect `IntervalSeconds` in every run. If sampling itself takes longer than requested, the effective cadence will be slower than requested.
- Use 0.1–0.25 s only as a separate, higher-frequency RAM-peak profile for short-lived allocations. It improves the chance of observing brief peaks but cannot guarantee that every peak is captured. Faster sampling can increase WMI/PowerShell overhead and affect CPU measurements; do not mix these CPU numbers with a 1-second profile. For the main CPU comparison, use a common interval with acceptable measured overhead for both variants.
- This is a first-pass comparison tool, not a replacement for Windows Performance Recorder/ETW. Sampling introduces overhead, which can be material at short intervals.

## Inspect recent samples

```powershell
Import-Csv .\tauri-runtime.csv |
    Select-Object -Last 10 |
    Format-Table Timestamp, ProcessCount, WorkingSetMB, PrivateBytesMB, CpuPercentAllCores
```

## Summarize a run

The CSV uses an invariant decimal point (for example, `380.69`) regardless of the Windows display language. Keep the explicit invariant-culture parsing below when calculating numeric summaries; `Import-Csv` returns text values.

```powershell
$data = Import-Csv .\tauri-runtime.csv
$culture = [System.Globalization.CultureInfo]::InvariantCulture

$workingSet = @($data | ForEach-Object {
    [double]::Parse($_.WorkingSetMB, $culture)
})
$privateBytes = @($data | ForEach-Object {
    [double]::Parse($_.PrivateBytesMB, $culture)
})
$cpu = @($data |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_.CpuPercentAllCores) } |
    ForEach-Object { [double]::Parse($_.CpuPercentAllCores, $culture) })
$intervals = @($data | ForEach-Object {
    [double]::Parse($_.IntervalSeconds, $culture)
})

[pscustomobject]@{
    Metric = 'WorkingSetMB'
    Count = $workingSet.Count
    Average = ($workingSet | Measure-Object -Average).Average
    Maximum = ($workingSet | Measure-Object -Maximum).Maximum
}
[pscustomobject]@{
    Metric = 'PrivateBytesMB'
    Count = $privateBytes.Count
    Average = ($privateBytes | Measure-Object -Average).Average
    Maximum = ($privateBytes | Measure-Object -Maximum).Maximum
}
[pscustomobject]@{
    Metric = 'CpuPercentAllCores'
    Count = $cpu.Count
    Average = ($cpu | Measure-Object -Average).Average
    Maximum = ($cpu | Measure-Object -Maximum).Maximum
}
[pscustomobject]@{
    Metric = 'IntervalSeconds'
    Count = $intervals.Count
    Average = ($intervals | Measure-Object -Average).Average
    Maximum = ($intervals | Measure-Object -Maximum).Maximum
}
```

The CPU percentage is blank for the first sample and can also be blank when CPU-time deltas cannot be calculated. The CPU summary excludes blank values. Parse decimal values with `InvariantCulture` rather than relying on the Windows regional settings.
