<#
.SYNOPSIS
Summarizes Run-SymmetricPairs.ps1 results: one row per run with its validity,
the paired differences (runtime - plain) and, per scenario and metric, the
medians, the range of the differences and a verdict.

.DESCRIPTION
Correctness (counters) and resources (memory, CPU) are reported separately:
coalescing or cache hits alone are not evidence of lower RAM or CPU use.

The rule is the one in README.md ("Statistical rule"); in short:
- Estimand: the median paired difference (runtime - plain). The test
  statistic, the interval and the 2% threshold all use this median.
- Validity: a run is valid only if it passes every check listed in README.md
  ("Run validity"); a pair is valid only if both of its runs are. Invalid
  runs and pairs stay in runs.csv and pairs.csv with their reasons and are
  left out of every median, interval and p-value.
- Test: exact two-sided sign test of "median difference = 0", Holm
  correction within a look. Interval: the distribution-free interval for the
  median from order statistics (the sign test inverted), with its exact
  coverage.
- Confirmatory looks: look 1 after 10 pairs at alpha 0.025; look 2, only for
  tests undecided at look 1, after 20 pairs at alpha 0.025.
- Pilot results get "pilot: no conclusion" whatever the numbers.

Analysis files go to a new directory (default <ResultsDirectory>\analysis-
<timestamp>), so the raw data and earlier analyses are never overwritten.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResultsDirectory,

    # Look 2: the directory of the 10 extension pairs (Run-SymmetricPairs.ps1 -FirstPair 11).
    [string]$ExtensionDirectory,

    [string]$OutputDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$culture = [System.Globalization.CultureInfo]::InvariantCulture

if (-not ('SymmetricBenchStats' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
public static class SymmetricBenchStats {
    public static double Median(double[] values) {
        double[] sorted = (double[])values.Clone();
        Array.Sort(sorted);
        int n = sorted.Length;
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0;
    }

    // P(X <= k) for X ~ Binomial(n, 1/2).
    public static double BinomialHalfCdf(int n, int k) {
        if (k < 0) return 0.0;
        double term = Math.Pow(0.5, n), sum = 0.0;
        for (int i = 0; i <= Math.Min(k, n); i++) {
            sum += term;
            term = term * (n - i) / (i + 1);
        }
        return Math.Min(1.0, sum);
    }

    // Exact two-sided sign test of "median paired difference = 0"; zero differences are dropped.
    public static double SignTestP(double[] diffs) {
        int positive = 0, negative = 0;
        foreach (double d in diffs) { if (d > 0) positive++; else if (d < 0) negative++; }
        int n = positive + negative;
        if (n == 0) return 1.0;
        return Math.Min(1.0, 2.0 * BinomialHalfCdf(n, Math.Min(positive, negative)));
    }

    // Distribution-free interval for the median from order statistics (the sign test inverted):
    // [d(k), d(n-k+1)] with the largest k such that P(X <= k-1) <= (1-level)/2.
    // Returns {low, high, coverage}, or null when n is too small for the level.
    public static double[] MedianInterval(double[] diffs, double level) {
        int n = diffs.Length;
        double tail = (1.0 - level) / 2.0;
        int k = 0;
        while (k + 1 <= n / 2 && BinomialHalfCdf(n, k) <= tail) k++;
        if (k == 0) return null;
        double[] sorted = (double[])diffs.Clone();
        Array.Sort(sorted);
        return new double[] { sorted[k - 1], sorted[n - k], 1.0 - 2.0 * BinomialHalfCdf(n, k - 1) };
    }
}
'@
}

# Fixed protocol values (README.md, "Statistical rule" and "Run validity").
$plannedPairsPerLook = 10
$minValidPairsPerLook = 8
$lookAlpha = 0.025
$practicalThreshold = 0.02
$minLoadCoverage = 0.8
$maxIntervalDeviation = 0.2
$maxIntervalFactor = 5

function ConvertTo-Number {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    return [double]::Parse([string]$Value, $culture)
}

function Get-Median {
    param([double[]]$Values)
    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
    return [SymmetricBenchStats]::Median($Values)
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
    if ($null -eq $Value -or '' -eq $Value) { return '' }
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

function Read-Configuration {
    param([string]$Directory)
    $file = Join-Path $Directory 'configuration.json'
    if (-not (Test-Path -LiteralPath $file)) { throw "Missing $file" }
    $value = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    if (@('Cpu', 'Ram') -notcontains [string]$value.profile -or @('Pilot', 'Confirmatory') -notcontains [string]$value.phase) {
        throw "$file must name profile Cpu or Ram and phase Pilot or Confirmatory (got '$($value.profile)', '$($value.phase)')."
    }
    return $value
}

function Get-ConfigValue {
    param([object]$Configuration, [string]$Name, [object]$Default)
    if ($Configuration.PSObject.Properties[$Name]) { return $Configuration.$Name }
    return $Default
}

$ResultsDirectory = (Resolve-Path -LiteralPath $ResultsDirectory).Path
$configuration = Read-Configuration $ResultsDirectory
$monitorProfile = [string]$configuration.profile
$phase = [string]$configuration.phase
$nominalInterval = [double]$configuration.sampleIntervalSeconds
$deviations = New-Object System.Collections.Generic.List[string]

$directories = @($ResultsDirectory)
if ($ExtensionDirectory) {
    $ExtensionDirectory = (Resolve-Path -LiteralPath $ExtensionDirectory).Path
    if ($phase -ne 'Confirmatory') { throw 'An extension (look 2) exists only for Confirmatory results.' }
    $extension = Read-Configuration $ExtensionDirectory
    foreach ($name in @('profile', 'phase', 'machine', 'gitHead', 'plainExeSha256', 'runtimeExeSha256', 'monitorSha256', 'sampleIntervalSeconds',
            'durationSeconds', 'idleSeconds', 'pauseSeconds', 'iterations', 'bufferMb', 'requestsPerWindow', 'roundIntervalMs')) {
        if ([string](Get-ConfigValue $configuration $name '') -ne [string](Get-ConfigValue $extension $name '')) {
            throw "Extension differs from look 1 in '$name' ('$(Get-ConfigValue $configuration $name '')' vs '$(Get-ConfigValue $extension $name '')'); it cannot be pooled."
        }
    }
    if ([int](Get-ConfigValue $extension 'firstPair' 1) -ne $plannedPairsPerLook + 1 -or [int]$extension.pairs -ne $plannedPairsPerLook) {
        throw "The extension must be pairs $($plannedPairsPerLook + 1)..$(2 * $plannedPairsPerLook) (-FirstPair $($plannedPairsPerLook + 1) -Pairs $plannedPairsPerLook)."
    }
    $directories += $ExtensionDirectory
}
if ($phase -eq 'Confirmatory' -and ([int](Get-ConfigValue $configuration 'firstPair' 1) -ne 1 -or [int]$configuration.pairs -ne $plannedPairsPerLook)) {
    throw "Confirmatory look 1 must be pairs 1..$plannedPairsPerLook (got firstPair $(Get-ConfigValue $configuration 'firstPair' 1), pairs $($configuration.pairs))."
}
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $directories[-1] ("analysis-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
if (Test-Path -LiteralPath $OutputDirectory) { throw "$OutputDirectory already exists; choose a new -OutputDirectory." }

# Metrics compared between builds; the counters are reported, not compared.
# "MaxSample" is the largest value among the samples taken, not a guaranteed true peak.
$memoryMetrics = @(
    'IdleBeforePrivateMB', 'LoadPrivateMBAvg', 'LoadPrivateMBMaxSample', 'LoadWorkingSetMBAvg', 'LoadWorkingSetMBMaxSample',
    'IdleAfterPrivateMB', 'ExePrivateMBLoadAvg', 'WebViewPrivateMBLoadAvg'
)
$cpuMetrics = @('IdleBeforeCpuSeconds', 'LoadCpuSeconds')
$resourceMetrics = @($memoryMetrics + $cpuMetrics)
$performanceMetrics = @('RequestsPerSecond', 'RoundMsP50', 'RoundMsP95')
$primaryMetrics = if ($monitorProfile -eq 'Cpu') { @('LoadCpuSeconds', 'LoadPrivateMBAvg') } else { @('LoadPrivateMBMaxSample', 'LoadPrivateMBAvg') }
$comparedMetrics = if ($monitorProfile -eq 'Cpu') { @($resourceMetrics + $performanceMetrics) } else { @($memoryMetrics + $performanceMetrics) }

$runs = New-Object System.Collections.Generic.List[object]
foreach ($directory in $directories) {
    $runsDirectory = Join-Path $directory 'runs'
    $logByRun = @{}
    $logOrder = New-Object System.Collections.Generic.List[string]
    $runLog = Join-Path $directory 'runs.log'
    if (Test-Path -LiteralPath $runLog) {
        foreach ($line in @(Get-Content -LiteralPath $runLog)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $entry = $line | ConvertFrom-Json
            $logByRun[[string]$entry.name] = $entry
            $logOrder.Add([string]$entry.name)
        }
    }

    # The order fixed before the first run, if the run script wrote one.
    $scheduleFile = Join-Path $directory 'schedule.csv'
    if (Test-Path -LiteralPath $scheduleFile) {
        $scheduled = @(Import-Csv -LiteralPath $scheduleFile | Sort-Object { [int]$_.Seq } | ForEach-Object { $_.Name })
        $executed = @($logOrder)
        $missing = @($scheduled | Where-Object { $executed -notcontains $_ })
        $extra = @($executed | Where-Object { $scheduled -notcontains $_ })
        $inScheduleOrder = @($executed | Where-Object { $scheduled -contains $_ })
        $expectedOrder = @($scheduled | Where-Object { $executed -contains $_ })
        if ($missing.Count -gt 0) { $deviations.Add("$(Split-Path -Leaf $directory): scheduled but not run: $($missing -join ', ')") }
        if ($extra.Count -gt 0) { $deviations.Add("$(Split-Path -Leaf $directory): run but not scheduled: $($extra -join ', ')") }
        if (($inScheduleOrder -join ',') -ne ($expectedOrder -join ',')) { $deviations.Add("$(Split-Path -Leaf $directory): runs did not follow schedule.csv order") }
    }
    elseif ($phase -eq 'Confirmatory') {
        throw "Missing $scheduleFile; confirmatory runs need the order fixed in advance."
    }
    else {
        $deviations.Add("$(Split-Path -Leaf $directory): no schedule.csv (run script before the fixed-order change); order taken from runs.log")
    }

    foreach ($reportFile in @(Get-ChildItem -LiteralPath $runsDirectory -Filter '*.json' | Sort-Object Name)) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($reportFile.Name)
        if ($base -notmatch '^(S[1-4])-pair(\d+)-(plain|runtime)$') { continue }
        $scenario = $Matches[1]; $pair = [int]$Matches[2]; $build = $Matches[3]
        $log = $logByRun[$base]
        $reasons = New-Object System.Collections.Generic.List[string]
        $report = $null
        try { $report = Get-Content -LiteralPath $reportFile.FullName -Raw | ConvertFrom-Json }
        catch { $reasons.Add('report is not valid JSON') }
        $row = [ordered]@{
            Scenario = $scenario; Pair = $pair; Build = $build; Directory = Split-Path -Leaf $directory
            Valid = $false; InvalidReason = ''
            Passed = $false; Error = ''
            ExitCode = $(if ($null -ne $log) { $log.exitCode } else { $null })
            TimedOut = $(if ($null -ne $log) { $log.timedOut } else { $null })
            Rounds = $null; PassedRounds = $null; Overruns = $null
            RequestsReceived = $null; OperationsExecuted = $null; CoalescedRequests = $null; CacheHits = $null; FailedRequests = $null
            RequestsPerSecond = $null; RoundMsP50 = $null; RoundMsP95 = $null
            MonitorRows = 0; LoadRows = 0; LoadRowsExpected = $null; LoadRowsWithMissingValues = $null
            LoadRowsWithMissingPrivateValues = $null; LoadRowsWithUnreadableCpu = $null; LoadProcessCountMax = $null
            IntervalMedianSeconds = $null; IntervalMaxSeconds = $null; LoadIntervalMedianSeconds = $null; LoadIntervalMaxSeconds = $null
            MonitorCpuSeconds = $(if ($null -ne $log -and $log.PSObject.Properties['monitorCpuSeconds']) { $log.monitorCpuSeconds } else { $null })
        }
        foreach ($metric in $resourceMetrics) { $row[$metric] = $null }

        if ($null -eq $log) { $reasons.Add('no runs.log entry') }
        else {
            if ($null -eq $log.exitCode -or [int]$log.exitCode -ne 0) { $reasons.Add("app exit code $($log.exitCode)") }
            if ($log.timedOut) { $reasons.Add('timed out') }
            if ($null -eq $log.monitorExit) { $reasons.Add('monitor exit code missing from runs.log') }
            elseif ([int]$log.monitorExit -ne 0) { $reasons.Add("monitor exit code $($log.monitorExit)") }
        }
        if ($null -ne $report) {
            $row.Passed = [bool]$report.passed
            if (-not $row.Passed) { $reasons.Add('report not passed') }
            if ($report.PSObject.Properties['config'] -and $null -ne $report.config) {
                if ($report.config.PSObject.Properties['build'] -and [string]$report.config.build -ne $build) { $reasons.Add("report build '$($report.config.build)'") }
                if ($report.config.PSObject.Properties['scenario'] -and [string]$report.config.scenario -ne $scenario) { $reasons.Add("report scenario '$($report.config.scenario)'") }
            }
            if (-not $report.PSObject.Properties['summary']) {
                $row.Error = $(if ($report.PSObject.Properties['configError']) { [string]$report.configError } elseif ($report.PSObject.Properties['error']) { [string]$report.error } else { '' })
                $reasons.Add('no summary in report')
            }
        }
        if ($null -eq $report -or -not $report.PSObject.Properties['summary']) {
            $row.InvalidReason = $reasons -join '; '
            $runs.Add([pscustomobject]$row)
            continue
        }

        if ($report.PSObject.Properties['abort'] -and $null -ne $report.abort) {
            $row.Error = "aborted: $($report.abort.error) ($($report.abort.cleanup))"
            $reasons.Add('aborted')
        }
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
                        Time       = Get-Time $_.Timestamp
                        RootPid    = [int]$_.RootPid
                        Processes  = [int]$_.ProcessCount
                        WorkingSet = ConvertTo-Number $_.WorkingSetMB
                        Private    = ConvertTo-Number $_.PrivateBytesMB
                        CpuDelta   = ConvertTo-Number $_.CpuDeltaSeconds
                        Sample     = [int]$_.Sample
                        Interval       = ConvertTo-Number $_.IntervalSeconds
                        PrivateMissing = [int](ConvertTo-Number $_.PrivateMissingCount)
                        CpuUnreadable  = [int](ConvertTo-Number $_.CpuUnreadableCount)
                        Missing        = [int](ConvertTo-Number $_.PrivateMissingCount) + [int](ConvertTo-Number $_.CpuUnreadableCount)
                    }
                })
            $row.MonitorRows = $samples.Count
            # Actual sampling intervals; the first sample has none.
            $intervals = @($samples | Where-Object { $_.Sample -gt 0 -and $null -ne $_.Interval } | ForEach-Object { $_.Interval })
            $row.IntervalMedianSeconds = Get-Median $intervals
            $row.IntervalMaxSeconds = Get-Max $intervals
            $loadFrom = Get-Time $report.phases.loadStartedAt
            $loadTo = Get-Time $report.phases.loadEndedAt
            $idleBefore = Select-Phase $samples (Get-Time $report.phases.expectedReadyAt) $loadFrom
            $load = Select-Phase $samples $loadFrom $loadTo
            $idleAfter = Select-Phase $samples $loadTo (Get-Time $report.phases.endedAt)
            $row.LoadRows = $load.Count
            $row.LoadRowsExpected = [Math]::Floor(($loadTo - $loadFrom).TotalSeconds / $nominalInterval)
            $loadIntervals = @($load | Where-Object { $_.Sample -gt 0 -and $null -ne $_.Interval } | ForEach-Object { $_.Interval })
            $row.LoadIntervalMedianSeconds = Get-Median $loadIntervals
            $row.LoadIntervalMaxSeconds = Get-Max $loadIntervals
            $row.IdleBeforePrivateMB = Get-Average @($idleBefore | ForEach-Object { $_.Private })
            $row.LoadPrivateMBAvg = Get-Average @($load | ForEach-Object { $_.Private })
            $row.LoadPrivateMBMaxSample = Get-Max @($load | ForEach-Object { $_.Private })
            $row.LoadWorkingSetMBAvg = Get-Average @($load | ForEach-Object { $_.WorkingSet })
            $row.LoadWorkingSetMBMaxSample = Get-Max @($load | ForEach-Object { $_.WorkingSet })
            $cpu = @($load | Where-Object { $null -ne $_.CpuDelta } | ForEach-Object { $_.CpuDelta })
            if ($cpu.Count -gt 0) { $row.LoadCpuSeconds = ($cpu | Measure-Object -Sum).Sum }
            $row.IdleAfterPrivateMB = Get-Average @($idleAfter | ForEach-Object { $_.Private })
            $idleCpu = @($idleBefore | Where-Object { $null -ne $_.CpuDelta } | ForEach-Object { $_.CpuDelta })
            if ($idleCpu.Count -gt 0) { $row.IdleBeforeCpuSeconds = ($idleCpu | Measure-Object -Sum).Sum }
            $row.LoadRowsWithMissingPrivateValues = @($load | Where-Object { $_.PrivateMissing -gt 0 -or $null -eq $_.Private }).Count
            $row.LoadRowsWithUnreadableCpu = @($load | Where-Object { $_.CpuUnreadable -gt 0 -or $null -eq $_.CpuDelta }).Count
            $row.LoadRowsWithMissingValues = @($load | Where-Object { $_.Missing -gt 0 }).Count
            $row.LoadProcessCountMax = Get-Max @($load | ForEach-Object { [double]$_.Processes })

            if ($row.LoadRowsExpected -gt 0 -and $row.LoadRows -lt $minLoadCoverage * $row.LoadRowsExpected) { $reasons.Add("load rows $($row.LoadRows) < $([int]($minLoadCoverage * 100))% of $($row.LoadRowsExpected)") }
            if ($row.LoadRowsWithMissingPrivateValues -gt 0) { $reasons.Add("$($row.LoadRowsWithMissingPrivateValues) load rows with missing private-memory values") }
            if ($monitorProfile -eq 'Cpu' -and $row.LoadRowsWithUnreadableCpu -gt 0) { $reasons.Add("$($row.LoadRowsWithUnreadableCpu) load rows with unreadable CPU values") }
            if ($null -eq $row.LoadIntervalMedianSeconds -or [Math]::Abs($row.LoadIntervalMedianSeconds - $nominalInterval) -gt $maxIntervalDeviation * $nominalInterval) {
                $reasons.Add("load interval median $(Format-Number $row.LoadIntervalMedianSeconds 3) s not within $([int]($maxIntervalDeviation * 100))% of nominal $nominalInterval s")
            }
            if ($null -ne $row.LoadIntervalMaxSeconds -and $row.LoadIntervalMaxSeconds -gt $maxIntervalFactor * $nominalInterval) {
                $reasons.Add("load gap $(Format-Number $row.LoadIntervalMaxSeconds 3) s > $maxIntervalFactor x $nominalInterval s")
            }

            $diagnosticsFile = Join-Path $runsDirectory "$base.monitor.diagnostics.csv"
            if ((Test-Path -LiteralPath $diagnosticsFile) -and $samples.Count -gt 0) {
                $rootPid = $samples[0].RootPid
                $exeBytes = @(Import-Csv -LiteralPath $diagnosticsFile | Where-Object {
                        [int]$_.Pid -eq $rootPid -and $_.InTree -eq 'True' -and -not [string]::IsNullOrWhiteSpace($_.CimPrivatePageCount)
                    } | Where-Object {
                        $time = Get-Time $_.Timestamp; $time -ge $loadFrom -and $time -lt $loadTo
                    } | ForEach-Object { [double]$_.CimPrivatePageCount / 1MB })
                $row.ExePrivateMBLoadAvg = Get-Average $exeBytes
                if ($null -ne $row.ExePrivateMBLoadAvg -and $null -ne $row.LoadPrivateMBAvg) {
                    $row.WebViewPrivateMBLoadAvg = $row.LoadPrivateMBAvg - $row.ExePrivateMBLoadAvg
                }
            }
        }
        else {
            $reasons.Add('monitor CSV missing')
        }
        foreach ($metric in $primaryMetrics) {
            if ($null -eq $row[$metric]) { $reasons.Add("$metric missing") }
        }
        $row.Valid = $reasons.Count -eq 0
        $row.InvalidReason = $reasons -join '; '
        $runs.Add([pscustomobject]$row)
    }
}

# Preserve every planned/logged launch even when the app never wrote a JSON report.
# Otherwise a timed-out or crashed process can disappear from runs.csv and pairs.csv.
foreach ($directory in $directories) {
    $directoryLabel = Split-Path -Leaf $directory
    $scheduleFile = Join-Path $directory 'schedule.csv'
    $scheduledNames = @{}
    $candidateNames = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $scheduleFile) {
        foreach ($planned in @(Import-Csv -LiteralPath $scheduleFile)) {
            $name = [string]$planned.Name
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                $scheduledNames[$name] = $true
                if (-not $candidateNames.Contains($name)) { $candidateNames.Add($name) }
            }
        }
    }

    $runLogPath = Join-Path $directory 'runs.log'
    $logByName = @{}
    if (Test-Path -LiteralPath $runLogPath) {
        foreach ($line in @(Get-Content -LiteralPath $runLogPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $entry = $null
            try { $entry = $line | ConvertFrom-Json }
            catch { $deviations.Add(("{0}: malformed runs.log line ignored while locating missing reports" -f $directoryLabel)); continue }
            if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.name)) { continue }
            $logByName[[string]$entry.name] = $entry
            if (-not $candidateNames.Contains([string]$entry.name)) { $candidateNames.Add([string]$entry.name) }
        }
    }

    foreach ($name in @($candidateNames | Sort-Object -Unique)) {
        if ($name -notmatch '^(S[1-4])-pair(\d+)-(plain|runtime)$') { continue }
        $scenario = $Matches[1]; $pair = [int]$Matches[2]; $build = $Matches[3]
        $alreadyRepresented = @($runs | Where-Object { $_.Directory -eq $directoryLabel -and $_.Scenario -eq $scenario -and $_.Pair -eq $pair -and $_.Build -eq $build })
        if ($alreadyRepresented.Count -gt 0) { continue }

        $log = $logByName[$name]
        if ($null -eq $log) {
            $reason = if ($scheduledNames.ContainsKey($name)) { 'scheduled run has no runs.log entry and no JSON report' } else { 'unexpected run has no runs.log entry and no JSON report' }
        } else {
            $reason = "JSON report missing; app exit code $($log.exitCode), timedOut=$($log.timedOut), monitorExit=$($log.monitorExit)"
        }
        $row = [ordered]@{
            Scenario = $scenario; Pair = $pair; Build = $build; Directory = $directoryLabel
            Valid = $false; InvalidReason = $reason
            Passed = $false; Error = 'JSON report missing'
            ExitCode = $(if ($null -ne $log) { $log.exitCode } else { $null })
            TimedOut = $(if ($null -ne $log) { $log.timedOut } else { $null })
            Rounds = $null; PassedRounds = $null; Overruns = $null
            RequestsReceived = $null; OperationsExecuted = $null; CoalescedRequests = $null; CacheHits = $null; FailedRequests = $null
            RequestsPerSecond = $null; RoundMsP50 = $null; RoundMsP95 = $null
            MonitorRows = 0; LoadRows = 0; LoadRowsExpected = $null; LoadRowsWithMissingValues = $null
            LoadRowsWithMissingPrivateValues = $null; LoadRowsWithUnreadableCpu = $null; LoadProcessCountMax = $null
            IntervalMedianSeconds = $null; IntervalMaxSeconds = $null; LoadIntervalMedianSeconds = $null; LoadIntervalMaxSeconds = $null
            MonitorCpuSeconds = $(if ($null -ne $log -and $log.PSObject.Properties['monitorCpuSeconds']) { $log.monitorCpuSeconds } else { $null })
        }
        foreach ($metric in $resourceMetrics) { $row[$metric] = $null }
        $runs.Add([pscustomobject]$row)
    }
}

if ($runs.Count -eq 0) { throw "No run reports, scheduled runs, or logged launches found in $($directories -join ', ')" }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

$numberColumns = @($resourceMetrics + $performanceMetrics)
$formattedColumns = @($numberColumns + @('IntervalMedianSeconds', 'IntervalMaxSeconds', 'LoadIntervalMedianSeconds', 'LoadIntervalMaxSeconds'))
$runs | ForEach-Object {
    $out = [ordered]@{}
    foreach ($property in $_.PSObject.Properties) {
        if ($formattedColumns -contains $property.Name) { $out[$property.Name] = Format-Number $property.Value 3 }
        else { $out[$property.Name] = $property.Value }
    }
    [pscustomobject]$out
} | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'runs.csv') -NoTypeInformation -Encoding UTF8

# Paired differences; a pair is valid only if both of its runs are.
$pairRows = New-Object System.Collections.Generic.List[object]
foreach ($group in @($runs | Group-Object Scenario, Pair | Sort-Object { $_.Group[0].Scenario }, { $_.Group[0].Pair })) {
    $plain = @($group.Group | Where-Object { $_.Build -eq 'plain' })
    $runtime = @($group.Group | Where-Object { $_.Build -eq 'runtime' })
    $reasons = New-Object System.Collections.Generic.List[string]
    if ($plain.Count -ne 1) { $reasons.Add("plain runs: $($plain.Count)") }
    if ($runtime.Count -ne 1) { $reasons.Add("runtime runs: $($runtime.Count)") }
    foreach ($run in @($plain + $runtime)) { if (-not $run.Valid) { $reasons.Add("$($run.Build): $($run.InvalidReason)") } }
    $first = $group.Group[0]
    $pairRow = [ordered]@{ Scenario = $first.Scenario; Pair = $first.Pair; Valid = $reasons.Count -eq 0; InvalidReason = $reasons -join '; ' }
    foreach ($metric in $numberColumns) {
        $pairRow["Plain$metric"] = $null; $pairRow["Runtime$metric"] = $null; $pairRow[$metric] = $null
        if ($plain.Count -eq 1 -and $runtime.Count -eq 1 -and $null -ne $plain[0].$metric -and $null -ne $runtime[0].$metric) {
            $pairRow["Plain$metric"] = [double]$plain[0].$metric
            $pairRow["Runtime$metric"] = [double]$runtime[0].$metric
            $pairRow[$metric] = [double]$runtime[0].$metric - [double]$plain[0].$metric
        }
    }
    $pairRows.Add([pscustomobject]$pairRow)
}
$pairRows | ForEach-Object {
    $out = [ordered]@{ Scenario = $_.Scenario; Pair = $_.Pair; Valid = $_.Valid; InvalidReason = $_.InvalidReason }
    foreach ($metric in $numberColumns) { $out[$metric] = Format-Number $_.$metric }
    [pscustomobject]$out
} | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'pairs.csv') -NoTypeInformation -Encoding UTF8

function Invoke-Analysis {
    # One look: per scenario and metric, statistics over the valid pairs with Pair <= MaxPair.
    param([int]$MaxPair, [double]$Alpha, [string[]]$TestedKeys)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($scenario in @($pairRows | Select-Object -ExpandProperty Scenario -Unique | Sort-Object)) {
        $inLook = @($pairRows | Where-Object { $_.Scenario -eq $scenario -and $_.Pair -le $MaxPair })
        $valid = @($inLook | Where-Object { $_.Valid })
        foreach ($metric in $comparedMetrics) {
            $usable = @($valid | Where-Object { $null -ne $_.$metric })
            $diffs = [double[]]@($usable | ForEach-Object { [double]$_.$metric })
            $plainValues = [double[]]@($usable | ForEach-Object { [double]$_."Plain$metric" })
            $runtimeValues = [double[]]@($usable | ForEach-Object { [double]$_."Runtime$metric" })
            $key = "$scenario/$metric"
            $primary = $primaryMetrics -contains $metric
            $row = [pscustomobject][ordered]@{
                Scenario = $scenario; Metric = $metric
                Role = $(if ($primary) { 'primary' } else { 'descriptive' })
                PairsInLook = $inLook.Count; ValidPairs = $diffs.Count; InvalidPairs = $inLook.Count - $valid.Count
                PlainMedian = Get-Median $plainValues; RuntimeMedian = Get-Median $runtimeValues
                DiffMedian = Get-Median $diffs
                DiffMin = $(if ($diffs.Count -gt 0) { ($diffs | Measure-Object -Minimum).Minimum } else { $null })
                DiffMax = $(if ($diffs.Count -gt 0) { ($diffs | Measure-Object -Maximum).Maximum } else { $null })
                CiLevel = 1 - $Alpha; CiLow = $null; CiHigh = $null; CiCoverage = $null
                P = $null; PHolm = $null; Decided = $false; Verdict = ''
            }
            if ($diffs.Count -ge 1) {
                $interval = [SymmetricBenchStats]::MedianInterval($diffs, 1 - $Alpha)
                if ($null -ne $interval) { $row.CiLow = $interval[0]; $row.CiHigh = $interval[1]; $row.CiCoverage = $interval[2] }
            }
            if ($primary -and $TestedKeys -contains $key -and $diffs.Count -ge $minValidPairsPerLook) {
                $row.P = [SymmetricBenchStats]::SignTestP($diffs)
            }
            $rows.Add($row)
        }
    }
    # Holm over the primary tests of this look.
    $tested = @($rows | Where-Object { $null -ne $_.P } | Sort-Object P)
    $running = 0.0
    for ($k = 0; $k -lt $tested.Count; $k++) {
        $adjusted = [Math]::Min(1.0, ($tested.Count - $k) * $tested[$k].P)
        if ($adjusted -lt $running) { $adjusted = $running }
        $running = $adjusted
        $tested[$k].PHolm = $adjusted
    }
    foreach ($row in $rows) {
        if ($row.ValidPairs -eq 0) { $row.Verdict = 'no valid data'; continue }
        if ($row.Role -ne 'primary') { $row.Verdict = 'descriptive'; continue }
        if ($TestedKeys -notcontains "$($row.Scenario)/$($row.Metric)") { continue }
        if ($null -eq $row.P) { $row.Verdict = "insufficient valid pairs (< $minValidPairsPerLook)"; continue }
        if ($row.PHolm -lt $Alpha) {
            $row.Decided = $true
            if ([Math]::Abs($row.DiffMedian) -lt $practicalThreshold * [Math]::Abs($row.PlainMedian)) { $row.Verdict = 'difference below 2% of plain' }
            elseif ($row.DiffMedian -lt 0) { $row.Verdict = 'runtime lower' }
            else { $row.Verdict = 'runtime higher' }
        }
    }
    return , $rows.ToArray()
}

$allPrimaryKeys = @(foreach ($scenario in @($pairRows | Select-Object -ExpandProperty Scenario -Unique)) { foreach ($metric in $primaryMetrics) { "$scenario/$metric" } })
$looks = New-Object System.Collections.Generic.List[object]
if ($phase -eq 'Pilot') {
    $rows = Invoke-Analysis -MaxPair ([int]::MaxValue) -Alpha 0.05 -TestedKeys @()
    foreach ($row in $rows) { if ($row.Role -eq 'primary' -and $row.ValidPairs -gt 0) { $row.Verdict = 'pilot: no conclusion' } }
    $looks.Add([pscustomobject]@{ Name = 'pilot'; Rows = $rows })
}
else {
    $look1 = Invoke-Analysis -MaxPair $plannedPairsPerLook -Alpha $lookAlpha -TestedKeys $allPrimaryKeys
    $undecided = @($look1 | Where-Object { $_.Role -eq 'primary' -and -not $_.Decided } | ForEach-Object { "$($_.Scenario)/$($_.Metric)" })
    foreach ($row in $look1) {
        if ($row.Role -eq 'primary' -and -not $row.Decided) {
            $note = $(if ($ExtensionDirectory) { 'undecided, tested again at look 2' } else { 'undecided: extend to 20 pairs' })
            $row.Verdict = $(if ($row.Verdict) { "$($row.Verdict); $note" } else { $note })
        }
    }
    $looks.Add([pscustomobject]@{ Name = 'look1'; Rows = $look1 })
    if ($ExtensionDirectory) {
        $look2 = Invoke-Analysis -MaxPair (2 * $plannedPairsPerLook) -Alpha $lookAlpha -TestedKeys $undecided
        foreach ($row in $look2) {
            if ($row.Role -ne 'primary') { continue }
            if ($undecided -notcontains "$($row.Scenario)/$($row.Metric)") { $row.Verdict = 'decided at look 1'; continue }
            if (-not $row.Decided -and -not $row.Verdict) { $row.Verdict = 'no detectable difference' }
        }
        $looks.Add([pscustomobject]@{ Name = 'look2'; Rows = $look2 })
    }
}

$summaryRows = New-Object System.Collections.Generic.List[object]
foreach ($look in $looks) {
    foreach ($row in $look.Rows) {
        $out = [ordered]@{ Look = $look.Name }
        foreach ($property in $row.PSObject.Properties) {
            if (@('P', 'PHolm') -contains $property.Name) { $out[$property.Name] = Format-Number $property.Value 4 }
            elseif (@('PlainMedian', 'RuntimeMedian', 'DiffMedian', 'DiffMin', 'DiffMax', 'CiLow', 'CiHigh') -contains $property.Name) { $out[$property.Name] = Format-Number $property.Value }
            elseif (@('CiLevel', 'CiCoverage') -contains $property.Name) { $out[$property.Name] = Format-Number $property.Value 3 }
            else { $out[$property.Name] = $property.Value }
        }
        $summaryRows.Add([pscustomobject]$out)
    }
}
$summaryRows | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'summary.csv') -NoTypeInformation -Encoding UTF8

# Markdown: protocol notes, correctness, validity, then resources.
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add(('Profile: {0} (nominal monitor interval {1} s). Phase: {2}. Commit {3}. {4}.' -f $monitorProfile, $configuration.sampleIntervalSeconds, $phase, $configuration.gitHead, $configuration.os))
$lines.Add(('Sources: {0}. Analysis: {1}.' -f (($directories | ForEach-Object { Split-Path -Leaf $_ }) -join ', '), (Split-Path -Leaf $OutputDirectory)))
$lines.Add('')
$lines.Add('Estimand: median paired difference (runtime - plain) over valid pairs. MaxSample columns are the largest sampled value, not a guaranteed true peak.')
$lines.Add('')
if ($deviations.Count -gt 0) {
    $lines.Add('## Protocol deviations')
    $lines.Add('')
    foreach ($deviation in $deviations) { $lines.Add("- $deviation") }
    $lines.Add('')
}
$lines.Add('## Correctness (counters per run)')
$lines.Add('')
$lines.Add('| Scenario | Pair | Build | Passed | Rounds passed | Overruns | Received | Executed | Coalesced | Cache hits | Failed | Note |')
$lines.Add('|---|---|---|---|---|---|---|---|---|---|---|---|')
foreach ($run in @($runs | Sort-Object Scenario, Pair, Build)) {
    $lines.Add(('| {0} | {1} | {2} | {3} | {4}/{5} | {6} | {7} | {8} | {9} | {10} | {11} | {12} |' -f $run.Scenario, $run.Pair, $run.Build, $run.Passed, $run.PassedRounds, $run.Rounds, $run.Overruns, $run.RequestsReceived, $run.OperationsExecuted, $run.CoalescedRequests, $run.CacheHits, $run.FailedRequests, $run.Error))
}
$lines.Add('')
$lines.Add('## Run validity and monitoring')
$lines.Add('')
$lines.Add('| Run | Valid | Load rows / expected | Overall / load interval median / load max (s) | Monitor CPU s | Reason |')
$lines.Add('|---|---|---|---|---|---|')
foreach ($run in @($runs | Sort-Object Scenario, Pair, Build)) {
    $lines.Add(('| {0}-{1}-{2} | {3} | {4} / {5} | {6} / {7} / {8} | {9} | {10} |' -f $run.Scenario, $run.Pair, $run.Build, $run.Valid, $run.LoadRows, $run.LoadRowsExpected, (Format-Number $run.IntervalMedianSeconds 3), (Format-Number $run.LoadIntervalMedianSeconds 3), (Format-Number $run.LoadIntervalMaxSeconds 3), $run.MonitorCpuSeconds, $run.InvalidReason))
}
$lines.Add('')
$invalidPairs = @($pairRows | Where-Object { -not $_.Valid })
$lines.Add(('Invalid pairs (kept in pairs.csv, left out of the statistics): {0}' -f $(if ($invalidPairs.Count -eq 0) { 'none' } else { ($invalidPairs | ForEach-Object { "$($_.Scenario) pair $($_.Pair)" }) -join ', ' })))
$lines.Add('')
foreach ($look in $looks) {
    $lines.Add("## Resources and latency, $($look.Name) (paired differences: runtime - plain)")
    $lines.Add('')
    if ($monitorProfile -eq 'Ram') { $lines.Add('CPU metrics are not compared in the Ram profile (0.2 s WMI sampling adds observer overhead).'); $lines.Add('') }
    $lines.Add('| Scenario | Metric | Role | Valid / in look | Plain median | Runtime median | Diff median | Diff min..max | CI of median diff | p (Holm) | Verdict |')
    $lines.Add('|---|---|---|---|---|---|---|---|---|---|---|')
    foreach ($row in @($summaryRows | Where-Object { $_.Look -eq $look.Name })) {
        $ci = if ($row.CiLow -ne '') { '{0}..{1} ({2}%)' -f $row.CiLow, $row.CiHigh, ([double]$row.CiCoverage * 100).ToString('0.#', $culture) } elseif ($row.ValidPairs -gt 0) { "too few pairs for $(([double]$row.CiLevel * 100).ToString('0.#', $culture))%" } else { '' }
        $pText = if ($row.P -ne '') { '{0} ({1})' -f $row.P, $row.PHolm } else { '' }
        $lines.Add(('| {0} | {1} | {2} | {3} / {4} | {5} | {6} | {7} | {8}..{9} | {10} | {11} | {12} |' -f $row.Scenario, $row.Metric, $row.Role, $row.ValidPairs, $row.PairsInLook, $row.PlainMedian, $row.RuntimeMedian, $row.DiffMedian, $row.DiffMin, $row.DiffMax, $ci, $pText, $row.Verdict))
    }
    $lines.Add('')
}
$lines | Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.md') -Encoding UTF8
Write-Host "Wrote runs.csv, pairs.csv, summary.csv and summary.md to $OutputDirectory"
