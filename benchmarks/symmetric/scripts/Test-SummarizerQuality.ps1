<#
.SYNOPSIS
Regression tests for run discovery, monitor exit status, load cadence, and
metric-specific quality gating in Summarize-SymmetricRuns.ps1.

Runs under Windows PowerShell 5.1 and PowerShell 7. Uses only synthetic data.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$culture = [System.Globalization.CultureInfo]::InvariantCulture
$summarizer = Join-Path $PSScriptRoot 'Summarize-SymmetricRuns.ps1'
$root = Join-Path ([System.IO.Path]::GetTempPath()) ("symmetric-quality-test-{0}" -f [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null

function Assert-That {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if (-not $Condition) { throw "FAIL $Name $Detail" }
    Write-Host "ok   $Name"
}

function New-SyntheticResults {
    param(
        [string]$Directory,
        [ValidateSet('Cpu', 'Ram')][string]$Profile,
        [double]$Interval,
        [ValidateSet('none', 'private-nan', 'cpu-missing', 'cpu-nan', 'working-set-nan', 'missing-json', 'monitor-exit', 'bad-load-cadence')][string]$Fault
    )

    $runsDirectory = Join-Path $Directory 'runs'
    New-Item -ItemType Directory -Path $runsDirectory -Force | Out-Null
    $configuration = [ordered]@{
        profile = $Profile
        phase = 'Pilot'
        machine = 'SYNTHETIC'
        gitHead = 'synthetic'
        os = 'Synthetic Windows test'
        plainExeSha256 = 'plain-test'
        runtimeExeSha256 = 'runtime-test'
        monitorSha256 = 'monitor-test'
        sampleIntervalSeconds = $Interval
        durationSeconds = 10
        idleSeconds = 10
        pauseSeconds = 0
        iterations = 1
        bufferMb = 4
        requestsPerWindow = 10
        roundIntervalMs = 500
        pairs = 1
        firstPair = 1
    }
    $configuration | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Directory 'configuration.json') -Encoding UTF8

    $start = [DateTimeOffset]::new(2026, 10, 25, 12, 0, 0, [TimeSpan]::Zero)
    $schedule = New-Object System.Collections.Generic.List[object]
    $logEntries = New-Object System.Collections.Generic.List[string]

    foreach ($build in @('plain', 'runtime')) {
        $name = "S1-pair01-$build"
        $schedule.Add([pscustomobject][ordered]@{ Seq = $schedule.Count + 1; Name = $name })
        $reportPath = Join-Path $runsDirectory "$name.json"

        if (-not ($Fault -eq 'missing-json' -and $build -eq 'runtime')) {
            $report = [ordered]@{
                schemaVersion = 1
                passed = $true
                config = @{ build = $build; scenario = 'S1' }
                summary = @{ rounds = 20; passedRounds = 20; overruns = 0; requestsPerSecond = 2.0; roundMs = @{ p50 = 1.0; p95 = 2.0 } }
                totals = @{ requestsReceived = 20; operationsExecuted = 20; coalescedRequests = 0; cacheHits = 0; failedRequests = 0 }
                phases = @{
                    expectedReadyAt = $start.ToString('o')
                    loadStartedAt = $start.AddSeconds(10).ToString('o')
                    loadEndedAt = $start.AddSeconds(20).ToString('o')
                    endedAt = $start.AddSeconds(30).ToString('o')
                }
                abort = $null
            }
            $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8
        }

        $monitorExit = if ($Fault -eq 'monitor-exit' -and $build -eq 'runtime') { 1 } else { 0 }
        $logEntries.Add((@{
            name = $name
            exitCode = 0
            timedOut = $false
            monitorExit = $monitorExit
            monitorCpuSeconds = 0.1
        } | ConvertTo-Json -Compress))

        $samples = New-Object System.Collections.Generic.List[object]
        $count = [int][Math]::Round(30 / $Interval)
        for ($i = 0; $i -le $count; $i++) {
            $seconds = [Math]::Round($i * $Interval, 6)
            $time = $start.AddSeconds($seconds)
            $inLoad = $seconds -ge 10 -and $seconds -lt 20

            $private = '100.000'
            $workingSet = '120.000'
            $cpuDelta = if ($i -eq 0) { '' } else { $Interval.ToString('R', $culture) }
            $privateMissing = '0'
            $cpuUnreadable = '0'
            $sampleInterval = if ($i -eq 0) { '0' } else { $Interval.ToString('R', $culture) }

            if ($Fault -eq 'private-nan' -and $build -eq 'runtime' -and $seconds -ge 10 -and $seconds -lt (10 + $Interval)) {
                $private = 'NaN'
            }
            if ($Fault -eq 'working-set-nan' -and $build -eq 'runtime' -and $seconds -ge 10 -and $seconds -lt (10 + $Interval)) {
                $workingSet = 'NaN'
            }
            if (($Fault -eq 'cpu-missing' -or $Fault -eq 'cpu-nan') -and $build -eq 'runtime' -and $seconds -ge 10 -and $seconds -lt (10 + $Interval)) {
                $cpuDelta = if ($Fault -eq 'cpu-nan') { 'NaN' } else { '' }
                $cpuUnreadable = if ($Fault -eq 'cpu-missing') { '1' } else { '0' }
            }
            if ($Fault -eq 'bad-load-cadence' -and $build -eq 'plain' -and $inLoad -and $i -gt 0) {
                $sampleInterval = '1.3'
            }

            $samples.Add([pscustomobject][ordered]@{
                Timestamp = $time.ToString('o')
                RootPid = 1234
                ProcessCount = 1
                WorkingSetMB = $workingSet
                PrivateBytesMB = $private
                CpuDeltaSeconds = $cpuDelta
                Sample = $i
                IntervalSeconds = $sampleInterval
                PrivateMissingCount = $privateMissing
                CpuUnreadableCount = $cpuUnreadable
            })
        }
        $samples | Export-Csv -LiteralPath (Join-Path $runsDirectory "$name.monitor.csv") -NoTypeInformation -Encoding UTF8
    }

    $schedule | Export-Csv -LiteralPath (Join-Path $Directory 'schedule.csv') -NoTypeInformation -Encoding UTF8
    $logEntries | Set-Content -LiteralPath (Join-Path $Directory 'runs.log') -Encoding UTF8
}

function Invoke-Summary {
    param([string]$Name, [string]$Profile, [double]$Interval, [string]$Fault)
    $inputDirectory = Join-Path $root $Name
    $outputDirectory = Join-Path $inputDirectory 'analysis-test'
    New-SyntheticResults -Directory $inputDirectory -Profile $Profile -Interval $Interval -Fault $Fault
    & $summarizer -ResultsDirectory $inputDirectory -OutputDirectory $outputDirectory | Out-Null
    return $outputDirectory
}

try {
    # Missing/non-finite private memory must not invalidate a CPU-primary run,
    # but it must exclude that pair from private-memory secondary statistics.
    $cpuPrivateOutput = Invoke-Summary -Name 'cpu-private-nan' -Profile Cpu -Interval 1 -Fault 'private-nan'
    $cpuPrivateRuns = @(Import-Csv -LiteralPath (Join-Path $cpuPrivateOutput 'runs.csv'))
    $cpuRuntime = @($cpuPrivateRuns | Where-Object { $_.Build -eq 'runtime' })[0]
    Assert-That 'CPU primary remains valid with missing private-memory sample' ($cpuRuntime.Valid -eq 'True') $cpuRuntime.InvalidReason
    Assert-That 'non-finite private sample marks private metric invalid' ($cpuRuntime.PrivateMetricsValid -eq 'False')
    $cpuPrivateSummary = @(Import-Csv -LiteralPath (Join-Path $cpuPrivateOutput 'summary.csv'))
    $cpuPrimary = @($cpuPrivateSummary | Where-Object { $_.Metric -eq 'LoadCpuSeconds' })[0]
    $cpuSecondaryPrivate = @($cpuPrivateSummary | Where-Object { $_.Metric -eq 'LoadPrivateMBAvg' })[0]
    Assert-That 'CPU primary metric still has one valid pair' ([int]$cpuPrimary.ValidPairs -eq 1)
    Assert-That 'invalid private metric is excluded from secondary analysis' ([int]$cpuSecondaryPrivate.ValidPairs -eq 0)

    # CPU gaps must not invalidate a RAM-primary run.
    $ramCpuOutput = Invoke-Summary -Name 'ram-cpu-nan' -Profile Ram -Interval 0.2 -Fault 'cpu-nan'
    $ramRuns = @(Import-Csv -LiteralPath (Join-Path $ramCpuOutput 'runs.csv'))
    $ramRuntime = @($ramRuns | Where-Object { $_.Build -eq 'runtime' })[0]
    Assert-That 'RAM primary remains valid with non-finite CPU sample' ($ramRuntime.Valid -eq 'True') $ramRuntime.InvalidReason
    Assert-That 'non-finite CPU sample marks CPU metric invalid' ($ramRuntime.CpuMetricsValid -eq 'False')
    Assert-That 'RAM primary metric remains valid' ($ramRuntime.PrivateMetricsValid -eq 'True')

    # The run list is the union of the schedule, run log and report files.
    $missingOutput = Invoke-Summary -Name 'missing-json' -Profile Cpu -Interval 1 -Fault 'missing-json'
    $missingRuns = @(Import-Csv -LiteralPath (Join-Path $missingOutput 'runs.csv'))
    $missingRuntime = @($missingRuns | Where-Object { $_.Build -eq 'runtime' })[0]
    Assert-That 'scheduled run with absent JSON remains in runs.csv' ($null -ne $missingRuntime)
    Assert-That 'absent JSON has an explicit invalid reason' ($missingRuntime.InvalidReason -match 'JSON report missing') $missingRuntime.InvalidReason
    $missingPair = @(Import-Csv -LiteralPath (Join-Path $missingOutput 'pairs.csv'))[0]
    Assert-That 'missing report invalidates its pair' ($missingPair.Valid -eq 'False')

    # A monitor process failure is a failed measurement, even when its CSV exists.
    $monitorOutput = Invoke-Summary -Name 'monitor-exit' -Profile Cpu -Interval 1 -Fault 'monitor-exit'
    $monitorRuns = @(Import-Csv -LiteralPath (Join-Path $monitorOutput 'runs.csv'))
    $monitorRuntime = @($monitorRuns | Where-Object { $_.Build -eq 'runtime' })[0]
    Assert-That 'nonzero monitor exit invalidates run' ($monitorRuntime.Valid -eq 'False')
    Assert-That 'monitor exit failure reason is explicit' ($monitorRuntime.InvalidReason -match 'monitor exit code 1') $monitorRuntime.InvalidReason

    # A bad cadence during the measured phase must be caught even if the session-wide median is good.
    $cadenceOutput = Invoke-Summary -Name 'bad-load-cadence' -Profile Cpu -Interval 1 -Fault 'bad-load-cadence'
    $cadenceRuns = @(Import-Csv -LiteralPath (Join-Path $cadenceOutput 'runs.csv'))
    $cadencePlain = @($cadenceRuns | Where-Object { $_.Build -eq 'plain' })[0]
    Assert-That 'session-wide cadence median remains within nominal tolerance' ([Math]::Abs([double]$cadencePlain.IntervalMedianSeconds - 1.0) -le 0.2)
    Assert-That 'load-phase cadence median records the drift' ([double]$cadencePlain.LoadIntervalMedianSeconds -gt 1.2) $cadencePlain.LoadIntervalMedianSeconds
    Assert-That 'load-phase cadence drift invalidates the run' ($cadencePlain.Valid -eq 'False')
    Assert-That 'load-phase cadence reason is explicit' ($cadencePlain.InvalidReason -match 'load interval median') $cadencePlain.InvalidReason

    # A working-set gap is metric-specific too; CPU remains the primary metric in this profile.
    $wsOutput = Invoke-Summary -Name 'working-set-nan' -Profile Cpu -Interval 1 -Fault 'working-set-nan'
    $wsRuns = @(Import-Csv -LiteralPath (Join-Path $wsOutput 'runs.csv'))
    $wsRuntime = @($wsRuns | Where-Object { $_.Build -eq 'runtime' })[0]
    Assert-That 'working-set-only defect does not invalidate CPU run' ($wsRuntime.Valid -eq 'True') $wsRuntime.InvalidReason
    Assert-That 'working-set gap marks working-set metric invalid' ($wsRuntime.WorkingSetMetricsValid -eq 'False')

    Write-Host 'All summarizer quality tests passed.'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
