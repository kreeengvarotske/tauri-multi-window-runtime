<#
.SYNOPSIS
Summarizes a Run-SymmetricPairs.ps1 results directory: one row per run, the
paired differences (runtime - plain) and, per scenario and metric, the
medians, the range of the differences and a verdict.

.DESCRIPTION
Correctness (counters) and resources (memory, CPU) are reported separately:
coalescing or cache hits alone are not evidence of lower RAM or CPU use.

Verdict rule for a metric: "runtime lower" or "runtime higher" only when every
paired difference has the same sign AND the absolute median difference is
larger than the spread (max - min) of either build's own values across the
pairs. Otherwise "within spread". No run is dropped; a pair with a failed or
missing run is still listed and counted in IncompletePairs.
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
$resourceMetrics = @(
    'IdleBeforePrivateMB', 'LoadPrivateMBAvg', 'LoadPrivateMBPeak', 'LoadWorkingSetMBAvg', 'LoadWorkingSetMBPeak',
    'LoadCpuSeconds', 'IdleAfterPrivateMB', 'ExePrivateMBLoadAvg', 'WebViewPrivateMBLoadAvg'
)
$performanceMetrics = @('RequestsPerSecond', 'RoundMsP50', 'RoundMsP95')

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
                    Missing     = [int](ConvertTo-Number $_.PrivateMissingCount) + [int](ConvertTo-Number $_.CpuUnreadableCount)
                }
            })
        $row.MonitorRows = $samples.Count
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
$runs | ForEach-Object {
    $out = [ordered]@{}
    foreach ($property in $_.PSObject.Properties) {
        if ($numberColumns -contains $property.Name) { $out[$property.Name] = Format-Number $property.Value }
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
$summaryRows = New-Object System.Collections.Generic.List[object]
foreach ($scenario in @($runs | Select-Object -ExpandProperty Scenario -Unique | Sort-Object)) {
    $scenarioPairs = @($pairRows | Where-Object { $_.Scenario -eq $scenario })
    foreach ($metric in $numberColumns) {
        $diffs = @($scenarioPairs | Where-Object { $null -ne $_.$metric } | ForEach-Object { [double]$_.$metric })
        $plainValues = @($runs | Where-Object { $_.Scenario -eq $scenario -and $_.Build -eq 'plain' -and $null -ne $_.$metric } | ForEach-Object { [double]$_.$metric })
        $runtimeValues = @($runs | Where-Object { $_.Scenario -eq $scenario -and $_.Build -eq 'runtime' -and $null -ne $_.$metric } | ForEach-Object { [double]$_.$metric })
        $spread = 0.0
        foreach ($values in @(, $plainValues) + @(, $runtimeValues)) {
            if ($values.Count -gt 0) {
                $range = (($values | Measure-Object -Maximum).Maximum - ($values | Measure-Object -Minimum).Minimum)
                if ($range -gt $spread) { $spread = $range }
            }
        }
        $median = Get-Median $diffs
        $verdict = 'no data'
        if ($diffs.Count -gt 0) {
            $allPositive = @($diffs | Where-Object { $_ -le 0 }).Count -eq 0
            $allNegative = @($diffs | Where-Object { $_ -ge 0 }).Count -eq 0
            if ($allPositive -and [Math]::Abs($median) -gt $spread) { $verdict = 'runtime higher' }
            elseif ($allNegative -and [Math]::Abs($median) -gt $spread) { $verdict = 'runtime lower' }
            else { $verdict = 'within spread' }
        }
        $summaryRows.Add([pscustomobject][ordered]@{
                Scenario         = $scenario
                Metric           = $metric
                Pairs            = $diffs.Count
                IncompletePairs  = @($scenarioPairs | Where-Object { -not $_.Complete }).Count
                PlainMedian      = Format-Number (Get-Median $plainValues)
                RuntimeMedian    = Format-Number (Get-Median $runtimeValues)
                DiffMedian       = Format-Number $median
                DiffMin          = Format-Number $(if ($diffs.Count -gt 0) { ($diffs | Measure-Object -Minimum).Minimum } else { $null })
                DiffMax          = Format-Number $(if ($diffs.Count -gt 0) { ($diffs | Measure-Object -Maximum).Maximum } else { $null })
                LargerBuildSpread = Format-Number $spread
                Verdict          = $verdict
            })
    }
}
$summaryRows | Export-Csv -LiteralPath (Join-Path $ResultsDirectory 'summary.csv') -NoTypeInformation -Encoding UTF8

# Markdown: correctness first, then resources.
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('## Correctness (counters per run)')
$lines.Add('')
$lines.Add('| Scenario | Pair | Build | Passed | Rounds passed | Received | Executed | Coalesced | Cache hits | Failed | Note |')
$lines.Add('|---|---|---|---|---|---|---|---|---|---|---|')
foreach ($run in @($runs | Sort-Object Scenario, Pair, Build)) {
    $lines.Add(('| {0} | {1} | {2} | {3} | {4}/{5} | {6} | {7} | {8} | {9} | {10} | {11} |' -f $run.Scenario, $run.Pair, $run.Build, $run.Passed, $run.PassedRounds, $run.Rounds, $run.RequestsReceived, $run.OperationsExecuted, $run.CoalescedRequests, $run.CacheHits, $run.FailedRequests, $run.Error))
}
$lines.Add('')
$lines.Add('## Resources and latency (paired differences: runtime - plain)')
$lines.Add('')
$lines.Add('| Scenario | Metric | Pairs | Incomplete | Plain median | Runtime median | Diff median | Diff min..max | Larger spread | Verdict |')
$lines.Add('|---|---|---|---|---|---|---|---|---|---|')
foreach ($row in $summaryRows) {
    $lines.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7}..{8} | {9} | {10} |' -f $row.Scenario, $row.Metric, $row.Pairs, $row.IncompletePairs, $row.PlainMedian, $row.RuntimeMedian, $row.DiffMedian, $row.DiffMin, $row.DiffMax, $row.LargerBuildSpread, $row.Verdict))
}
$lines | Set-Content -LiteralPath (Join-Path $ResultsDirectory 'summary.md') -Encoding UTF8
Write-Host "Wrote runs.csv, pairs.csv, summary.csv and summary.md to $ResultsDirectory"
