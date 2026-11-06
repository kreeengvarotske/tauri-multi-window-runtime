<#
.SYNOPSIS
Runs built arms of scenario M briefly in a job, exactly as the runner does
(Invoke-CatalogJobRun), and checks the job's CPU accounting with the same
rules as the summarizer (Get-CatalogJobCpu). No monitor: membership is
checked for the app's own identity only.

.DESCRIPTION
For CI (Actions Windows Server, a build and correctness check, not a
measurement) and for a short native check. Writes the report, job.csv and
job.messages.csv per arm into -OutputDirectory (must be new). Exits 1 on a
failed check.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$Executable,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [int]$DataMib = 16,
    [int]$Windows = 2
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CatalogJobCpu.ps1')
$culture = [System.Globalization.CultureInfo]::InvariantCulture
if (Test-Path -LiteralPath $OutputDirectory) { throw "$OutputDirectory exists; use a new directory." }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$failures = New-Object System.Collections.Generic.List[string]
foreach ($exe in $Executable) {
    $exe = (Resolve-Path -LiteralPath $exe).Path
    $name = [System.IO.Path]::GetFileNameWithoutExtension($exe)
    $report = Join-Path $OutputDirectory "$name.json"
    $commandLine = '"{0}" --report "{1}" --data-mib {2} --windows {3} --idle-before 2 --warmup 3 --duration 10 --idle-after 2' -f $exe, $report, $DataMib, $Windows
    $run = Invoke-CatalogJobRun -Label $name -CommandLine $commandLine -WorkingDirectory $OutputDirectory `
        -Environment @{ WEBVIEW2_USER_DATA_FOLDER = (Join-Path $OutputDirectory "$name.profile") } -TimeoutSeconds 240 `
        -JobCsv (Join-Path $OutputDirectory "$name.job.csv") -JobMessagesCsv (Join-Path $OutputDirectory "$name.job.messages.csv") `
        -OnStarted { param($appPid) "{0}@{1}" -f $appPid, (Get-Process -Id $appPid).StartTime.ToUniversalTime().Ticks }
    $problems = New-Object System.Collections.Generic.List[string]
    if ($null -ne $run.Error) { $problems.Add("runner: $($run.Error)") }
    if ($run.TimedOut -or $run.Terminated) { $problems.Add("job terminated (timeout $($run.TimedOut), leftovers $($run.LeftoverProcesses))") }
    if ($run.ExitCode -ne 0) { $problems.Add("exit code $($run.ExitCode)") }
    $job = $null
    if (-not (Test-Path -LiteralPath $report)) { $problems.Add('no report') }
    else {
        $result = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
        if (-not $result.passed) { $problems.Add("report not passed: $(@($result.problems) -join '; ')") }
        $job = Get-CatalogJobCpu -Rows @(Import-Csv -LiteralPath (Join-Path $OutputDirectory "$name.job.csv")) -Messages @(Import-Csv -LiteralPath (Join-Path $OutputDirectory "$name.job.messages.csv")) -Phases $result.phases -MonitorKeys @($run.OnStartedResult)
        foreach ($p in $job.Problems) { $problems.Add("job: $p") }
        if ($job.JobProcesses -lt 2) { $problems.Add("only $($job.JobProcesses) process(es) in the job; WebView2 processes expected") }
    }
    if ($null -ne $job) {
        Write-Host ("{0}: limit flags {1}, job processes {2}, whole-run CPU {3} s (startup {4}, load {5}), end gap {6} s, max row interval {7} s, clock drift {8} s, rows {9}" -f $name, $run.LimitFlags, $job.JobProcesses,
            (Format-CatalogNumber $job.RunCpuSeconds), (Format-CatalogNumber $job.StartupCpuSeconds), (Format-CatalogNumber $job.LoadCpuSeconds), (Format-CatalogNumber $job.EndGapSeconds), (Format-CatalogNumber $job.MaxRowIntervalSeconds), (Format-CatalogNumber $job.MaxClockDriftSeconds), $run.Rows)
    }
    if ($problems.Count -gt 0) { foreach ($p in $problems) { $failures.Add("${name}: $p"); Write-Host "FAIL ${name}: $p" } }
    else { Write-Host "ok   ${name}: ran in its job; accounting complete and valid" }
}
if ($failures.Count -gt 0) { exit 1 }
Write-Host "PASS: $($Executable.Count) arm(s) ran in a job with complete, valid job CPU accounting."
exit 0
