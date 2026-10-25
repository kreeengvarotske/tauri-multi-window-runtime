# Windows Process-Tree Resource Monitor

This directory contains a PowerShell script for sampling a Windows application's resource usage. It records the target process and its discoverable child processes to CSV, supporting repeatable baseline measurements of Tauri and Electron applications.

## Metrics

"MB" in column names means 2^20 bytes (PowerShell `1MB`, i.e. MiB).

- `WorkingSetMB` — the **sum of the working sets** (`Win32_Process.WorkingSetSize`) of the included processes. Pages shared between processes (DLLs, shared memory, WebView2 shared sections) are counted once per process that has them resident, so this is not the amount of unique physical RAM the application uses. Use it as a footprint of the listed PIDs, always together with `ProcessTree`.
- `PrivateBytesMB` — sum of `Win32_Process.PrivatePageCount` of the included processes, divided by 2^20. Despite its name, `PrivatePageCount` is in **bytes**: on Windows 10 22H2 (build 19045) with Windows PowerShell 5.1 it equalled `Get-Process` `PrivateMemorySize64` and `PageFileUsage × 1024` for all 9 sampled processes (median ratio 1.000000 idle and under load; the "pages" hypothesis gives 4096). The raw comparison is published in issue #13. Private bytes are committed memory that no other process shares, including pages that are not currently resident, so they are not a subset of the working set. The script re-checks the unit at startup (see below).
- `CpuPercentAllCores` — `CpuDeltaSeconds` divided by the elapsed time and by the number of logical CPUs, as a percentage (0–100%, clamped). On a 16-logical-CPU system one fully busy core is 6.25%. The first sample is blank because a previous sample is needed to calculate a delta.
- `CpuDeltaSeconds` — sum over the included processes of the increase in `Get-Process` `TotalProcessorTime` (user + kernel) since the previous sample. Only processes present in both samples contribute, so CPU used by a process that started or exited between two samples is not counted for that interval. It is empty, like `CpuPercentAllCores`, when no process of the row had readable CPU time in both samples, so an unknown value never looks like a real zero. Sum `CpuDeltaSeconds` over a run to get total CPU seconds.
- `PrivateMissingCount`, `CpuUnreadableCount` — how many processes of the row were left out of `PrivateBytesMB` or `CpuDeltaSeconds` because `PrivatePageCount` was empty or `Get-Process` could not read the process (it exited after the snapshot, or access was denied). A missing value is never counted as zero silently: a non-zero count means that row's sum is low, and the script prints a warning at the end. If `Win32_Process` itself cannot be queried (WMI error), the script stops with that error; the rows written so far stay in the CSV.
- `ProcessCount`, `ProcessIds`, `ProcessTree` — processes included in each sample.
- `Timestamp`, `ElapsedSeconds`, `IntervalSeconds` — sample timing: `Timestamp` is the wall clock at the start of the sample, `ElapsedSeconds` the stopwatch after the processes were read.

## Which processes are included

The script walks `ParentProcessId` from the root process. This finds the WebView2 browser process and its children (GPU, renderers, utility) when they are descendants of the app. It cannot see processes that are not descendants: a process whose parent exited is reparented to nothing, and a WebView2 browser shared with another app is not counted. A reused PID can also attach an unrelated process. Before treating a sum as the application's total, check `ProcessTree`, or run with `-Diagnostics` (below), which lists WebView2 processes started for this executable that the walk missed.

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

At startup the script compares `PrivatePageCount` with `Get-Process` `PrivateMemorySize64` for every process in the tree and prints the median ratio. If it is outside 0.9–1.1, the script stops instead of writing wrong `PrivateBytesMB` values. It also stops if no finite valid ratio can be computed (for example, because process-memory access is denied or all candidate values are zero/missing); an unverified unit must not be presented as a verified measurement. The validation logic is isolated in `PrivateUnitValidation.psm1` so the empty-input and wrong-unit paths can be tested without relying on OS-specific protected processes.

Run the deterministic PowerShell 5.1 regression checks with:

```powershell
.\Test-PrivateUnitValidation.ps1
```

The test covers an empty ratio list, a list containing only non-finite values, and ratios consistent with a page-count rather than byte-count interpretation. These are unit tests for fail-closed behavior; they do not replace a native end-to-end monitor run.

Add `-Diagnostics` to also write `<output>.diagnostics.csv` (or `-DiagnosticsPath`), with one row per process per sample:

```powershell
.\Measure-ProcessTree.ps1 -RootPid 12345 -DurationSeconds 60 -Diagnostics -OutputPath .\tauri-runtime.csv
```

Columns: `Pid`, `ParentPid`, `Name`, `InTree`, `CimWorkingSetSize`, `CimPrivatePageCount`, `CimPageFileUsageKB`, `ProcPrivateMemorySize64`, `ProcWorkingSet64`, `ProcTotalProcessorSeconds`, `RatioPrivatePageCountToPrivateMemorySize64`. Rows with `InTree=False` are WebView2 processes whose command line names this executable (`--webview-exe-name=`) but which are outside the `ParentProcessId` tree; they are not in the main CSV's sums. At the end the script prints the median ratio and any such processes. The CIM and `Get-Process` values are read a few milliseconds apart, so a process whose memory is changing can show a ratio slightly different from 1. Diagnostics read each process's command line and are slower; use them for checks, not for the measured runs.

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
