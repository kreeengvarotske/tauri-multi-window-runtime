# Windows Process-Tree Resource Monitor

This directory contains a PowerShell script for sampling a Windows application's resource usage. It records the target process and its discoverable child processes to CSV, supporting repeatable baseline measurements of Tauri and Electron applications.

## Metrics

- `WorkingSetMB` — sum of working sets for included processes (memory currently resident in physical RAM).
- `PrivateBytesMB` — sum of private memory for included processes. Review it alongside Working Set when comparing variants.
- `CpuPercentAllCores` — approximate CPU usage normalized to the total capacity of all logical CPUs (0–100%). The first sample is blank because a previous sample is needed to calculate a delta.
- `ProcessCount`, `ProcessIds`, `ProcessTree` — processes included in each sample.
- `Timestamp`, `ElapsedSeconds`, `IntervalSeconds` — sample timing information.

## Requirements

- Windows 11
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
- The sampler compensates for its collection and CSV-write overhead when scheduling the next sample. Real intervals may still vary because of Windows scheduling, so inspect `IntervalSeconds` in every run.
- This is a first-pass comparison tool, not a replacement for Windows Performance Recorder/ETW. Sampling introduces a small amount of overhead, so avoid excessively short intervals.

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
