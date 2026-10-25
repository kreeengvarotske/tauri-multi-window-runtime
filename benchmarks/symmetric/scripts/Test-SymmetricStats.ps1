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
Assert-Near 'sign test without zeros equals the classic one: 8 + / 2 -' ([SymmetricBenchStats]::SignTestP([double[]]@(1, 2, 3, 4, 5, 6, 7, 8, -1, -2))) (2 * 56 / 1024)
Assert-Near 'sign test keeps zeros in n: + + + - 0 0' ([SymmetricBenchStats]::SignTestP([double[]]@(1, 2, 3, -1, 0, 0))) 1
$tenAndZeros = [double[]]@(@(1..10) + @(0) * 10)
Assert-Near '10 positive + 10 exact zeros is no 10/10 evidence: p = 2 P(Bin(20) >= 10), capped at 1' ([SymmetricBenchStats]::SignTestP($tenAndZeros)) 1
Assert-Near '17 positive + 3 zeros: p = 2 P(Bin(20) >= 17)' ([SymmetricBenchStats]::SignTestP([double[]]@(@(1..17) + @(0) * 3))) (2 * 1351 / 1048576)
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
Assert-Near 'mixed + / - / 0: sign test keeps the 6 zeros in n = 10' ([SymmetricBenchStats]::SignTestP($mixed)) 1
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

# --- Sign test level with an atom at zero: P(-1) = 0.1, P(0) = 0.45, P(+1) = 0.45, so 0 is the
# median, yet the non-zero signs are 82% positive. The test must still reject at most 5%.
$rejected = 0; $rejectedDroppingZeros = 0
$sample = New-Object double[] 20
for ($r = 0; $r -lt $reps; $r++) {
    for ($i = 0; $i -lt 20; $i++) { $u = $random.NextDouble(); $sample[$i] = if ($u -lt 0.1) { -1.0 } elseif ($u -lt 0.55) { 0.0 } else { 1.0 } }
    if ([SymmetricBenchStats]::SignTestP($sample) -lt 0.05) { $rejected++ }
    $nonZero = [double[]]@($sample | Where-Object { $_ -ne 0 })
    if ($nonZero.Count -gt 0 -and [SymmetricBenchStats]::SignTestP($nonZero) -lt 0.05) { $rejectedDroppingZeros++ }
}
$slack = 4 * [Math]::Sqrt(0.05 * 0.95 / $reps)
Assert-True 'atom at zero: rejection rate <= 5%' ($rejected / $reps -le 0.05 + $slack) "rate $($rejected / $reps)"
Assert-True 'atom at zero: dropping zeros would not hold the level (the case this guards)' ($rejectedDroppingZeros / $reps -gt 0.2) "rate $($rejectedDroppingZeros / $reps)"

# --- End to end: synthetic Cpu and Ram results as one family of 8, with failed and broken runs.
$root = Join-Path ([System.IO.Path]::GetTempPath()) ("symmetric-stats-test-{0}" -f [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $start0 = [DateTimeOffset]::new(2026, 10, 25, 12, 0, 0, [TimeSpan]::Zero)
    function New-SyntheticResults {
        # Mutations: run name -> one of NoReport, AppExit, MonitorExit, NaNPrivate, BadPrivate, NaNWorkingSet, ZeroInterval, SlowLoadInterval, CpuUnreadable.
        param([string]$Directory, [string]$MonitorProfile, [double]$Interval, [string[]]$Scenarios = @('S1', 'S2', 'S3', 'S4'),
            [int]$FirstPair = 1, [int[]]$SkipPairs = @(), [hashtable]$Mutations = @{})
        $runs = Join-Path $Directory 'runs'
        New-Item -ItemType Directory -Path $runs | Out-Null
        [ordered]@{
            profile = $MonitorProfile; phase = 'Confirmatory'; machine = 'SYNTHETIC'; gitHead = 'synthetic'; os = 'synthetic'
            plainExeSha256 = 'p'; runtimeExeSha256 = 'r'; monitorSha256 = $MonitorProfile; sampleIntervalSeconds = $Interval
            durationSeconds = 20; idleSeconds = 2; pauseSeconds = 0; iterations = 1; bufferMb = 4; requestsPerWindow = 10; roundIntervalMs = 500
            scenarios = $Scenarios; pairs = 10; firstPair = $FirstPair; order = 'fixed'; runScriptSha256 = 'run'; summarizeScriptSha256 = 'sum'; protocolSha256 = 'readme'
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Directory 'configuration.json') -Encoding UTF8
        $schedule = New-Object System.Collections.Generic.List[object]
        foreach ($scenario in $Scenarios) {
            for ($pair = $FirstPair; $pair -lt $FirstPair + 10; $pair++) {
                if ($SkipPairs -contains $pair) { continue }
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
            $mutation = [string]$Mutations[$run.Name]
            $start = $clock; $clock = $clock.AddSeconds(30)
            $phases = [ordered]@{ expectedReadyAt = $start.AddSeconds(1).ToString('o'); loadStartedAt = $start.AddSeconds(3).ToString('o'); loadEndedAt = $start.AddSeconds(23).ToString('o'); endedAt = $start.AddSeconds(25).ToString('o') }
            if ($mutation -ne 'NoReport') {
                [ordered]@{
                    schemaVersion = 1; passed = $true; config = @{ build = $run.Build; scenario = $run.Scenario }
                    summary = @{ rounds = 40; passedRounds = 40; overruns = 0; requestsPerSecond = 40.0; roundMs = @{ p50 = 300; p95 = 400 } }
                    totals = @{ requestsReceived = 800; operationsExecuted = 800; coalescedRequests = 0; cacheHits = 0; failedRequests = 0 }
                    phases = $phases; abort = $null
                } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $runs "$($run.Name).json") -Encoding UTF8
            }
            # S1: Private identical in both builds for pairs 1-4 (zero differences), else a small offset.
            # S2, S4: runtime clearly lower. S3: noise. Values have more than 2 decimals on purpose.
            $privateMb = 200.123456
            if ($run.Build -eq 'runtime') {
                if (@('S2', 'S4') -contains $run.Scenario) { $privateMb -= 30.000001 * (1 + $run.Pair / 100) }
                elseif ($run.Scenario -eq 'S3') { $privateMb += $(if ($run.Pair % 2 -eq 0) { 0.5 } else { -0.4 }) * $run.Pair / 10 }
                elseif ($run.Pair -gt 4) { $privateMb += $(if ($run.Pair % 2 -eq 0) { 0.004321 } else { -0.003217 }) }
            }
            $cpuPerSecond = if ($run.Build -eq 'runtime' -and @('S2', 'S4') -contains $run.Scenario) { 0.333333 } else { 1.0 + $run.Pair / 1000 }
            $rows = New-Object System.Collections.Generic.List[string]
            $rows.Add('"Timestamp","RootPid","ProcessCount","WorkingSetMB","PrivateBytesMB","CpuDeltaSeconds","Sample","IntervalSeconds","PrivateMissingCount","CpuUnreadableCount"')
            $count = [int](25 / $Interval)
            for ($i = 0; $i -le $count; $i++) {
                $offset = $i * $Interval + $Interval / 2
                $inLoad = $offset -ge 3 -and $offset -lt 23
                $time = $start.AddSeconds($offset).ToString('o')
                $cpu = if ($i -eq 0) { '' } else { ($cpuPerSecond * $Interval).ToString('R', $culture) }
                $intervalValue = $Interval
                if ($inLoad -and $mutation -eq 'SlowLoadInterval') { $intervalValue = 1.3 * $Interval }
                $intervalText = if ($i -eq 0) { '' } elseif ($inLoad -and $mutation -eq 'ZeroInterval' -and $i % 7 -eq 0) { '0' } else { $intervalValue.ToString('R', $culture) }
                $privateText = if ($inLoad -and @('NaNPrivate', 'BadPrivate') -contains $mutation -and $i % 9 -eq 0) {
                    if ($mutation -eq 'BadPrivate') { 'not-a-number' } else { 'NaN' }
                } else { $privateMb.ToString('R', $culture) }
                $workingSetText = if ($inLoad -and $mutation -eq 'NaNWorkingSet' -and $i % 9 -eq 0) { 'NaN' } else { '300' }
                $cpuUnreadable = if ($inLoad -and $mutation -eq 'CpuUnreadable' -and $i % 5 -eq 0) { '1' } else { '0' }
                if ($cpuUnreadable -eq '1') { $cpu = '' }
                $rows.Add(('"{0}","1000","6","{1}","{2}","{3}","{4}","{5}","0","{6}"' -f $time, $workingSetText, $privateText, $cpu, $i, $intervalText, $cpuUnreadable))
            }
            $rows | Set-Content -LiteralPath (Join-Path $runs "$($run.Name).monitor.csv") -Encoding UTF8
            $exitCode = if ($mutation -eq 'AppExit' -or $mutation -eq 'NoReport') { 1 } else { 0 }
            $monitorExit = if ($mutation -eq 'MonitorExit') { 1 } else { 0 }
            $log.Add((@{ name = $run.Name; exitCode = $exitCode; timedOut = $false; monitorExit = $monitorExit; monitorCpuSeconds = 1.0 } | ConvertTo-Json -Compress))
        }
        $log | Set-Content -LiteralPath (Join-Path $Directory 'runs.log') -Encoding UTF8
    }
    $summarize = Join-Path $PSScriptRoot 'Summarize-SymmetricRuns.ps1'
    $cpuDirectory = Join-Path $root 'cpu'; $ramDirectory = Join-Path $root 'ram'
    $cpuMutations = @{
        'S1-pair05-plain' = 'CpuUnreadable'
        'S1-pair06-runtime' = 'NaNPrivate'
        'S1-pair07-runtime' = 'BadPrivate'
        'S1-pair08-runtime' = 'NaNWorkingSet'
    }
    foreach ($pair in 1..10) { foreach ($build in 'plain', 'runtime') { $cpuMutations[('S3-pair{0:D2}-{1}' -f $pair, $build)] = 'AppExit' } }
    New-SyntheticResults -Directory $cpuDirectory -MonitorProfile 'Cpu' -Interval 1 -Mutations $cpuMutations
    New-SyntheticResults -Directory $ramDirectory -MonitorProfile 'Ram' -Interval 0.2 -Mutations @{
        'S1-pair09-runtime' = 'NoReport'; 'S3-pair01-plain' = 'MonitorExit'; 'S3-pair02-runtime' = 'NaNPrivate'
        'S3-pair03-plain' = 'ZeroInterval'; 'S3-pair04-plain' = 'SlowLoadInterval'; 'S4-pair05-runtime' = 'CpuUnreadable'
    }
    $output = Join-Path $root 'analysis'
    & $summarize -ResultsDirectory $cpuDirectory, $ramDirectory -OutputDirectory $output | Out-Null

    $summary = @(Import-Csv -LiteralPath (Join-Path $output 'summary.csv'))
    $primary = @($summary | Where-Object { $_.Role -eq 'primary' })
    Assert-True 'family: 8 primary hypotheses over both profiles' ($primary.Count -eq 8) "got $(($primary | ForEach-Object { "$($_.Profile)/$($_.Scenario)/$($_.Metric)" }) -join ', ')"
    Assert-True 'family: Cpu tests LoadCpuSeconds, Ram tests LoadPrivateMBAvg' (@($primary | Where-Object { -not (($_.Profile -eq 'Cpu' -and $_.Metric -eq 'LoadCpuSeconds') -or ($_.Profile -eq 'Ram' -and $_.Metric -eq 'LoadPrivateMBAvg')) }).Count -eq 0)
    foreach ($row in @($primary | Where-Object { @('S2', 'S4') -contains $_.Scenario })) {
        Assert-Near "$($row.Profile) $($row.Scenario): p = 2/1024" (ConvertTo-Double $row.P) (2 / 1024)
        Assert-Near "$($row.Profile) $($row.Scenario): Holm over all 8, the one without data included" (ConvertTo-Double $row.PHolm) (8 * 2 / 1024)
        Assert-True "$($row.Profile) $($row.Scenario): runtime lower" ($row.Verdict -eq 'runtime lower') "verdict '$($row.Verdict)'"
    }
    $cpuS3 = @($primary | Where-Object { $_.Profile -eq 'Cpu' -and $_.Scenario -eq 'S3' })[0]
    Assert-True 'Cpu S3 without valid pairs stays in the family' ($cpuS3.ValidPairs -eq '0' -and (ConvertTo-Double $cpuS3.PHolm) -eq 1) "valid $($cpuS3.ValidPairs), PHolm '$($cpuS3.PHolm)', verdict '$($cpuS3.Verdict)'"
    $ramS1 = @($primary | Where-Object { $_.Profile -eq 'Ram' -and $_.Scenario -eq 'S1' })[0]
    Assert-True 'Ram S1: 9 valid pairs, 4 zero differences' ($ramS1.ValidPairs -eq '9' -and $ramS1.ZeroDiffs -eq '4') "valid $($ramS1.ValidPairs), zeros $($ramS1.ZeroDiffs)"
    Assert-True 'Ram S1: not decided at look 1' ($ramS1.Verdict -like '*undecided*') "verdict '$($ramS1.Verdict)'"

    $runRows = @(Import-Csv -LiteralPath (Join-Path $output 'runs.csv'))
    function Get-Run { param([string]$Profile, [string]$Scenario, [int]$Pair, [string]$Build) @($runRows | Where-Object { $_.Profile -eq $Profile -and $_.Scenario -eq $Scenario -and [int]$_.Pair -eq $Pair -and $_.Build -eq $Build }) }

    # In Cpu profile, incomplete secondary memory data must not discard a valid CPU run,
    # but it must be excluded from the private-memory metric's own pair set.
    $cpuPrivateNaN = @(Get-Run 'Cpu' 'S1' 6 'runtime')
    Assert-True 'NaN private secondary sample does not invalidate Cpu-primary run' ($cpuPrivateNaN.Count -eq 1 -and $cpuPrivateNaN[0].Valid -eq 'True') "reason '$(if ($cpuPrivateNaN.Count) { $cpuPrivateNaN[0].InvalidReason })'"
    $cpuPrivateBad = @(Get-Run 'Cpu' 'S1' 7 'runtime')
    Assert-True 'malformed numeric secondary sample does not crash or invalidate Cpu-primary run' ($cpuPrivateBad.Count -eq 1 -and $cpuPrivateBad[0].Valid -eq 'True') "reason '$(if ($cpuPrivateBad.Count) { $cpuPrivateBad[0].InvalidReason })'"
    $cpuWorkingSetBad = @(Get-Run 'Cpu' 'S1' 8 'runtime')
    Assert-True 'NaN working-set secondary sample does not invalidate Cpu-primary run' ($cpuWorkingSetBad.Count -eq 1 -and $cpuWorkingSetBad[0].Valid -eq 'True') "reason '$(if ($cpuWorkingSetBad.Count) { $cpuWorkingSetBad[0].InvalidReason })'"
    $cpuPrivateSecondary = @($summary | Where-Object { $_.Look -eq 'look1' -and $_.Profile -eq 'Cpu' -and $_.Scenario -eq 'S1' -and $_.Metric -eq 'LoadPrivateMBAvg' })[0]
    Assert-True 'private secondary metric excludes both malformed/non-finite pairs only' ($cpuPrivateSecondary.ValidPairs -eq '7' -and $cpuPrivateSecondary.MetricExcludedPairs -eq '2' -and $cpuPrivateSecondary.InvalidPairs -eq '1') "valid $($cpuPrivateSecondary.ValidPairs), metric-excluded $($cpuPrivateSecondary.MetricExcludedPairs), invalid $($cpuPrivateSecondary.InvalidPairs)"
    $cpuWorkingSetSecondary = @($summary | Where-Object { $_.Look -eq 'look1' -and $_.Profile -eq 'Cpu' -and $_.Scenario -eq 'S1' -and $_.Metric -eq 'LoadWorkingSetMBAvg' })[0]
    Assert-True 'working-set secondary metric excludes only the pair with bad samples' ($cpuWorkingSetSecondary.ValidPairs -eq '8' -and $cpuWorkingSetSecondary.MetricExcludedPairs -eq '1' -and $cpuWorkingSetSecondary.InvalidPairs -eq '1') "valid $($cpuWorkingSetSecondary.ValidPairs), metric-excluded $($cpuWorkingSetSecondary.MetricExcludedPairs), invalid $($cpuWorkingSetSecondary.InvalidPairs)"

    $noReport = @(Get-Run 'Ram' 'S1' 9 'runtime')
    Assert-True 'launch without JSON report is kept as an invalid run' ($noReport.Count -eq 1 -and $noReport[0].Valid -eq 'False' -and $noReport[0].InvalidReason -like '*JSON report missing*') "$($noReport.Count) rows"
    $checks = @(
        @('Ram', 'S3', 1, 'plain', 'monitor exit code*'), @('Ram', 'S3', 2, 'runtime', '*non-finite private memory*'),
        @('Ram', 'S3', 3, 'plain', '*non-positive interval*'), @('Ram', 'S3', 4, 'plain', '*load interval median*'),
        @('Cpu', 'S1', 5, 'plain', '*non-finite CPU*'))
    foreach ($check in $checks) {
        $run = @(Get-Run $check[0] $check[1] $check[2] $check[3])
        Assert-True "invalid: $($check[0]) $($check[1]) pair $($check[2]) $($check[3]) ($($check[4]))" ($run.Count -eq 1 -and $run[0].Valid -eq 'False' -and $run[0].InvalidReason -like "*$($check[4].Trim('*'))*") "reason '$(if ($run.Count) { $run[0].InvalidReason })'"
    }
    $ramCpu = @(Get-Run 'Ram' 'S4' 5 'runtime')
    Assert-True 'unreadable CPU does not invalidate a Ram-profile run' ($ramCpu.Count -eq 1 -and $ramCpu[0].Valid -eq 'True') "reason '$(if ($ramCpu.Count) { $ramCpu[0].InvalidReason })'"

    $pairs = @(Import-Csv -LiteralPath (Join-Path $output 'pairs.csv') | Where-Object { $_.Profile -eq 'Ram' -and $_.Scenario -eq 'S1' -and $_.Pair -eq '6' })[0]
    Assert-Near 'pairs.csv keeps full precision (no rounding before statistics)' (ConvertTo-Double $pairs.LoadPrivateMBAvg) ((200.123456 + 0.004321) - 200.123456) 1e-9

    # Look 2: extensions with exactly the undecided scenarios (S1 and S3 in both profiles), pairs 11-20.
    $undecidedScenarios = @('S1', 'S3')
    $cpuExtension = Join-Path $root 'cpu-ext'; $ramExtension = Join-Path $root 'ram-ext'
    New-SyntheticResults -Directory $cpuExtension -MonitorProfile 'Cpu' -Interval 1 -Scenarios $undecidedScenarios -FirstPair 11
    New-SyntheticResults -Directory $ramExtension -MonitorProfile 'Ram' -Interval 0.2 -Scenarios $undecidedScenarios -FirstPair 11
    $output2 = Join-Path $root 'analysis-look2'
    & $summarize -ResultsDirectory $cpuDirectory, $ramDirectory -ExtensionDirectory $cpuExtension, $ramExtension -OutputDirectory $output2 | Out-Null
    $look2 = @(Import-Csv -LiteralPath (Join-Path $output2 'summary.csv') | Where-Object { $_.Look -eq 'look2' -and $_.Role -eq 'primary' })
    Assert-True 'look 2: decided hypotheses are not tested again' (@($look2 | Where-Object { @('S2', 'S4') -contains $_.Scenario -and $_.Verdict -ne 'decided at look 1' }).Count -eq 0)
    $cpuS3Look2 = @($look2 | Where-Object { $_.Profile -eq 'Cpu' -and $_.Scenario -eq 'S3' })[0]
    Assert-True 'look 2: Cpu S3 uses the 10 new pairs' ($cpuS3Look2.ValidPairs -eq '10' -and $cpuS3Look2.PairsInLook -eq '20') "valid $($cpuS3Look2.ValidPairs) of $($cpuS3Look2.PairsInLook)"
    Assert-Near 'look 2: Holm over the 4 undecided hypotheses' (ConvertTo-Double $cpuS3Look2.PHolm) 1

    function Test-Refused {
        param([string]$Name, [scriptblock]$Action, [string]$Pattern)
        $message = ''
        try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
        Assert-True $Name ($message -like $Pattern) "message '$message'"
    }
    $cpuShort = Join-Path $root 'cpu-ext-missing-scenario'
    New-SyntheticResults -Directory $cpuShort -MonitorProfile 'Cpu' -Interval 1 -Scenarios @('S1') -FirstPair 11
    Test-Refused 'look 2 refused when the extension omits an undecided scenario' { & $summarize -ResultsDirectory $cpuDirectory, $ramDirectory -ExtensionDirectory $cpuShort, $ramExtension -OutputDirectory (Join-Path $root 'x1') } '*exactly the scenarios undecided*'
    $ramGap = Join-Path $root 'ram-ext-missing-pair'
    New-SyntheticResults -Directory $ramGap -MonitorProfile 'Ram' -Interval 0.2 -Scenarios $undecidedScenarios -FirstPair 11 -SkipPairs @(15)
    Test-Refused 'look 2 refused when a planned pair 11-20 is missing' { & $summarize -ResultsDirectory $cpuDirectory, $ramDirectory -ExtensionDirectory $cpuExtension, $ramGap -OutputDirectory (Join-Path $root 'x2') } '*planned pair 15*'
    Test-Refused 'look 2 refused without an extension for a profile with undecided tests' { & $summarize -ResultsDirectory $cpuDirectory, $ramDirectory -ExtensionDirectory $cpuExtension -OutputDirectory (Join-Path $root 'x3') } '*exactly the scenarios undecided*'
    Test-Refused 'confirmatory with one profile only is refused' { & $summarize -ResultsDirectory $cpuDirectory -OutputDirectory (Join-Path $root 'x4') } '*one Cpu and one Ram*'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host "FAIL $failure" }
    exit 1
}
Write-Host 'All statistics tests passed.'
