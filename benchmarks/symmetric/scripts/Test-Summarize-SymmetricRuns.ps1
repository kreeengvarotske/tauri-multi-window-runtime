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

    # A missing primary hypothesis must remain in the predeclared Holm family with p=1.
    # One S1 metric has 10/10 signs; the other has 9/10. If unavailable S2-S4
    # hypotheses are incorrectly omitted, Holm over only two tests falsely declares both significant.
    $confirmRoot = Join-Path $root 'confirmatory'
    $confirmRuns = Join-Path $confirmRoot 'runs'
    $confirmAnalysis = Join-Path $confirmRoot 'analysis-test'
    New-Item -ItemType Directory -Path $confirmRuns -Force | Out-Null
    $confirmConfiguration = [ordered]@{
        profile = 'Cpu'
        phase = 'Confirmatory'
        sampleIntervalSeconds = 1
        gitHead = 'synthetic-test'
        os = 'Windows PowerShell summarizer test'
        machine = 'fixture'
        pairs = 10
        firstPair = 1
        durationSeconds = 10
        idleSeconds = 10
        pauseSeconds = 0
        iterations = 1
        bufferMb = 4
        requestsPerWindow = 10
        roundIntervalMs = 500
        plainExeSha256 = 'plain'
        runtimeExeSha256 = 'runtime'
        monitorSha256 = 'monitor'
        runScriptSha256 = 'runner'
        summarizeScriptSha256 = 'summarizer'
        protocolSha256 = 'protocol'
        order = 'alternating'
    }
    $confirmConfiguration | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $confirmRoot 'configuration.json') -Encoding UTF8

    $confirmSchedule = New-Object System.Collections.Generic.List[object]
    $confirmLogs = New-Object System.Collections.Generic.List[object]
    foreach ($scenario in @('S1', 'S2', 'S3', 'S4')) {
        for ($pairNumber = 1; $pairNumber -le 10; $pairNumber++) {
            $buildOrder = if ($pairNumber % 2 -eq 1) { @('plain', 'runtime') } else { @('runtime', 'plain') }
            foreach ($buildName in $buildOrder) {
                $name = '{0}-pair{1:D2}-{2}' -f $scenario, $pairNumber, $buildName
                $confirmSchedule.Add([pscustomobject]@{
                    Seq = $confirmSchedule.Count + 1
                    Scenario = $scenario
                    Pair = $pairNumber
                    PositionInPair = $(if ($buildName -eq $buildOrder[0]) { 1 } else { 2 })
                    Build = $buildName
                    Name = $name
                })
                $validScenario = $scenario -eq 'S1'
                $confirmLogs.Add([pscustomobject][ordered]@{
                    name = $name
                    scenario = $scenario
                    pair = $pairNumber
                    build = $buildName
                    exitCode = $(if ($validScenario) { 0 } else { 1 })
                    timedOut = $false
                    monitorExit = 0
                    monitorCpuSeconds = 0.1
                    reportExists = $validScenario
                })
                if (-not $validScenario) { continue }

                $privateMb = if ($buildName -eq 'plain') { 100.0 } elseif ($pairNumber -eq 10) { 110.0 } else { 90.0 }
                $cpuEachSample = if ($buildName -eq 'plain') { 0.100 } else { 0.080 }
                $confirmReport = [pscustomobject][ordered]@{
                    schemaVersion = 1
                    config = [pscustomobject]@{ scenario = $scenario; build = $buildName }
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
                        requestsPerSecond = 20
                        roundMs = [pscustomobject]@{ p50 = 100; p95 = 120; max = 150 }
                    }
                    totals = [pscustomobject]@{
                        requestsReceived = 200
                        operationsExecuted = $(if ($buildName -eq 'plain') { 200 } else { 20 })
                        coalescedRequests = $(if ($buildName -eq 'plain') { 0 } else { 180 })
                        cacheHits = 0
                        failedRequests = 0
                    }
                    abort = $null
                    passed = $true
                }
                $confirmReport | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $confirmRuns "$name.json") -Encoding UTF8

                $confirmSamples = New-Object System.Collections.Generic.List[object]
                for ($sampleIndex = 0; $sampleIndex -le 30; $sampleIndex++) {
                    $confirmSamples.Add([pscustomobject][ordered]@{
                        Timestamp = $epoch.AddSeconds($sampleIndex).ToString('o')
                        RootPid = 456
                        ProcessCount = 3
                        WorkingSetMB = '120.000'
                        PrivateBytesMB = $privateMb.ToString('F3', [System.Globalization.CultureInfo]::InvariantCulture)
                        CpuDeltaSeconds = $cpuEachSample.ToString('F3', [System.Globalization.CultureInfo]::InvariantCulture)
                        Sample = $sampleIndex
                        IntervalSeconds = $(if ($sampleIndex -eq 0) { '0.000' } else { '1.000' })
                        PrivateMissingCount = 0
                        CpuUnreadableCount = 0
                    })
                }
                $confirmSamples | Export-Csv -LiteralPath (Join-Path $confirmRuns "$name.monitor.csv") -NoTypeInformation -Encoding UTF8
            }
        }
    }
    $confirmSchedule | Export-Csv -LiteralPath (Join-Path $confirmRoot 'schedule.csv') -NoTypeInformation -Encoding UTF8
    $confirmLogs | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content -LiteralPath (Join-Path $confirmRoot 'runs.log') -Encoding UTF8

    & $summarizer -ResultsDirectory $confirmRoot -OutputDirectory $confirmAnalysis
    $confirmSummary = @(Import-Csv -LiteralPath (Join-Path $confirmAnalysis 'summary.csv'))
    $allSigns = @($confirmSummary | Where-Object { $_.Look -eq 'look1' -and $_.Scenario -eq 'S1' -and $_.Metric -eq 'LoadCpuSeconds' })[0]
    $nineSigns = @($confirmSummary | Where-Object { $_.Look -eq 'look1' -and $_.Scenario -eq 'S1' -and $_.Metric -eq 'LoadPrivateMBAvg' })[0]
    Assert-True ([double]$allSigns.PHolm -lt 0.025) '10/10 consistent signs must survive Holm correction over the full 8-test family'
    Assert-True ($allSigns.Decided -eq 'True') '10/10 result should be decided at look 1 in the synthetic fixture'
    Assert-True ([double]$nineSigns.PHolm -ge 0.025) '9/10 signs must not survive Holm correction when the other six hypotheses have insufficient data'
    Assert-True ($nineSigns.Decided -eq 'False') '9/10 result must remain undecided when correction includes the full family'

    # Look 2 must never silently re-test look 1 data if the extension omitted a
    # scenario that still has undecided primary metrics.
    $extensionRoot = Join-Path $root 'incomplete-extension'
    $extensionRuns = Join-Path $extensionRoot 'runs'
    $extensionAnalysis = Join-Path $extensionRoot 'analysis-test'
    New-Item -ItemType Directory -Path $extensionRuns -Force | Out-Null
    $extensionConfiguration = [ordered]@{}
    foreach ($entry in $confirmConfiguration.GetEnumerator()) { $extensionConfiguration[$entry.Key] = $entry.Value }
    $extensionConfiguration['firstPair'] = 11
    $extensionConfiguration['pairs'] = 10
    $extensionConfiguration['scenarios'] = @('S2')
    $extensionConfiguration | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $extensionRoot 'configuration.json') -Encoding UTF8

    $extensionSchedule = New-Object System.Collections.Generic.List[object]
    foreach ($pairNumber in 11..20) {
        $order = if ($pairNumber % 2 -eq 1) { @('plain', 'runtime') } else { @('runtime', 'plain') }
        for ($position = 0; $position -lt 2; $position++) {
            $build = $order[$position]
            $extensionSchedule.Add([pscustomobject]@{
                Seq = $extensionSchedule.Count + 1
                Scenario = 'S2'
                Pair = $pairNumber
                PositionInPair = $position + 1
                Build = $build
                Name = ('S2-pair{0:D2}-{1}' -f $pairNumber, $build)
            })
        }
    }
    $extensionSchedule | Export-Csv -LiteralPath (Join-Path $extensionRoot 'schedule.csv') -NoTypeInformation -Encoding UTF8

    $extensionError = $null
    try {
        & $summarizer -ResultsDirectory $confirmRoot -ExtensionDirectory $extensionRoot -OutputDirectory $extensionAnalysis
    }
    catch {
        $extensionError = $_.Exception.Message
    }
    Assert-True ($extensionError -match 'extension scenarios must exactly match') 'look 2 must reject an extension that omits scenarios with undecided hypotheses'

    Write-Host 'PASS: summarizer preserves failed runs, validates monitor data, applies full-family Holm, and refuses incomplete look-2 extensions.'
}
finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
