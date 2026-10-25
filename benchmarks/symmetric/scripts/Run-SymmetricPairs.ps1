<#
.SYNOPSIS
Builds (or reuses) the plain and runtime variants and runs a fixed, predeclared
set of alternating pairs with the process monitor (issue #13, stage 9).

.DESCRIPTION
For every scenario and pair, both builds run once, in alternating order
(odd pairs plain first, even pairs runtime first). Each run starts from a
fresh process after a pause, runs its scenario automatically, writes its JSON
report and exits; Measure-ProcessTree.ps1 samples the whole process tree
every second until the app exits. Nothing is discarded: every report, every
monitor CSV and the console output of every run stay in -OutputDirectory.
Summarize-SymmetricRuns.ps1 then computes the paired differences.

Two monitoring profiles are kept apart, each in its own output directory:
- Cpu (default): one sample per second. The CPU comparison uses only this
  profile, so CPU results of different sampling rates are never mixed.
- Ram: one sample every 0.2 s, to see more of the short memory peaks (it
  still cannot guarantee catching every peak). WMI sampling this often costs
  the observer more CPU, so its CPU numbers are not compared. Needs a
  monitor that accepts fractional intervals (PR #19).
The monitor's own CPU time is recorded for every run as its overhead.

-Phase Pilot always means five exploratory pairs per scenario and profile;
they are summarized descriptively and never pooled with Confirmatory pairs.
-Phase Confirmatory always means one fixed series of 20 pairs per scenario
and profile. There is no interim statistical look and no confirmatory extension.

The order of all 20 pairs is fixed before the first one: schedule.csv lists every
planned run, and README.md is copied to protocol.md with the SHA256 of both
scripts in configuration.json. An existing results directory is never reused.
To keep the two monitor profiles comparable, the second profile can reuse the
same plain/runtime binaries via -ExecutablesFrom from the first profile's
results directory.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MonitorScript,

    [ValidateSet('Cpu', 'Ram')]
    [string]$MonitorProfile = 'Cpu',

    [Parameter(Mandatory = $true)]
    [ValidateSet('Pilot', 'Confirmatory')]
    [string]$Phase,

    [string]$OutputDirectory = (Join-Path (Get-Location) ("symmetric-results-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))),

    [ValidateSet('S1', 'S2', 'S3', 'S4')]
    [string[]]$Scenarios = @('S1', 'S2', 'S3', 'S4'),

    [ValidateRange(1, 50)]
    [int]$Pairs = 5,

    # Number of the first pair; 11 for the confirmatory extension.
    [ValidateRange(1, 50)]
    [int]$FirstPair = 1,

    [ValidateRange(5, 600)]
    [int]$DurationSeconds = 60,

    [ValidateRange(0, 120)]
    [int]$IdleSeconds = 10,

    [ValidateRange(0, 600)]
    [int]$PauseSeconds = 30,

    [ValidateRange(1, 100000)]
    [int]$Iterations = 100,

    [ValidateRange(1, 8)]
    [int]$BufferMb = 4,

    [ValidateRange(1, 50)]
    [int]$RequestsPerWindow = 10,

    [ValidateRange(0, 60000)]
    [int]$RoundIntervalMs = 500,

    # Reuse plain.exe and runtime.exe already in <OutputDirectory>\bin.
    [switch]$SkipBuild,

    # Reuse plain.exe and runtime.exe from the other monitor profile's results directory,
    # so Cpu and Ram measurements use byte-identical executables.
    [string]$ExecutablesFrom
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$expectedScenarios = @('S1', 'S2', 'S3', 'S4')
if (($Scenarios -join ',') -ne ($expectedScenarios -join ',')) {
    throw "Phase $Phase must include scenarios in the fixed order S1,S2,S3,S4."
}
if ($Phase -eq 'Pilot' -and ($FirstPair -ne 1 -or $Pairs -ne 5)) {
    throw 'Pilot protocol is fixed at pairs 1..5; use -FirstPair 1 -Pairs 5.'
}
if ($Phase -eq 'Confirmatory' -and ($FirstPair -ne 1 -or $Pairs -ne 20)) {
    throw 'Confirmatory protocol is fixed at pairs 1..20 with one analysis; use -FirstPair 1 -Pairs 20. Extensions/interim looks are not part of this protocol.'
}

$benchRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $benchRoot)
$MonitorScript = (Resolve-Path -LiteralPath $MonitorScript).Path
$sampleIntervalSeconds = if ($MonitorProfile -eq 'Ram') { 0.2 } else { 1 }
$intervalType = (Get-Command -Name $MonitorScript).Parameters['SampleIntervalSeconds'].ParameterType
if ($MonitorProfile -eq 'Ram' -and $intervalType -ne [double]) {
    throw "The Ram profile samples every 0.2 s, but $MonitorScript takes SampleIntervalSeconds as $($intervalType.Name). Use a monitor that accepts fractional seconds (PR #19)."
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$binDirectory = Join-Path $OutputDirectory 'bin'
$runsDirectory = Join-Path $OutputDirectory 'runs'
# Never mix or overwrite measurements: a results directory is used once.
foreach ($existing in @('configuration.json', 'schedule.csv', 'runs.log')) {
    if (Test-Path -LiteralPath (Join-Path $OutputDirectory $existing)) {
        throw "$OutputDirectory already has $existing; use a new -OutputDirectory."
    }
}
if ((Test-Path -LiteralPath $runsDirectory) -and @(Get-ChildItem -LiteralPath $runsDirectory).Count -gt 0) {
    throw "$runsDirectory is not empty; use a new -OutputDirectory."
}
New-Item -ItemType Directory -Force -Path $binDirectory, $runsDirectory | Out-Null

function Invoke-Checked {
    param([string]$Description, [scriptblock]$Command)
    Write-Host "== $Description"
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE"
    }
}

function Get-CommandVersion {
    param([string]$Name, [string[]]$Arguments)
    try {
        return ((& $Name @Arguments 2>&1) | Out-String).Trim()
    }
    catch {
        return "unavailable: $($_.Exception.Message)"
    }
}

function Get-WebView2Version {
    $keys = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    )
    foreach ($key in $keys) {
        $item = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($null -ne $item -and $item.PSObject.Properties['pv']) {
            return [string]$item.pv
        }
    }
    return 'unknown'
}

$exe = @{
    plain   = Join-Path $binDirectory 'plain.exe'
    runtime = Join-Path $binDirectory 'runtime.exe'
}

if ($ExecutablesFrom) {
    foreach ($build in @('plain', 'runtime')) {
        Copy-Item -LiteralPath (Join-Path $ExecutablesFrom "bin\$build.exe") -Destination $exe[$build] -Force
    }
}
elseif (-not $SkipBuild) {
    Push-Location $benchRoot
    try {
        Invoke-Checked 'npm ci' { npm ci }
        Invoke-Checked 'Build plain' { npm run tauri -- build --no-bundle -- --locked }
        Copy-Item -LiteralPath (Join-Path $repoRoot 'target\release\symmetric-bench.exe') -Destination $exe.plain -Force
        Invoke-Checked 'Build runtime' { npm run tauri -- build --no-bundle --features runtime -- --locked }
        Copy-Item -LiteralPath (Join-Path $repoRoot 'target\release\symmetric-bench.exe') -Destination $exe.runtime -Force
    }
    finally {
        Pop-Location
    }
}
foreach ($build in $exe.Keys) {
    if (-not (Test-Path -LiteralPath $exe[$build])) {
        throw "Missing $($exe[$build]); run without -SkipBuild."
    }
}

$os = Get-CimInstance -ClassName Win32_OperatingSystem
$cpu = @(Get-CimInstance -ClassName Win32_Processor)[0]
$gitStatus = (& git -C $repoRoot status --porcelain) | Out-String
$configuration = [ordered]@{
    createdAt         = (Get-Date).ToString('o')
    machine           = $env:COMPUTERNAME
    os                = "$($os.Caption) $($os.Version) (build $($os.BuildNumber))"
    cpu               = "$($cpu.Name), $($cpu.NumberOfCores) cores, $($cpu.NumberOfLogicalProcessors) logical"
    memoryGb          = [Math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    webView2          = Get-WebView2Version
    powershell        = $PSVersionTable.PSVersion.ToString()
    node              = Get-CommandVersion 'node' @('--version')
    npm               = Get-CommandVersion 'npm' @('--version')
    rustc             = Get-CommandVersion 'rustc' @('--version')
    cargo             = Get-CommandVersion 'cargo' @('--version')
    gitHead           = ((& git -C $repoRoot rev-parse HEAD) | Out-String).Trim()
    gitDirty          = -not [string]::IsNullOrWhiteSpace($gitStatus)
    gitStatus         = $gitStatus.Trim()
    monitorScript     = $MonitorScript
    monitorSha256     = (Get-FileHash -LiteralPath $MonitorScript -Algorithm SHA256).Hash
    monitorGitHead    = ((& git -C (Split-Path -Parent $MonitorScript) rev-parse HEAD 2>$null) | Out-String).Trim()
    plainExeSha256    = (Get-FileHash -LiteralPath $exe.plain -Algorithm SHA256).Hash
    plainExeBytes     = (Get-Item -LiteralPath $exe.plain).Length
    runtimeExeSha256  = (Get-FileHash -LiteralPath $exe.runtime -Algorithm SHA256).Hash
    runtimeExeBytes   = (Get-Item -LiteralPath $exe.runtime).Length
    profile           = $MonitorProfile
    phase             = $Phase
    sampleIntervalSeconds = $sampleIntervalSeconds
    scenarios         = $Scenarios
    pairs             = $Pairs
    firstPair         = $FirstPair
    durationSeconds   = $DurationSeconds
    idleSeconds       = $IdleSeconds
    pauseSeconds      = $PauseSeconds
    iterations        = $Iterations
    bufferMb          = $BufferMb
    requestsPerWindow = $RequestsPerWindow
    roundIntervalMs   = $RoundIntervalMs
    order             = 'scenarios in the given order; within a scenario pairs in order; odd pairs plain then runtime, even pairs runtime then plain (schedule.csv)'
    runScriptSha256   = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    summarizeScriptSha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'Summarize-SymmetricRuns.ps1') -Algorithm SHA256).Hash
    protocolSha256    = (Get-FileHash -LiteralPath (Join-Path $benchRoot 'README.md') -Algorithm SHA256).Hash
}
$configuration | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'configuration.json') -Encoding UTF8
Copy-Item -LiteralPath (Join-Path $benchRoot 'README.md') -Destination (Join-Path $OutputDirectory 'protocol.md')

# The full order, written before the first run.
$schedule = New-Object System.Collections.Generic.List[object]
foreach ($scenario in $Scenarios) {
    for ($pair = $FirstPair; $pair -lt $FirstPair + $Pairs; $pair++) {
        $order = if ($pair % 2 -eq 1) { @('plain', 'runtime') } else { @('runtime', 'plain') }
        for ($position = 1; $position -le 2; $position++) {
            $build = $order[$position - 1]
            $schedule.Add([pscustomobject][ordered]@{
                    Seq = $schedule.Count + 1; Scenario = $scenario; Pair = $pair; PositionInPair = $position; Build = $build
                    Name = ('{0}-pair{1:D2}-{2}' -f $scenario, $pair, $build)
                })
        }
    }
}
$schedule | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'schedule.csv') -NoTypeInformation -Encoding UTF8

$runLog = Join-Path $OutputDirectory 'runs.log'
$timeoutSeconds = $DurationSeconds + 2 * $IdleSeconds + 120

foreach ($planned in $schedule) {
    $scenario = $planned.Scenario; $pair = $planned.Pair; $position = $planned.PositionInPair
    $build = $planned.Build; $name = $planned.Name
    $report = Join-Path $runsDirectory "$name.json"
    $monitorCsv = Join-Path $runsDirectory "$name.monitor.csv"
    $monitorLog = Join-Path $runsDirectory "$name.monitor.log"
    if ($PauseSeconds -gt 0) {
        Write-Host "Pause $PauseSeconds s before $name"
        Start-Sleep -Seconds $PauseSeconds
    }

    $arguments = @(
        '--scenario', $scenario, '--report', "`"$report`"", '--duration', $DurationSeconds,
        '--idle-before', $IdleSeconds, '--idle-after', $IdleSeconds, '--iterations', $Iterations,
        '--buffer-mb', $BufferMb, '--requests-per-window', $RequestsPerWindow, '--round-interval-ms', $RoundIntervalMs
    )
    $started = Get-Date
    $app = Start-Process -FilePath $exe[$build] -ArgumentList $arguments -PassThru
    # Windows PowerShell reports ExitCode only if the handle was opened before exit.
    $null = $app.Handle
    $monitorArguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$MonitorScript`"", '-RootPid', $app.Id,
        '-DurationSeconds', ($timeoutSeconds + 30), '-SampleIntervalSeconds', $sampleIntervalSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture),
        '-OutputPath', "`"$monitorCsv`"", '-Diagnostics'
    )
    $monitor = Start-Process -FilePath 'powershell.exe' -ArgumentList $monitorArguments -PassThru -NoNewWindow -RedirectStandardOutput $monitorLog -RedirectStandardError "$monitorLog.err"
    $null = $monitor.Handle

    $timedOut = -not $app.WaitForExit($timeoutSeconds * 1000)
    if ($timedOut) {
        Write-Warning "$name did not exit within $timeoutSeconds s; stopping it."
        Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
        $app.WaitForExit()
    }
    $monitor.WaitForExit()
    # Observer overhead: CPU time of the monitor process itself.
    $monitorCpuSeconds = $null
    try { $monitorCpuSeconds = [Math]::Round($monitor.TotalProcessorTime.TotalSeconds, 3) } catch { }
    $entry = [ordered]@{
        name          = $name
        scenario      = $scenario
        pair          = $pair
        positionInPair = $position
        build         = $build
        startedAt     = $started.ToString('o')
        endedAt       = (Get-Date).ToString('o')
        pid           = $app.Id
        exitCode      = $app.ExitCode
        timedOut      = $timedOut
        monitorExit   = $monitor.ExitCode
        monitorCpuSeconds = $monitorCpuSeconds
        reportExists  = Test-Path -LiteralPath $report
    }
    ($entry | ConvertTo-Json -Compress) | Add-Content -LiteralPath $runLog -Encoding UTF8
    Write-Host ("{0}: exit {1}, report {2}" -f $name, $app.ExitCode, $(if ($entry.reportExists) { 'written' } else { 'MISSING' }))
}

Write-Host "Done. Results: $OutputDirectory"
Write-Host "Next: Summarize-SymmetricRuns.ps1 -ResultsDirectory `"$OutputDirectory`""
