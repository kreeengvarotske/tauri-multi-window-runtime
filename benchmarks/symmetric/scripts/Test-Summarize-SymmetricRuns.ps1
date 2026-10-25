[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

$scriptDirectory = Split-Path -Parent $PSCommandPath
$summarizer = Join-Path $scriptDirectory 'Summarize-SymmetricRuns.ps1'
$root = Join-Path ([System.IO.Path]::GetTempPath()) ("symmetric-summarizer-test-{0}" -f [Guid]::NewGuid().ToString('N'))
$runsDirectory = Join-Path $root 'runs'
$outputDirectory = Join-Path $root 'analysis-test'
New-Item -ItemType Directory -Path $runsDirectory -Force | Out-Null

try {
    $epoch = [DateTimeOffset]::Parse('2026-10-25T00:00:00Z')
    $configuration = [ordered]@{
        profile = 'Cpu'
        phase = 'Pilot'
        sampleIntervalSeconds = 1
        gitHead = 'synthetic-test'
        os = 'Windows PowerShell summarizer test'
        pairs = 1
        firstPair = 1
        durationSeconds = 10
        idleSeconds = 10
        pauseSeconds = 0
        iterations = 1
        bufferMb = 4
        requestsPerWindow = 1
        roundIntervalMs = 500
    }
    $configuration | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $root 'configuration.json') -Encoding UTF8

    $schedule = New-Object System.Collections.Generic.List[object]
    $logEntries = New-Object System.Collections.Generic.List[object]
    foreach ($scenario in @('S1', 'S2', 'S3')) {
        foreach ($build in @('plain', 'runtime')) {
            $name = '{0}-pair01-{1}' -f $scenario, $build
            $schedule.Add([pscustomobject]@{
                Seq = $schedule.Count + 1
                Scenario = $scenario
                Pair = 1
                PositionInPair = $(if ($build -eq 'plain') { 1 } else { 2 })
                Build = $build
                Name = $name
            })

            $missingReport = $scenario -eq 'S3' -and $build -eq 'runtime'
            $monitorExit = if ($scenario -eq 'S1' -and $build -eq 'plain') { 1 } else { 0 }
            $appExit = if ($missingReport) { 1 } else { 0 }
            $logEntries.Add([pscustomobject][ordered]@{
                name = $name
                scenario = $scenario
                pair = 1
                build = $build
                exitCode = $appExit
                timedOut = $false
                monitorExit = $monitorExit
                monitorCpuSeconds = 0.1
                reportExists = (-not $missingReport)
            })

            if ($missingReport) { continue }

            $roundMs = [pscustomobject]@{ p50 = 100; p95 = 120; max = 150 }
            $report = [pscustomobject][ordered]@{
                schemaVersion = 1
                config = [pscustomobject]@{ scenario = $scenario; build = $build }
                phases = [pscustomobject]@{
                    expectedReadyAt = $epoch.ToString('o')
                    loadStartedAt = $epoch.AddSeconds(10).ToString('o')
                    loadEndedAt = $epoch.AddSeconds(20).ToString('o')
                    endedAt = $epoch.AddSeconds(30).ToString('o')
                }
                summary = [pscustomobject]@{
                    rounds = 20
                    passedRounds = 20
                    overruns = 0
                    requestsPerSecond = 2
                    roundMs = $roundMs
                }
                totals = [pscustomobject]@{
                    requestsReceived = 20
                    operationsExecuted = 20
                    coalescedRequests = 0
                    cacheHits = 0
                    failedRequests = 0
                }
                abort = $null
                passed = $true
            }
            $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runsDirectory "$name.json") -Encoding UTF8

            $times = New-Object System.Collections.Generic.List[double]
            if ($scenario -eq 'S2' -and $build -eq 'plain') {
                foreach ($value in 0..9) { $times.Add([double]$value) }
                foreach ($value in @(10.3, 11.6, 12.9, 14.2, 15.5, 16.8, 18.1, 19.4)) { $times.Add([double]$value) }
                foreach ($value in 21..30) { $times.Add([double]$value) }
            }
            else {
                foreach ($value in 0..30) { $times.Add([double]$value) }
            }

            $samples = New-Object System.Collections.Generic.List[object]
            for ($i = 0; $i -lt $times.Count; $i++) {
                $time = $times[$i]
                $interval = if ($i -eq 0) { 0.0 } elseif ($scenario -eq 'S2' -and $build -eq 'plain' -and $time -ge 10 -and $time -lt 20) { 1.3 } elseif ($scenario -eq 'S2' -and $build -eq 'plain' -and $time -eq 21) { 1.6 } else { 1.0 }
                $samples.Add([pscustomobject][ordered]@{
                    Timestamp = $epoch.AddSeconds($time).ToString('o')
                    RootPid = 123
                    ProcessCount = 1
                    WorkingSetMB = '120.000'
                    PrivateBytesMB = '100.000'
                    CpuDeltaSeconds = '0.100'
                    Sample = $i
                    IntervalSeconds = $interval.ToString('F3', [System.Globalization.CultureInfo]::InvariantCulture)
                    PrivateMissingCount = 0
                    CpuUnreadableCount = 0
                })
            }
            $samples | Export-Csv -LiteralPath (Join-Path $runsDirectory "$name.monitor.csv") -NoTypeInformation -Encoding UTF8
        }
    }
    $schedule | Export-Csv -LiteralPath (Join-Path $root 'schedule.csv') -NoTypeInformation -Encoding UTF8
    $logEntries | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content -LiteralPath (Join-Path $root 'runs.log') -Encoding UTF8

    & $summarizer -ResultsDirectory $root -OutputDirectory $outputDirectory

    $runs = @(Import-Csv -LiteralPath (Join-Path $outputDirectory 'runs.csv'))
    $pairs = @(Import-Csv -LiteralPath (Join-Path $outputDirectory 'pairs.csv'))
    Assert-True ($runs.Count -eq 6) "expected all six scheduled runs in runs.csv; found $($runs.Count)"

    $monitorFailure = @($runs | Where-Object { $_.Scenario -eq 'S1' -and $_.Build -eq 'plain' })[0]
    Assert-True ($monitorFailure.Valid -eq 'False') 'nonzero monitor exit must invalidate its run'
    Assert-True ($monitorFailure.InvalidReason -match 'monitor exit code 1') 'monitor failure reason must be explicit'

    $loadCadence = @($runs | Where-Object { $_.Scenario -eq 'S2' -and $_.Build -eq 'plain' })[0]
    Assert-True ([double]$loadCadence.IntervalMedianSeconds -lt 1.2) 'fixture must keep whole-session median within tolerance'
    Assert-True ([double]$loadCadence.LoadIntervalMedianSeconds -gt 1.2) 'fixture must make load-only median exceed tolerance'
    Assert-True ($loadCadence.Valid -eq 'False') 'bad cadence during the measured load must invalidate the run'
    Assert-True ($loadCadence.InvalidReason -match 'load interval median') 'load cadence failure reason must be explicit'

    $missing = @($runs | Where-Object { $_.Scenario -eq 'S3' -and $_.Build -eq 'runtime' })[0]
    Assert-True ($null -ne $missing) 'scheduled run with missing JSON must still appear in runs.csv'
    Assert-True ($missing.Valid -eq 'False') 'run with missing JSON must be invalid'
    Assert-True ($missing.InvalidReason -match 'JSON report missing') 'missing JSON reason must be explicit'

    foreach ($scenario in @('S1', 'S2', 'S3')) {
        $pair = @($pairs | Where-Object { $_.Scenario -eq $scenario })[0]
        Assert-True ($pair.Valid -eq 'False') "$scenario pair must be invalid when either side is invalid"
    }

    Write-Host 'PASS: summarizer preserves missing reports, checks monitor exit, and validates load-only cadence.'
}
finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
