<#
.SYNOPSIS
Tests the statistics of Summarize-SymmetricRuns.ps1: the sign test, the median
interval (including zero differences and ties), its coverage by simulation,
and an end-to-end summary of synthetic Cpu and Ram results as one family.

.DESCRIPTION
Runs in Windows PowerShell 5.1 and PowerShell 7. Writes synthetic data only to
a new temporary directory and removes it at the end. Exits 1 on any failure.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$culture = [System.Globalization.CultureInfo]::InvariantCulture
if (-not ('SymmetricBenchStats' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'SymmetricBenchStats.cs')
}
$failures = New-Object System.Collections.Generic.List[string]

function Assert-Near {
    param([string]$Name, [double]$Actual, [double]$Expected, [double]$Tolerance = 1e-12)
    if ([double]::IsNaN($Actual) -or [Math]::Abs($Actual - $Expected) -gt $Tolerance) { $failures.Add("${Name}: expected $Expected, got $Actual") }
    else { Write-Host "ok   $Name" }
}

function ConvertTo-Double {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return [double]::NaN }
    return [double]::Parse($Text, $culture)
}

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if (-not $Condition) { $failures.Add("${Name}: $Detail") } else { Write-Host "ok   $Name" }
}

# --- Sign test and binomial tail.
Assert-Near 'P(Bin(10,1/2) <= 1) = 11/1024' ([SymmetricBenchStats]::BinomialHalfCdf(10, 1)) (11 / 1024)
Assert-Near 'P(Bin(20,1/2) <= 3) = 1351/2^20' ([SymmetricBenchStats]::BinomialHalfCdf(20, 3)) (1351 / 1048576)
Assert-Near 'sign test, 10 of 10 positive' ([SymmetricBenchStats]::SignTestP([double[]](1..10))) (2 / 1024)
Assert-Near 'sign test drops zeros: + + + - 0 0 -> n = 4' ([SymmetricBenchStats]::SignTestP([double[]]@(1, 2, 3, -1, 0, 0))) (2 * 5 / 16)
Assert-Near 'sign test, only zeros' ([SymmetricBenchStats]::SignTestP([double[]]@(0, 0, 0))) 1
Assert-Near 'sign test, 5 + / 5 -' ([SymmetricBenchStats]::SignTestP([double[]]@(1, -1, 2, -2, 3, -3, 4, -4, 5, -5))) 1

# --- Median interval: order statistics over all differences, zeros included.
$interval = [SymmetricBenchStats]::MedianInterval([double[]]@(10, 9, 8, 7, 6, 5, 4, 3, 2, 1), 0.975)
Assert-Near 'interval n = 10 at 97.5%: low = d(2)' $interval[0] 2
Assert-Near 'interval n = 10 at 97.5%: high = d(9)' $interval[1] 9
Assert-Near 'interval n = 10 at 97.5%: minimum coverage' $interval[2] (1 - 22 / 1024)
$mixed = [double[]]@(0, 0, 0, 1.25, 2.5, -1.75, 0, 3, 0, 0)
$interval = [SymmetricBenchStats]::MedianInterval($mixed, 0.975)
Assert-Near 'mixed + / - / 0: low' $interval[0] 0
Assert-Near 'mixed + / - / 0: high' $interval[1] 2.5
Assert-Near 'mixed + / - / 0: zero count' ([SymmetricBenchStats]::CountZeros($mixed)) 6
Assert-Near 'mixed + / - / 0: sign test over the 4 non-zero' ([SymmetricBenchStats]::SignTestP($mixed)) (2 * 5 / 16)
Assert-Near 'mixed + / - / 0: median' ([SymmetricBenchStats]::Median($mixed)) 0
Assert-True 'interval is null when n is too small' ($null -eq [SymmetricBenchStats]::MedianInterval([double[]]@(1, 2, 3, 4, 5), 0.95))

# --- Coverage by simulation: at least the stated minimum with ties, close to it without.
$random = New-Object System.Random 20261025
$reps = 4000
$n = 10
$level = 0.975
$stated = [SymmetricBenchStats]::MedianInterval([double[]](1..$n), $level)[2]
$sample = New-Object double[] $n
foreach ($case in @('ties', 'continuous')) {
    $covered = 0
    for ($r = 0; $r -lt $reps; $r++) {
        for ($i = 0; $i -lt $n; $i++) {
            $u = $random.NextDouble()
            # ties: -1 / 0 / 1 with probabilities 0.2 / 0.4 / 0.4, median 0; continuous: uniform(-1, 1), median 0.
            $sample[$i] = if ($case -eq 'ties') { if ($u -lt 0.2) { -1.0 } elseif ($u -lt 0.6) { 0.0 } else { 1.0 } } else { 2 * $u - 1 }
        }
        $ci = [SymmetricBenchStats]::MedianInterval($sample, $level)
        if ($ci[0] -le 0 -and 0 -le $ci[1]) { $covered++ }
    }
    $observed = $covered / $reps
    # 4 binomial standard errors of slack for the simulation.
    $slack = 4 * [Math]::Sqrt($stated * (1 - $stated) / $reps)
    Assert-True "coverage with $case >= stated $([Math]::Round($stated, 4))" ($observed -ge $stated - $slack) "observed $observed"
    if ($case -eq 'continuous') { Assert-True 'coverage without ties is close to the stated value' ([Math]::Abs($observed - $stated) -le $slack) "observed $observed" }
}

# --- End to end: synthetic Cpu and Ram results, one family, zero differences, raw precision.
$root = Join-Path ([System.IO.Path]::GetTempPath()) ("symmetric-stats-test-{0}" -f [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $start0 = [DateTimeOffset]::new(2026, 10, 25, 12, 0, 0, [TimeSpan]::Zero)
    function New-SyntheticResults {
        param([string]$Directory, [string]$MonitorProfile, [double]$Interval)
        $runs = Join-Path $Directory 'runs'
        New-Item -ItemType Directory -Path $runs | Out-Null
        [ordered]@{
            profile = $MonitorProfile; phase = 'Confirmatory'; machine = 'SYNTHETIC'; gitHead = 'synthetic'; os = 'synthetic'
            plainExeSha256 = 'p'; runtimeExeSha256 = 'r'; monitorSha256 = $MonitorProfile; sampleIntervalSeconds = $Interval
            durationSeconds = 20; idleSeconds = 2; pauseSeconds = 0; iterations = 1; bufferMb = 4; requestsPerWindow = 10; roundIntervalMs = 500
            pairs = 10; firstPair = 1
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Directory 'configuration.json') -Encoding UTF8
        $schedule = New-Object System.Collections.Generic.List[object]
        foreach ($scenario in @('S1', 'S2')) {
            for ($pair = 1; $pair -le 10; $pair++) {
                $order = if ($pair % 2 -eq 1) { @('plain', 'runtime') } else { @('runtime', 'plain') }
                for ($position = 1; $position -le 2; $position++) {
                    $schedule.Add([pscustomobject][ordered]@{ Seq = $schedule.Count + 1; Scenario = $scenario; Pair = $pair; PositionInPair = $position; Build = $order[$position - 1]
                            Name = ('{0}-pair{1:D2}-{2}' -f $scenario, $pair, $order[$position - 1]) })
                }
            }
        }
        $schedule | Export-Csv -LiteralPath (Join-Path $Directory 'schedule.csv') -NoTypeInformation -Encoding UTF8
        $log = New-Object System.Collections.Generic.List[string]
        $clock = $start0
        foreach ($run in $schedule) {
            $start = $clock; $clock = $clock.AddSeconds(30)
            $phases = [ordered]@{ expectedReadyAt = $start.AddSeconds(1).ToString('o'); loadStartedAt = $start.AddSeconds(3).ToString('o'); loadEndedAt = $start.AddSeconds(23).ToString('o'); endedAt = $start.AddSeconds(25).ToString('o') }
            [ordered]@{
                schemaVersion = 1; passed = $true; config = @{ build = $run.Build; scenario = $run.Scenario }
                summary = @{ rounds = 40; passedRounds = 40; overruns = 0; requestsPerSecond = 40.0; roundMs = @{ p50 = 300; p95 = 400 } }
                totals = @{ requestsReceived = 800; operationsExecuted = 800; coalescedRequests = 0; cacheHits = 0; failedRequests = 0 }
                phases = $phases; abort = $null
            } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $runs "$($run.Name).json") -Encoding UTF8
            # S1: Private identical in both builds for pairs 1-4 (zero differences), else a small offset.
            # S2: runtime clearly lower. Values have more than 2 decimals on purpose.
            $privateMb = 200.123456
            if ($run.Build -eq 'runtime') {
                if ($run.Scenario -eq 'S2') { $privateMb -= 30.000001 * (1 + $run.Pair / 100) }
                elseif ($run.Pair -gt 4) { $privateMb += $(if ($run.Pair % 2 -eq 0) { 0.004321 } else { -0.003217 }) }
            }
            $cpuPerSecond = if ($run.Build -eq 'runtime' -and $run.Scenario -eq 'S2') { 0.333333 } else { 1.0 + $run.Pair / 1000 }
            $rows = New-Object System.Collections.Generic.List[string]
            $rows.Add('"Timestamp","RootPid","ProcessCount","WorkingSetMB","PrivateBytesMB","CpuDeltaSeconds","Sample","IntervalSeconds","PrivateMissingCount","CpuUnreadableCount"')
            $count = [int](25 / $Interval)
            for ($i = 0; $i -le $count; $i++) {
                $time = $start.AddSeconds($i * $Interval + $Interval / 2).ToString('o')
                $cpu = if ($i -eq 0) { '' } else { ($cpuPerSecond * $Interval).ToString('R', $culture) }
                $intervalText = if ($i -eq 0) { '' } else { $Interval.ToString('R', $culture) }
                $rows.Add(('"{0}","1000","6","300","{1}","{2}","{3}","{4}","0","0"' -f $time, $privateMb.ToString('R', $culture), $cpu, $i, $intervalText))
            }
            $rows | Set-Content -LiteralPath (Join-Path $runs "$($run.Name).monitor.csv") -Encoding UTF8
            $log.Add((@{ name = $run.Name; exitCode = 0; timedOut = $false; monitorCpuSeconds = 1.0 } | ConvertTo-Json -Compress))
        }
        $log | Set-Content -LiteralPath (Join-Path $Directory 'runs.log') -Encoding UTF8
    }
    $cpuDirectory = Join-Path $root 'cpu'; $ramDirectory = Join-Path $root 'ram'
    New-SyntheticResults -Directory $cpuDirectory -MonitorProfile 'Cpu' -Interval 1
    New-SyntheticResults -Directory $ramDirectory -MonitorProfile 'Ram' -Interval 0.2
    $summarize = Join-Path $PSScriptRoot 'Summarize-SymmetricRuns.ps1'
    $output = Join-Path $root 'analysis'
    & $summarize -ResultsDirectory $cpuDirectory, $ramDirectory -OutputDirectory $output | Out-Null

    $summary = @(Import-Csv -LiteralPath (Join-Path $output 'summary.csv'))
    $primary = @($summary | Where-Object { $_.Role -eq 'primary' })
    Assert-True 'family: 4 primary tests over both profiles' ($primary.Count -eq 4) "got $(($primary | ForEach-Object { "$($_.Profile)/$($_.Scenario)/$($_.Metric)" }) -join ', ')"
    Assert-True 'family: Cpu tests LoadCpuSeconds, Ram tests LoadPrivateMBAvg' (@($primary | Where-Object { -not (($_.Profile -eq 'Cpu' -and $_.Metric -eq 'LoadCpuSeconds') -or ($_.Profile -eq 'Ram' -and $_.Metric -eq 'LoadPrivateMBAvg')) }).Count -eq 0)
    $s2 = @($primary | Where-Object { $_.Scenario -eq 'S2' })
    foreach ($row in $s2) {
        Assert-Near "$($row.Profile) S2: p = 2/1024" (ConvertTo-Double $row.P) (2 / 1024)
        Assert-Near "$($row.Profile) S2: Holm over the joint family of 4" (ConvertTo-Double $row.PHolm) (4 * 2 / 1024)
        Assert-True "$($row.Profile) S2: runtime lower" ($row.Verdict -eq 'runtime lower') "verdict '$($row.Verdict)'"
    }
    $ramS1 = @($primary | Where-Object { $_.Profile -eq 'Ram' -and $_.Scenario -eq 'S1' })[0]
    Assert-True 'Ram S1: 4 zero differences counted' ($ramS1.ZeroDiffs -eq '4') "got $($ramS1.ZeroDiffs)"
    Assert-Near 'Ram S1: sign test over the 6 non-zero differences (3 + / 3 -)' (ConvertTo-Double $ramS1.P) 1
    Assert-True 'Ram S1: not decided at look 1' ($ramS1.Verdict -like '*undecided*') "verdict '$($ramS1.Verdict)'"

    $pairs = @(Import-Csv -LiteralPath (Join-Path $output 'pairs.csv') | Where-Object { $_.Profile -eq 'Ram' -and $_.Scenario -eq 'S1' -and $_.Pair -eq '6' })[0]
    $expectedDiff = (200.123456 + 0.004321) - 200.123456
    Assert-Near 'pairs.csv keeps full precision (no rounding before statistics)' (ConvertTo-Double $pairs.LoadPrivateMBAvg) $expectedDiff 1e-9

    $threw = $false
    try { & $summarize -ResultsDirectory $cpuDirectory -OutputDirectory (Join-Path $root 'single') | Out-Null } catch { $threw = $_.Exception.Message -like '*one Cpu and one Ram*' }
    Assert-True 'confirmatory with one profile only is refused' $threw
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host "FAIL $failure" }
    exit 1
}
Write-Host 'All statistics tests passed.'
