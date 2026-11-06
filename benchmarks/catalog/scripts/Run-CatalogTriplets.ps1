<#
.SYNOPSIS
Builds the arms of memory scenario M and runs them in matched triplets with
the process monitor (protocol: docs/benchmark/memory-pilot-protocol.md).

.DESCRIPTION
Arms: A = per-window JS copy (no feature), B = hand-written shared Rust
service (--features shared), C = the same catalog through shared-runtime
(--features framework; #35 at b65177d, merged in for arm C). -Phase Pilot
still refuses to start: the pilot runs only after a native smoke of all
three arms and the final check of the frozen protocol (#33 §10).

The whole order is written to schedule.csv before the first run
(CatalogSchedule.ps1: cells interleaved block by block, arm permutations
cycled per cell) and read back and checked for completeness before it. Each run is a fresh process with its own WebView2 user data folder
(WEBVIEW2_USER_DATA_FOLDER under profiles\), after a pause. The monitor
samples the whole process tree every second until the app exits. Each app
is created suspended in its own Windows Job Object and resumed only after
the assignment (CatalogJobCpu.ps1); the runner reads the job's CPU
accounting every 250 ms into runs\<run>.job.csv and keeps the job's
process messages in runs\<run>.job.messages.csv. Whole-run CPU comes from
the job (protocol §7); the monitor gives RAM and the per-process
diagnostics. On a timeout, or when processes of the app outlive it by more
than the grace period, the runner terminates its own job and nothing else.
Nothing is
discarded: every report, monitor CSV, diagnostics file and log stays in
-OutputDirectory, failed runs included. An existing results directory is
never reused. Summarize-CatalogRuns.ps1 then computes the per-run measures
and the differences inside each triplet.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MonitorScript,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Smoke', 'Pilot')]
    [string]$Phase,

    [string]$OutputDirectory = (Join-Path (Get-Location) ("catalog-results-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))),

    [string[]]$Cells = @('N2D0', 'N2D16', 'N2D64', 'N4D64'),

    [ValidateSet('A', 'B', 'C')]
    [string[]]$Arms = @('A', 'B', 'C'),

    [ValidateRange(1, 50)]
    [int]$Triplets = 5,

    # Picks the first arm permutation and cell rotation; recorded in schedule.csv.
    [ValidateRange(0, 1000000)]
    [int]$ScheduleSeed = 1,

    [ValidateRange(1, 1000000)]
    [int]$DataSeed = 1,

    [ValidateRange(0, 600)]
    [int]$IdleBeforeSeconds = 20,

    [ValidateRange(0, 600)]
    [int]$WarmupSeconds = 30,

    [ValidateRange(1, 600)]
    [int]$LoadSeconds = 120,

    [ValidateRange(0, 600)]
    [int]$IdleAfterSeconds = 30,

    [ValidateRange(0, 600)]
    [int]$PauseSeconds = 30,

    [ValidateRange(100, 10000)]
    [int]$StepIntervalMs = 500,

    # Reuse bin\arm-*.exe already in -OutputDirectory.
    [switch]$SkipBuild,

    # Copy bin\arm-*.exe from an earlier results directory instead of building.
    [string]$ExecutablesFrom,

    # A schedule.csv written and reviewed before the run (plans\). The
    # runner stops before building if the schedule it would follow differs
    # from this file in any field or order.
    [string]$ExpectedSchedule
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CatalogSchedule.ps1')
. (Join-Path $PSScriptRoot 'CatalogJobCpu.ps1')

$benchRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $benchRoot)
$protocolFile = Join-Path $repoRoot 'docs\benchmark\memory-pilot-protocol.md'
$sampleIntervalSeconds = 1

if ($Phase -eq 'Pilot') {
    throw 'The pilot runs only after a native smoke of arms A, B and C and the final check of the frozen protocol (docs/benchmark/memory-pilot-protocol.md §10, pilot gate).'
}

$MonitorScript = (Resolve-Path -LiteralPath $MonitorScript).Path
# Scenario M verifies the PrivatePageCount unit on a stable WebView2 child,
# not on the host process alone (monitor #43, -UnitCheckRequireChildName).
$unitCheckChildName = 'msedgewebview2.exe'
if (-not (Get-Command -Name $MonitorScript).Parameters.ContainsKey('UnitCheckRequireChildName')) {
    throw "$MonitorScript has no -UnitCheckRequireChildName; scenario M needs the monitor from #43 (167a67d or later)."
}
$cellRows = @($Cells | ForEach-Object { ConvertFrom-CellName $_ })
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$binDirectory = Join-Path $OutputDirectory 'bin'
$runsDirectory = Join-Path $OutputDirectory 'runs'
$profilesDirectory = Join-Path $OutputDirectory 'profiles'
foreach ($existing in @('configuration.json', 'schedule.csv', 'runs.log')) {
    if (Test-Path -LiteralPath (Join-Path $OutputDirectory $existing)) {
        throw "$OutputDirectory already has $existing; use a new -OutputDirectory."
    }
}
if ((Test-Path -LiteralPath $runsDirectory) -and @(Get-ChildItem -LiteralPath $runsDirectory).Count -gt 0) {
    throw "$runsDirectory is not empty; use a new -OutputDirectory."
}
New-Item -ItemType Directory -Force -Path $binDirectory, $runsDirectory, $profilesDirectory | Out-Null

$schedule = New-CatalogSchedule -Cells $Cells -Arms $Arms -Triplets $Triplets -Seed $ScheduleSeed -DataSeed $DataSeed
$expectedScheduleSha256 = $null
if ($ExpectedSchedule) {
    if (-not (Test-CatalogScheduleMatchesFile -Schedule $schedule -Path $ExpectedSchedule)) { throw "The schedule for these parameters differs from $ExpectedSchedule; nothing was built or run." }
    $expectedScheduleSha256 = (Get-FileHash -LiteralPath $ExpectedSchedule -Algorithm SHA256).Hash
}

function Invoke-Checked {
    param([string]$Description, [scriptblock]$Command)
    Write-Host "== $Description"
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$Description failed with exit code $LASTEXITCODE" }
}

function Get-CommandVersion {
    param([string]$Name, [string[]]$Arguments)
    try { return ((& $Name @Arguments 2>&1) | Out-String).Trim() }
    catch { return "unavailable: $($_.Exception.Message)" }
}

function Get-WebView2Version {
    $keys = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    )
    foreach ($key in $keys) {
        $item = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($null -ne $item -and $item.PSObject.Properties['pv']) { return [string]$item.pv }
    }
    return 'unknown'
}

function Get-PowerPlan {
    try { return ((& powercfg /getactivescheme 2>&1) | Out-String).Trim() }
    catch { return 'unknown' }
}

$exe = [ordered]@{}
foreach ($arm in $Arms) { $exe[$arm] = Join-Path $binDirectory "arm-$arm.exe" }
$features = @{ A = @(); B = @('--features', 'shared'); C = @('--features', 'framework') }

if ($ExecutablesFrom) {
    foreach ($arm in $Arms) { Copy-Item -LiteralPath (Join-Path $ExecutablesFrom "bin\arm-$arm.exe") -Destination $exe[$arm] -Force }
}
elseif (-not $SkipBuild) {
    Push-Location $benchRoot
    try {
        Invoke-Checked 'npm ci' { npm ci }
        foreach ($arm in $Arms) {
            $armFeatures = $features[$arm]
            Invoke-Checked "Build arm $arm" { npm run tauri -- build --no-bundle @armFeatures -- --locked }
            Copy-Item -LiteralPath (Join-Path $repoRoot 'target\release\catalog-bench.exe') -Destination $exe[$arm] -Force
        }
    }
    finally { Pop-Location }
}
foreach ($arm in $Arms) {
    if (-not (Test-Path -LiteralPath $exe[$arm])) { throw "Missing $($exe[$arm]); run without -SkipBuild." }
}

$os = Get-CimInstance -ClassName Win32_OperatingSystem
$cpu = @(Get-CimInstance -ClassName Win32_Processor)[0]
$gitStatus = (& git -C $repoRoot status --porcelain) | Out-String
$executables = [ordered]@{}
foreach ($arm in $Arms) {
    $executables[$arm] = [ordered]@{
        sha256 = (Get-FileHash -LiteralPath $exe[$arm] -Algorithm SHA256).Hash
        bytes  = (Get-Item -LiteralPath $exe[$arm]).Length
    }
}
$configuration = [ordered]@{
    scenario              = 'M'
    createdAt             = (Get-Date).ToString('o')
    machine               = $env:COMPUTERNAME
    os                    = "$($os.Caption) $($os.Version) (build $($os.BuildNumber))"
    cpu                   = "$($cpu.Name), $($cpu.NumberOfCores) cores, $($cpu.NumberOfLogicalProcessors) logical"
    memoryGb              = [Math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    powerPlan             = Get-PowerPlan
    webView2              = Get-WebView2Version
    powershell            = $PSVersionTable.PSVersion.ToString()
    node                  = Get-CommandVersion 'node' @('--version')
    npm                   = Get-CommandVersion 'npm' @('--version')
    rustc                 = Get-CommandVersion 'rustc' @('--version')
    cargo                 = Get-CommandVersion 'cargo' @('--version')
    gitHead               = ((& git -C $repoRoot rev-parse HEAD) | Out-String).Trim()
    gitDirty              = -not [string]::IsNullOrWhiteSpace($gitStatus)
    gitStatus             = $gitStatus.Trim()
    monitorScript         = $MonitorScript
    monitorSha256         = (Get-FileHash -LiteralPath $MonitorScript -Algorithm SHA256).Hash
    monitorGitHead        = ((& git -C (Split-Path -Parent $MonitorScript) rev-parse HEAD 2>$null) | Out-String).Trim()
    monitorUnitCheckRequireChildName = $unitCheckChildName
    cpuSource             = 'job'
    jobLimits             = $script:CatalogJob
    jobScriptSha256       = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'CatalogJobCpu.ps1') -Algorithm SHA256).Hash
    expectedSchedule      = if ($ExpectedSchedule) { (Resolve-Path -LiteralPath $ExpectedSchedule).Path } else { $null }
    expectedScheduleSha256 = $expectedScheduleSha256
    executables           = $executables
    phase                 = $Phase
    sampleIntervalSeconds = $sampleIntervalSeconds
    cells                 = $Cells
    arms                  = $Arms
    triplets              = $Triplets
    scheduleSeed          = $ScheduleSeed
    dataSeed              = $DataSeed
    idleBeforeSeconds     = $IdleBeforeSeconds
    warmupSeconds         = $WarmupSeconds
    loadSeconds           = $LoadSeconds
    idleAfterSeconds      = $IdleAfterSeconds
    pauseSeconds          = $PauseSeconds
    stepIntervalMs        = $StepIntervalMs
    order                 = 'CatalogSchedule.ps1: blocks of one triplet per cell, cell order rotated per block, arm permutations cycled per cell from a different start in each cell (schedule.csv)'
    runScriptSha256       = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    scheduleScriptSha256  = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'CatalogSchedule.ps1') -Algorithm SHA256).Hash
    summarizeScriptSha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'Summarize-CatalogRuns.ps1') -Algorithm SHA256).Hash
    readmeSha256          = (Get-FileHash -LiteralPath (Join-Path $benchRoot 'README.md') -Algorithm SHA256).Hash
    protocolSha256        = if (Test-Path -LiteralPath $protocolFile) { (Get-FileHash -LiteralPath $protocolFile -Algorithm SHA256).Hash } else { $null }
}
$configuration | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'configuration.json') -Encoding UTF8
Copy-Item -LiteralPath (Join-Path $benchRoot 'README.md') -Destination (Join-Path $OutputDirectory 'README.md')
if (Test-Path -LiteralPath $protocolFile) { Copy-Item -LiteralPath $protocolFile -Destination (Join-Path $OutputDirectory 'protocol.md') }

# The full order, written before the first run.
$schedule | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'schedule.csv') -NoTypeInformation -Encoding UTF8
# The file as written is read back and checked, and must match the order
# the runs follow, before the first run.
$written = @(Import-Csv -LiteralPath (Join-Path $OutputDirectory 'schedule.csv'))
$scheduleProblems = @(Test-CatalogSchedule -Schedule $written -Cells $Cells -Arms $Arms -Triplets $Triplets)
if ((@($written | ForEach-Object { $_.Name }) -join ',') -ne (@($schedule | ForEach-Object { $_.Name }) -join ',')) { $scheduleProblems += 'schedule.csv differs from the run order' }
if ($scheduleProblems.Count -gt 0) { throw "schedule.csv is not a complete schedule: $($scheduleProblems -join '; ')" }

$runLog = Join-Path $OutputDirectory 'runs.log'
$maxDataMib = ($cellRows | Measure-Object -Property DataMib -Maximum).Maximum
$timeoutSeconds = $IdleBeforeSeconds + $WarmupSeconds + $LoadSeconds + $IdleAfterSeconds + 180 + 2 * $maxDataMib

foreach ($planned in $schedule) {
    $name = $planned.Name
    $report = Join-Path $runsDirectory "$name.json"
    $monitorCsv = Join-Path $runsDirectory "$name.monitor.csv"
    $monitorLog = Join-Path $runsDirectory "$name.monitor.log"
    $webViewProfile = Join-Path $profilesDirectory $name
    if ($PauseSeconds -gt 0) {
        Write-Host "Pause $PauseSeconds s before $name"
        Start-Sleep -Seconds $PauseSeconds
    }

    $arguments = @(
        '--report', "`"$report`"", '--data-mib', $planned.DataMib, '--windows', $planned.Windows, '--seed', $planned.DataSeed,
        '--idle-before', $IdleBeforeSeconds, '--warmup', $WarmupSeconds, '--duration', $LoadSeconds,
        '--idle-after', $IdleAfterSeconds, '--step-interval-ms', $StepIntervalMs
    )
    $jobCsv = Join-Path $runsDirectory "$name.job.csv"
    $jobMessagesCsv = Join-Path $runsDirectory "$name.job.messages.csv"
    $commandLine = '"{0}" {1}' -f $exe[$planned.Arm], ($arguments -join ' ')
    $started = Get-Date
    $monitorArguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$MonitorScript`"", '-RootPid', '{PID}',
        '-DurationSeconds', ($timeoutSeconds + 30), '-SampleIntervalSeconds', $sampleIntervalSeconds,
        '-OutputPath', "`"$monitorCsv`"", '-Diagnostics', '-UnitCheckRequireChildName', $unitCheckChildName
    )
    # The app is created suspended in a new job, resumed, then the monitor is
    # started on its PID; the job is read every 250 ms until every process of
    # the app has exited (CatalogJobCpu.ps1, Invoke-CatalogJobRun).
    $run = Invoke-CatalogJobRun -Label $name -CommandLine $commandLine -WorkingDirectory (Get-Location).Path `
        -Environment @{ WEBVIEW2_USER_DATA_FOLDER = $webViewProfile } -TimeoutSeconds $timeoutSeconds `
        -JobCsv (Join-Path $runsDirectory "$name.job.csv") -JobMessagesCsv (Join-Path $runsDirectory "$name.job.messages.csv") `
        -OnStarted {
            param($appPid)
            $arguments = @($monitorArguments | ForEach-Object { if ($_ -eq '{PID}') { $appPid } else { $_ } })
            $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -PassThru -NoNewWindow -RedirectStandardOutput $monitorLog -RedirectStandardError "$monitorLog.err"
            $null = $process.Handle
            $process
        }.GetNewClosure()
    $monitor = $run.OnStartedResult
    $exitCode = $run.ExitCode
    $timedOut = $run.TimedOut
    if ($null -ne $monitor) { $monitor.WaitForExit() }
    $entry = [ordered]@{
        name              = $name
        seq               = $planned.Seq
        cell              = $planned.Cell
        triplet           = $planned.Triplet
        position          = $planned.Position
        arm               = $planned.Arm
        startedAt         = $started.ToString('o')
        endedAt           = (Get-Date).ToString('o')
        pid               = $run.Pid
        exitCode          = $exitCode
        timedOut          = $timedOut
        jobLimitFlags     = $run.LimitFlags
        jobRows           = $run.Rows
        jobLeftoverProcesses = $run.LeftoverProcesses
        jobTerminated     = $run.Terminated
        jobError          = $run.Error
        monitorExit       = $monitorExit
        monitorCpuSeconds = $monitorCpuSeconds
        reportExists      = Test-Path -LiteralPath $report
        webView2Profile   = $webViewProfile
        profileCreated    = Test-Path -LiteralPath $webViewProfile
    }
    ($entry | ConvertTo-Json -Compress) | Add-Content -LiteralPath $runLog -Encoding UTF8
    Write-Host ("{0}: exit {1}, report {2}" -f $name, $exitCode, $(if ($entry.reportExists) { 'written' } else { 'MISSING' }))
}

Write-Host "Done. Results: $OutputDirectory"
Write-Host "Next: Summarize-CatalogRuns.ps1 -ResultsDirectory `"$OutputDirectory`""
