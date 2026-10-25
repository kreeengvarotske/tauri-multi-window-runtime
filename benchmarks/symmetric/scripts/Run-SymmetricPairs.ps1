<#
.SYNOPSIS
Builds the plain and runtime variants of the symmetric benchmark and runs
alternating pairs of each scenario with the process monitor (issue #13, stage 9).

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

-Phase Pilot marks exploratory pairs: they are summarized descriptively and
never pooled with Confirmatory pairs, which are judged by the rule fixed in
README.md before they run.
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
    [switch]$SkipBuild
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

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

if (-not $SkipBuild) {
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
    durationSeconds   = $DurationSeconds
    idleSeconds       = $IdleSeconds
    pauseSeconds      = $PauseSeconds
    iterations        = $Iterations
    bufferMb          = $BufferMb
    requestsPerWindow = $RequestsPerWindow
    roundIntervalMs   = $RoundIntervalMs
    order             = 'odd pairs plain then runtime, even pairs runtime then plain'
}
$configuration | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'configuration.json') -Encoding UTF8

$runLog = Join-Path $OutputDirectory 'runs.log'
$timeoutSeconds = $DurationSeconds + 2 * $IdleSeconds + 120

foreach ($scenario in $Scenarios) {
    for ($pair = 1; $pair -le $Pairs; $pair++) {
        $order = if ($pair % 2 -eq 1) { @('plain', 'runtime') } else { @('runtime', 'plain') }
        $position = 0
        foreach ($build in $order) {
            $position++
            $name = '{0}-pair{1:D2}-{2}' -f $scenario, $pair, $build
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
    }
}

Write-Host "Done. Results: $OutputDirectory"
Write-Host "Next: Summarize-SymmetricRuns.ps1 -ResultsDirectory `"$OutputDirectory`""
