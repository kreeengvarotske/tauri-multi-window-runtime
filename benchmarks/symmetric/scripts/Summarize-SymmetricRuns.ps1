<#
.SYNOPSIS
Summarizes a Run-SymmetricPairs.ps1 results directory: one row per run, the
paired differences (runtime - plain) and, per scenario and metric, the
medians, the range of the differences and a verdict.

.DESCRIPTION
Correctness (counters) and resources (memory, CPU) are reported separately:
coalescing or cache hits alone are not evidence of lower RAM or CPU use.

Primary metrics and the decision rule are fixed in README.md ("Statistical
rule") before confirmatory pairs run:
- Cpu profile: LoadCpuSeconds and LoadPrivateMBAvg; Ram profile:
  LoadPrivateMBPeak and LoadPrivateMBAvg; each per scenario.
- Test: two-sided sign-flip permutation test on the paired differences
  (exact up to 14 pairs, otherwise 20000 random flips, fixed seed), Holm
  correction over all primary tests of the results directory.
- Uncertainty: 95% bootstrap interval of the median difference (10000
  resamples, fixed seed).
- "runtime lower" / "runtime higher" only if Holm-adjusted p < 0.05, the
  interval excludes 0 and |median difference| >= 2% of the plain median;
  otherwise "no detectable difference".
- Pilot results get "pilot: no conclusion" whatever the numbers.
Other metrics are descriptive only. CPU metrics are not compared in the Ram
profile. No run is dropped; a pair with a failed or missing run is still
listed and counted in IncompletePairs.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResultsDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$culture = [System.Globalization.CultureInfo]::InvariantCulture
$ResultsDirectory = (Resolve-Path -LiteralPath $ResultsDirectory).Path
$runsDirectory = Join-Path $ResultsDirectory 'runs'
$configurationFile = Join-Path $ResultsDirectory 'configuration.json'
if (-not (Test-Path -LiteralPath $configurationFile)) { throw "Missing $configurationFile" }
$configuration = Get-Content -LiteralPath $configurationFile -Raw | ConvertFrom-Json
$monitorProfile = [string]$configuration.profile
$phase = [string]$configuration.phase
if (@('Cpu', 'Ram') -notcontains $monitorProfile -or @('Pilot', 'Confirmatory') -notcontains $phase) {
    throw "configuration.json must name profile Cpu or Ram and phase Pilot or Confirmatory (got '$monitorProfile', '$phase')."
}
$monitorCpuByRun = @{}
$runLog = Join-Path $ResultsDirectory 'runs.log'
if (Test-Path -LiteralPath $runLog) {
    foreach ($line in @(Get-Content -LiteralPath $runLog)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $entry = $line | ConvertFrom-Json
        if ($entry.PSObject.Properties['monitorCpuSeconds']) { $monitorCpuByRun[[string]$entry.name] = $entry.monitorCpuSeconds }
    }
}

function ConvertTo-Number {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    return [double]::Parse([string]$Value, $culture)
}

function Get-Median {
    param([double[]]$Values)
    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $middle = [int][Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) { return [double]$sorted[$middle] }
    return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2.0
}

function Get-Average {
    param([double[]]$Values)
    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
    return ($Values | Measure-Object -Average).Average
}

function Get-Max {
    param([double[]]$Values)
    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
    return ($Values | Measure-Object -Maximum).Maximum
}

function Format-Number {
    param([AllowNull()][object]$Value, [int]$Digits = 2)
    if ($null -eq $Value) { return '' }
    return ([double]$Value).ToString(("F{0}" -f $Digits), $culture)
}

function Get-Time {
    param([string]$Text)
    return [DateTimeOffset]::Parse($Text, $culture)
}

function Select-Phase {
    param([object[]]$Rows, [DateTimeOffset]$From, [DateTimeOffset]$To)
    @($Rows | Where-Object { $_.Time -ge $From -and $_.Time -lt $To })
}

# Metrics compared between builds; the counters are reported, not compared.
$memoryMetrics = @(
    'IdleBeforePrivateMB', 'LoadPrivateMBAvg', 'LoadPrivateMBPeak', 'LoadWorkingSetMBAvg', 'LoadWorkingSetMBPeak',
    'IdleAfterPrivateMB', 'ExePrivateMBLoadAvg', 'WebViewPrivateMBLoadAvg'
)
$cpuMetrics = @('IdleBeforeCpuSeconds', 'LoadCpuSeconds')
$resourceMetrics = @($memoryMetrics + $cpuMetrics)
$performanceMetrics = @('RequestsPerSecond', 'RoundMsP50', 'RoundMsP95')
$primaryMetrics = if ($monitorProfile -eq 'Cpu') { @('LoadCpuSeconds', 'LoadPrivateMBAvg') } else { @('LoadPrivateMBPeak', 'LoadPrivateMBAvg') }
$comparedMetrics = if ($monitorProfile -eq 'Cpu') { @($resourceMetrics + $performanceMetrics) } else { @($memoryMetrics + $performanceMetrics) }

function Get-SignFlipP {
    # Two-sided permutation test of "mean paired difference = 0".
    param([double[]]$Diffs, [System.Random]$Random)
    $n = $Diffs.Count
    $observed = [Math]::Abs(($Diffs | Measure-Object -Sum).Sum)
    $atLeast = 0
    if ($n -le 14) {
        $total = [int][Math]::Pow(2, $n)
        for ($mask = 0; $mask -lt $total; $mask++) {
            $sum = 0.0
            for ($i = 0; $i -lt $n; $i++) { if (($mask -shr $i) -band 1) { $sum -= $Diffs[$i] } else { $sum += $Diffs[$i] } }
            if ([Math]::Abs($sum) -ge $observed - 1e-9) { $atLeast++ }
        }
        return $atLeast / $total
    }
    $draws = 20000
    for ($d = 0; $d -lt $draws; $d++) {
        $sum = 0.0
        for ($i = 0; $i -lt $n; $i++) { if ($Random.Next(2) -eq 1) { $sum -= $Diffs[$i] } else { $sum += $Diffs[$i] } }
        if ([Math]::Abs($sum) -ge $observed - 1e-9) { $atLeast++ }
    }
    return ($atLeast + 1) / ($draws + 1)
}

function Get-BootstrapMedianInterval {
    param([double[]]$Diffs, [System.Random]$Random)
    $n = $Diffs.Count
    $medians = New-Object double[] 10000
    $sample = New-Object double[] $n
    for ($b = 0; $b -lt 10000; $b++) {
        for ($i = 0; $i -lt $n; $i++) { $sample[$i] = $Diffs[$Random.Next($n)] }
        $medians[$b] = Get-Median $sample
    }
    [Array]::Sort($medians)
    return @($medians[249], $medians[9749])
}

$runs = New-Object System.Collections.Generic.List[object]
foreach ($reportFile in @(Get-ChildItem -LiteralPath $runsDirectory -Filter '*.json' | Sort-Object Name)) {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($reportFile.Name)
    if ($base -notmatch '^(S[1-4])-pair(\d+)-(plain|runtime)$') { continue }
    $scenario = $Matches[1]; $pair = [int]$Matches[2]; $build = $Matches[3]
    $report = Get-Content -LiteralPath $reportFile.FullName -Raw | ConvertFrom-Json
    $row = [ordered]@{
        Scenario = $scenario; Pair = $pair; Build = $build
        Passed = [bool]$report.passed
        Error = ''
        Rounds = $null; PassedRounds = $null; Overruns = $null
        RequestsReceived = $null; OperationsExecuted = $null; CoalescedRequests = $null; CacheHits = $null; FailedRequests = $null
        RequestsPerSecond = $null; RoundMsP50 = $null; RoundMsP95 = $null
        MonitorRows = 0; LoadRowsWithMissingValues = $null; LoadProcessCountMax = $null
        IntervalMedianSeconds = $null; IntervalMaxSeconds = $null
        MonitorCpuSeconds = $monitorCpuByRun[$base]
    }
    foreach ($metric in $resourceMetrics) { $row[$metric] = $null }

    if (-not $report.PSObject.Properties['summary']) {
        $row.Error = [string]$report.error
        $runs.Add([pscustomobject]$row)
        continue
    }
    if ($null -ne $report.abort) { $row.Error = "aborted: $($report.abort.error) ($($report.abort.cleanup))" }
    $row.Rounds = $report.summary.rounds
    $row.PassedRounds = $report.summary.passedRounds
    $row.Overruns = $report.summary.overruns
    $row.RequestsReceived = $report.totals.requestsReceived
    $row.OperationsExecuted = $report.totals.operationsExecuted
    $row.CoalescedRequests = $report.totals.coalescedRequests
    $row.CacheHits = $report.totals.cacheHits
    $row.FailedRequests = $report.totals.failedRequests
    $row.RequestsPerSecond = [double]$report.summary.requestsPerSecond
    if ($null -ne $report.summary.roundMs) {
        $row.RoundMsP50 = [double]$report.summary.roundMs.p50
        $row.RoundMsP95 = [double]$report.summary.roundMs.p95
    }

    $monitorFile = Join-Path $runsDirectory "$base.monitor.csv"
    if (Test-Path -LiteralPath $monitorFile) {
        $samples = @(Import-Csv -LiteralPath $monitorFile | ForEach-Object {
                [pscustomobject]@{
                    Time        = Get-Time $_.Timestamp
                    RootPid     = [int]$_.RootPid
                    Processes   = [int]$_.ProcessCount
                    WorkingSet  = ConvertTo-Number $_.WorkingSetMB
                    Private     = ConvertTo-Number $_.PrivateBytesMB
                    CpuDelta    = ConvertTo-Number $_.CpuDeltaSeconds
                    Sample      = [int]$_.Sample
                    Interval    = ConvertTo-Number $_.IntervalSeconds
                    Missing     = [int](ConvertTo-Number $_.PrivateMissingCount) + [int](ConvertTo-Number $_.CpuUnreadableCount)
                }
            })
        $row.MonitorRows = $samples.Count
        # Actual sampling intervals; the first sample has none.
        $intervals = @($samples | Where-Object { $_.Sample -gt 0 -and $null -ne $_.Interval } | ForEach-Object { $_.Interval })
        $row.IntervalMedianSeconds = Get-Median $intervals
        $row.IntervalMaxSeconds = Get-Max $intervals
        $idleBefore = Select-Phase $samples (Get-Time $report.phases.expectedReadyAt) (Get-Time $report.phases.loadStartedAt)
        $load = Select-Phase $samples (Get-Time $report.phases.loadStartedAt) (Get-Time $report.phases.loadEndedAt)
        $idleAfter = Select-Phase $samples (Get-Time $report.phases.loadEndedAt) (Get-Time $report.phases.endedAt)
        $row.IdleBeforePrivateMB = Get-Average @($idleBefore | ForEach-Object { $_.Private })
        $row.LoadPrivateMBAvg = Get-Average @($load | ForEach-Object { $_.Private })
        $row.LoadPrivateMBPeak = Get-Max @($load | ForEach-Object { $_.Private })
        $row.LoadWorkingSetMBAvg = Get-Average @($load | ForEach-Object { $_.WorkingSet })
        $row.LoadWorkingSetMBPeak = Get-Max @($load | ForEach-Object { $_.WorkingSet })
        $cpu = @($load | Where-Object { $null -ne $_.CpuDelta } | ForEach-Object { $_.CpuDelta })
        if ($cpu.Count -gt 0) { $row.LoadCpuSeconds = ($cpu | Measure-Object -Sum).Sum }
        $row.IdleAfterPrivateMB = Get-Average @($idleAfter | ForEach-Object { $_.Private })
        $idleCpu = @($idleBefore | Where-Object { $null -ne $_.CpuDelta } | ForEach-Object { $_.CpuDelta })
        if ($idleCpu.Count -gt 0) { $row.IdleBeforeCpuSeconds = ($idleCpu | Measure-Object -Sum).Sum }
        $row.LoadRowsWithMissingValues = @($load | Where-Object { $_.Missing -gt 0 }).Count
        $row.LoadProcessCountMax = Get-Max @($load | ForEach-Object { [double]$_.Processes })

        $diagnosticsFile = Join-Path $runsDirectory "$base.monitor.diagnostics.csv"
        if ((Test-Path -LiteralPath $diagnosticsFile) -and $samples.Count -gt 0) {
            $rootPid = $samples[0].RootPid
            $from = Get-Time $report.phases.loadStartedAt
            $to = Get-Time $report.phases.loadEndedAt
            $exeBytes = @(Import-Csv -LiteralPath $diagnosticsFile | Where-Object {
                    [int]$_.Pid -eq $rootPid -and $_.InTree -eq 'True' -and -not [string]::IsNullOrWhiteSpace($_.CimPrivatePageCount)
                } | Where-Object {
                    $time = Get-Time $_.Timestamp; $time -ge $from -and $time -lt $to
                } | ForEach-Object { [double]$_.CimPrivatePageCount / 1MB })
            $row.ExePrivateMBLoadAvg = Get-Average $exeBytes
            if ($null -ne $row.ExePrivateMBLoadAvg -and $null -ne $row.LoadPrivateMBAvg) {
                $row.WebViewPrivateMBLoadAvg = $row.LoadPrivateMBAvg - $row.ExePrivateMBLoadAvg
            }
        }
    }
    else {
        $row.Error = ($row.Error + ' monitor CSV missing').Trim()
    }
    $runs.Add([pscustomobject]$row)
}

if ($runs.Count -eq 0) { throw "No run reports found in $runsDirectory" }

$numberColumns = @($resourceMetrics + $performanceMetrics)
$formattedColumns = @($numberColumns + @('IntervalMedianSeconds', 'IntervalMaxSeconds'))
$runs | ForEach-Object {
    $out = [ordered]@{}
    foreach ($property in $_.PSObject.Properties) {
        if ($formattedColumns -contains $property.Name) { $out[$property.Name] = Format-Number $property.Value 3 }
        else { $out[$property.Name] = $property.Value }
    }
    [pscustomobject]$out
} | Export-Csv -LiteralPath (Join-Path $ResultsDirectory 'runs.csv') -NoTypeInformation -Encoding UTF8

# Paired differences.
$pairRows = New-Object System.Collections.Generic.List[object]
foreach ($group in @($runs | Group-Object Scenario, Pair)) {
    $plain = @($group.Group | Where-Object { $_.Build -eq 'plain' })
    $runtime = @($group.Group | Where-Object { $_.Build -eq 'runtime' })
    $complete = $plain.Count -eq 1 -and $runtime.Count -eq 1 -and $plain[0].Passed -and $runtime[0].Passed
    $first = $group.Group[0]
    $pairRow = [ordered]@{ Scenario = $first.Scenario; Pair = $first.Pair; Complete = $complete }
    foreach ($metric in $numberColumns) {
        $value = $null
        if ($plain.Count -eq 1 -and $runtime.Count -eq 1 -and $null -ne $plain[0].$metric -and $null -ne $runtime[0].$metric) {
            $value = [double]$runtime[0].$metric - [double]$plain[0].$metric
        }
        $pairRow[$metric] = $value
    }
    $pairRows.Add([pscustomobject]$pairRow)
}
$pairRows | ForEach-Object {
    $out = [ordered]@{}
    foreach ($property in $_.PSObject.Properties) {
        if ($numberColumns -contains $property.Name) { $out[$property.Name] = Format-Number $property.Value } else { $out[$property.Name] = $property.Value }
    }
    [pscustomobject]$out
} | Export-Csv -LiteralPath (Join-Path $ResultsDirectory 'pairs.csv') -NoTypeInformation -Encoding UTF8

# Per scenario and metric.
$random = New-Object System.Random 20261025
$summaryRows = New-Object System.Collections.Generic.List[object]
foreach ($scenario in @($runs | Select-Object -ExpandProperty Scenario -Unique | Sort-Object)) {
    $scenarioPairs = @($pairRows | Where-Object { $_.Scenario -eq $scenario })
    foreach ($metric in $comparedMetrics) {
        $diffs = @($scenarioPairs | Where-Object { $null -ne $_.$metric } | ForEach-Object { [double]$_.$metric })
        $plainValues = @($runs | Where-Object { $_.Scenario -eq $scenario -and $_.Build -eq 'plain' -and $null -ne $_.$metric } | ForEach-Object { [double]$_.$metric })
        $runtimeValues = @($runs | Where-Object { $_.Scenario -eq $scenario -and $_.Build -eq 'runtime' -and $null -ne $_.$metric } | ForEach-Object { [double]$_.$metric })
        $primary = $primaryMetrics -contains $metric
        $median = Get-Median $diffs
        $p = $null; $low = $null; $high = $null
        if ($primary -and $diffs.Count -ge 2) {
            $p = Get-SignFlipP -Diffs $diffs -Random $random
            $interval = Get-BootstrapMedianInterval -Diffs $diffs -Random $random
            $low = $interval[0]; $high = $interval[1]
        }
        $summaryRows.Add([pscustomobject][ordered]@{
                Scenario        = $scenario
                Metric          = $metric
                Role            = $(if ($primary) { 'primary' } else { 'descriptive' })
                Pairs           = $diffs.Count
                IncompletePairs = @($scenarioPairs | Where-Object { -not $_.Complete }).Count
                PlainMedian     = Get-Median $plainValues
                RuntimeMedian   = Get-Median $runtimeValues
                DiffMedian      = $median
                DiffMin         = $(if ($diffs.Count -gt 0) { ($diffs | Measure-Object -Minimum).Minimum } else { $null })
                DiffMax         = $(if ($diffs.Count -gt 0) { ($diffs | Measure-Object -Maximum).Maximum } else { $null })
                CiLow           = $low
                CiHigh          = $high
                P               = $p
                PHolm           = $null
                Verdict         = ''
            })
    }
}

# Holm over the primary tests of this directory.
$tested = @($summaryRows | Where-Object { $null -ne $_.P } | Sort-Object P)
$m = $tested.Count
$running = 0.0
for ($k = 0; $k -lt $m; $k++) {
    $adjusted = [Math]::Min(1.0, ($m - $k) * $tested[$k].P)
    if ($adjusted -lt $running) { $adjusted = $running }
    $running = $adjusted
    $tested[$k].PHolm = $adjusted
}
foreach ($row in $summaryRows) {
    if ($row.Pairs -eq 0) { $row.Verdict = 'no data'; continue }
    if ($row.Role -ne 'primary') { $row.Verdict = 'descriptive'; continue }
    if ($phase -eq 'Pilot') { $row.Verdict = 'pilot: no conclusion'; continue }
    $threshold = 0.02 * [Math]::Abs([double]$row.PlainMedian)
    $significant = $null -ne $row.PHolm -and $row.PHolm -lt 0.05 -and $null -ne $row.CiLow -and ($row.CiLow -gt 0 -or $row.CiHigh -lt 0)
    if ($significant -and [Math]::Abs($row.DiffMedian) -ge $threshold) {
        $row.Verdict = $(if ($row.DiffMedian -lt 0) { 'runtime lower' } else { 'runtime higher' })
    }
    else {
        $row.Verdict = 'no detectable difference'
    }
}
$summaryRows = @($summaryRows | ForEach-Object {
        $out = [ordered]@{}
        foreach ($property in $_.PSObject.Properties) {
            if (@('P', 'PHolm') -contains $property.Name) { $out[$property.Name] = Format-Number $property.Value 4 }
            elseif (@('PlainMedian', 'RuntimeMedian', 'DiffMedian', 'DiffMin', 'DiffMax', 'CiLow', 'CiHigh') -contains $property.Name) { $out[$property.Name] = Format-Number $property.Value }
            else { $out[$property.Name] = $property.Value }
        }
        [pscustomobject]$out
    })
$summaryRows | Export-Csv -LiteralPath (Join-Path $ResultsDirectory 'summary.csv') -NoTypeInformation -Encoding UTF8

# Markdown: correctness first, then resources.
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add(('Profile: {0} (monitor interval {1} s). Phase: {2}. Commit {3}. {4}.' -f $monitorProfile, $configuration.sampleIntervalSeconds, $phase, $configuration.gitHead, $configuration.os))
$lines.Add('')
$lines.Add('## Correctness (counters per run)')
$lines.Add('')
$lines.Add('| Scenario | Pair | Build | Passed | Rounds passed | Received | Executed | Coalesced | Cache hits | Failed | Note |')
$lines.Add('|---|---|---|---|---|---|---|---|---|---|---|')
foreach ($run in @($runs | Sort-Object Scenario, Pair, Build)) {
    $lines.Add(('| {0} | {1} | {2} | {3} | {4}/{5} | {6} | {7} | {8} | {9} | {10} | {11} |' -f $run.Scenario, $run.Pair, $run.Build, $run.Passed, $run.PassedRounds, $run.Rounds, $run.RequestsReceived, $run.OperationsExecuted, $run.CoalescedRequests, $run.CacheHits, $run.FailedRequests, $run.Error))
}
$lines.Add('')
$lines.Add('## Monitoring')
$lines.Add('')
$lines.Add('| Run | Interval median / max (s) | Monitor CPU s | Load rows with missing values |')
$lines.Add('|---|---|---|---|')
foreach ($run in @($runs | Sort-Object Scenario, Pair, Build)) {
    $lines.Add(('| {0}-{1}-{2} | {3} / {4} | {5} | {6} |' -f $run.Scenario, $run.Pair, $run.Build, (Format-Number $run.IntervalMedianSeconds 3), (Format-Number $run.IntervalMaxSeconds 3), $run.MonitorCpuSeconds, $run.LoadRowsWithMissingValues))
}
$lines.Add('')
$lines.Add('## Resources and latency (paired differences: runtime - plain)')
$lines.Add('')
if ($monitorProfile -eq 'Ram') { $lines.Add('CPU metrics are not compared in the Ram profile (0.2 s WMI sampling adds observer overhead).'); $lines.Add('') }
$lines.Add('| Scenario | Metric | Role | Pairs | Incomplete | Plain median | Runtime median | Diff median | Diff min..max | 95% CI of median diff | p (Holm) | Verdict |')
$lines.Add('|---|---|---|---|---|---|---|---|---|---|---|---|')
foreach ($row in $summaryRows) {
    $ci = if ($row.CiLow -ne '') { '{0}..{1}' -f $row.CiLow, $row.CiHigh } else { '' }
    $pText = if ($row.P -ne '') { '{0} ({1})' -f $row.P, $row.PHolm } else { '' }
    $lines.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8}..{9} | {10} | {11} | {12} |' -f $row.Scenario, $row.Metric, $row.Role, $row.Pairs, $row.IncompletePairs, $row.PlainMedian, $row.RuntimeMedian, $row.DiffMedian, $row.DiffMin, $row.DiffMax, $ci, $pText, $row.Verdict))
}
$lines | Set-Content -LiteralPath (Join-Path $ResultsDirectory 'summary.md') -Encoding UTF8
Write-Host "Wrote runs.csv, pairs.csv, summary.csv and summary.md to $ResultsDirectory"
