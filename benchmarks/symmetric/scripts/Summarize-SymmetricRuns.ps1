<#
.SYNOPSIS
Summarizes Run-SymmetricPairs.ps1 results: one row per run with its validity,
the paired differences (runtime - plain) and, per profile, scenario and
metric, the medians, the range of the differences and a verdict.

.DESCRIPTION
Correctness (counters) and resources (memory, CPU) are reported separately:
coalescing or cache hits alone are not evidence of lower RAM or CPU use.

The rule is the one in README.md ("Statistical rule"); in short:
- One family of confirmatory hypotheses over both profiles: per scenario,
  LoadCpuSeconds from the Cpu profile and LoadPrivateMBAvg from the Ram
  profile (8 tests). Everything else is secondary and descriptive.
- Estimand: the median paired difference (runtime - plain). The test, the
  interval and the 2% threshold all refer to it. Statistics use the values
  as read from the raw files; nothing is rounded before them.
- Validity: a run is valid only if it passes every check listed in README.md
  ("Run validity"); a pair is valid only if both of its runs are. Invalid
  runs and pairs stay in runs.csv and pairs.csv with their reasons and are
  left out of every median, interval and p-value.
- Test: two-sided sign test that keeps zero differences in n (exact without
  ties, conservative with them), Holm within a look over every hypothesis of
  the declared family, with p = 1 where no p-value can be computed. Interval: closed order-statistic interval for
  the median over all differences, with a guaranteed minimum coverage
  (exact only without ties; see SymmetricBenchStats.cs).
- Confirmatory protocol: one fixed family analysis at alpha 0.05 after
  the predeclared 20 pairs per scenario and profile; no interim looks,
  data-dependent extensions, or pair replacements.
- Pilot results get "pilot: no conclusion" whatever the numbers.

Analysis files go to a new directory (default <last results directory>\
analysis-<timestamp>), so the raw data and earlier analyses are never
overwritten.
#>
[CmdletBinding()]
param(
    # One directory per profile. Confirmatory analysis needs both a Cpu and a Ram directory,
    # because the hypotheses form one family over both profiles.
    [Parameter(Mandatory = $true)]
    [string[]]$ResultsDirectory,

    [string]$OutputDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$culture = [System.Globalization.CultureInfo]::InvariantCulture

if (-not ('SymmetricBenchStats' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'SymmetricBenchStats.cs')
}

# Fixed protocol values (README.md, "Statistical rule" and "Run validity").
$plannedPairs = 20
$minValidPairs = 8
$analysisAlpha = 0.05
$practicalThreshold = 0.02
$minLoadCoverage = 0.8
$maxIntervalDeviation = 0.2
$maxIntervalFactor = 5

function ConvertTo-Number {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    $number = 0.0
    if (-not [double]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Float, $culture, [ref]$number)) { return $null }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { return $null }
    return $number
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

# Full precision for CSV files, so a recomputation from them gives the same statistics.
function Format-Raw {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or '' -eq $Value) { return '' }
    return ([double]$Value).ToString('R', $culture)
}

function Get-Time {
    param([string]$Text)
    return [DateTimeOffset]::Parse($Text, $culture)
}

function Select-Phase {
    param([object[]]$Rows, [DateTimeOffset]$From, [DateTimeOffset]$To)
    @($Rows | Where-Object { $_.Time -ge $From -and $_.Time -lt $To })
}

function Get-LogReasons {
    param([AllowNull()][object]$Log)
    if ($null -eq $Log) { return @('no runs.log entry') }
    $reasons = @()
    if (-not $Log.PSObject.Properties['exitCode'] -or $null -eq $Log.exitCode -or [int]$Log.exitCode -ne 0) { $reasons += "app exit code '$(Get-ConfigValue $Log 'exitCode' '')'" }
    if (-not $Log.PSObject.Properties['timedOut'] -or $Log.timedOut) { $reasons += 'timed out or timeout not recorded' }
    if (-not $Log.PSObject.Properties['monitorExit'] -or $null -eq $Log.monitorExit -or [int]$Log.monitorExit -ne 0) { $reasons += "monitor exit code '$(Get-ConfigValue $Log 'monitorExit' '')'" }
    return $reasons
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

$deviations = New-Object System.Collections.Generic.List[string]
$identityFields = @('machine', 'gitHead', 'plainExeSha256', 'runtimeExeSha256', 'durationSeconds', 'idleSeconds', 'pauseSeconds',
    'iterations', 'bufferMb', 'requestsPerWindow', 'roundIntervalMs', 'runScriptSha256', 'summarizeScriptSha256', 'protocolSha256', 'order')
$familyScenarios = @('S1', 'S2', 'S3', 'S4')
$sources = New-Object System.Collections.Generic.List[object]
foreach ($path in $ResultsDirectory) {
    $directory = (Resolve-Path -LiteralPath $path).Path
    $sources.Add([pscustomobject]@{ Directory = $directory; Configuration = (Read-Configuration $directory) })
}
$phases = @($sources | ForEach-Object { [string]$_.Configuration.phase } | Select-Object -Unique)
if ($phases.Count -ne 1) { throw "All results directories must have the same phase (got $($phases -join ', '))." }
$phase = $phases[0]
$profiles = @($sources | ForEach-Object { [string]$_.Configuration.profile })
if (@($profiles | Select-Object -Unique).Count -ne $profiles.Count) { throw "Give at most one results directory per profile (got $($profiles -join ', '))." }
$firstConfiguration = $sources[0].Configuration
foreach ($source in $sources) {
    foreach ($name in $identityFields) {
        if ([string](Get-ConfigValue $firstConfiguration $name '') -ne [string](Get-ConfigValue $source.Configuration $name '')) {
            $message = "$(Split-Path -Leaf $source.Directory) differs from $(Split-Path -Leaf $sources[0].Directory) in '$name'"
            if ($phase -eq 'Confirmatory') { throw "$message; the profiles cannot form one family." }
            $deviations.Add($message)
        }
    }
}
if ($phase -eq 'Confirmatory') {
    if ((($profiles | Sort-Object) -join ',') -ne 'Cpu,Ram') { throw 'Confirmatory analysis needs one Cpu and one Ram results directory: the family covers both profiles.' }
    foreach ($source in $sources) {
        if ([int](Get-ConfigValue $source.Configuration 'firstPair' 1) -ne 1 -or [int]$source.Configuration.pairs -ne $plannedPairs) {
            throw "Confirmatory analysis requires predeclared pairs 1..$plannedPairs in one series (got firstPair $(Get-ConfigValue $source.Configuration 'firstPair' 1), pairs $($source.Configuration.pairs))."
        }
        if ((@($source.Configuration.scenarios | ForEach-Object { [string]$_ } | Sort-Object) -join ',') -ne ($familyScenarios -join ',')) {
            throw "Confirmatory analysis must schedule all of $($familyScenarios -join ', ') (got $(@($source.Configuration.scenarios) -join ', ')): the family is fixed over all scenarios."
        }
    }
}
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $sources[$sources.Count - 1].Directory ("analysis-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
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
# The confirmatory family: one primary metric per profile and scenario. CPU is judged only at
# the 1 s rate, memory only at the 0.2 s rate; the other metrics of each profile are secondary.
$primaryByProfile = @{ Cpu = 'LoadCpuSeconds'; Ram = 'LoadPrivateMBAvg' }
$comparedByProfile = @{ Cpu = @($resourceMetrics + $performanceMetrics); Ram = @($memoryMetrics + $performanceMetrics) }

$runs = New-Object System.Collections.Generic.List[object]
foreach ($source in $sources) {
    $directory = $source.Directory
    $monitorProfile = [string]$source.Configuration.profile
    $nominalInterval = [double]$source.Configuration.sampleIntervalSeconds
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
    $scheduled = @()
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
    if ($phase -eq 'Confirmatory') {
        $expectedNames = New-Object System.Collections.Generic.List[string]
        foreach ($scenarioName in $familyScenarios) {
            for ($pairNumber = 1; $pairNumber -le $plannedPairs; $pairNumber++) {
                $plannedBuildOrder = if ($pairNumber % 2 -eq 1) { @('plain', 'runtime') } else { @('runtime', 'plain') }
                foreach ($buildName in $plannedBuildOrder) { $expectedNames.Add(('{0}-pair{1:D2}-{2}' -f $scenarioName, $pairNumber, $buildName)) }
            }
        }
        $missingFromSchedule = @($expectedNames | Where-Object { $scheduled -notcontains $_ })
        $extraInSchedule = @($scheduled | Where-Object { $expectedNames -notcontains $_ })
        if ($missingFromSchedule.Count -gt 0 -or $extraInSchedule.Count -gt 0 -or $scheduled.Count -ne $expectedNames.Count) {
            throw "Confirmatory schedule must list all planned runs for pairs 1..$plannedPairs exactly once. Missing: $($missingFromSchedule -join ', '); extra: $($extraInSchedule -join ', ')."
        }
        if (($scheduled -join ',') -ne ($expectedNames -join ',')) {
            throw "Confirmatory schedule does not match the fixed alternated order for pairs 1..$plannedPairs."
        }
    }

    $reportFilesByName = @{}
    foreach ($reportFile in @(Get-ChildItem -LiteralPath $runsDirectory -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $reportBase = [System.IO.Path]::GetFileNameWithoutExtension($reportFile.Name)
        if ($reportBase -match '^(S[1-4])-pair(\d+)-(plain|runtime)
        $row = [ordered]@{
            Profile = $monitorProfile; Scenario = $scenario; Pair = $pair; Build = $build; Directory = Split-Path -Leaf $directory
            Valid = $false; InvalidReason = ''
            Passed = $false; Error = ''
            ExitCode = $(if ($null -ne $log) { $log.exitCode } else { $null })
            TimedOut = $(if ($null -ne $log) { $log.timedOut } else { $null })
            Rounds = $null; PassedRounds = $null; Overruns = $null
            RequestsReceived = $null; OperationsExecuted = $null; CoalescedRequests = $null; CacheHits = $null; FailedRequests = $null
            RequestsPerSecond = $null; RoundMsP50 = $null; RoundMsP95 = $null
            MonitorExit = $(if ($null -ne $log -and $log.PSObject.Properties['monitorExit']) { $log.monitorExit } else { $null })
            MonitorRows = 0; LoadRows = 0; LoadRowsExpected = $null
            LoadRowsWithMissingPrivate = $null; LoadRowsWithUnreadableCpu = $null; LoadRowsWithMissingWorkingSet = $null
            LoadRowsWithInvalidInterval = $null; LoadProcessCountMax = $null
            PrivateMetricsValid = $false; CpuMetricsValid = $false; WorkingSetMetricsValid = $false; DiagnosticsPrivateMetricsValid = $false
            IdleBeforePrivateMetricsValid = $false; IdleAfterPrivateMetricsValid = $false; IdleBeforeCpuMetricsValid = $false
            IntervalMedianSeconds = $null; IntervalMaxSeconds = $null; LoadIntervalMedianSeconds = $null; LoadIntervalMaxSeconds = $null
            MonitorCpuSeconds = $(if ($null -ne $log -and $log.PSObject.Properties['monitorCpuSeconds']) { $log.monitorCpuSeconds } else { $null })
        }
        foreach ($metric in $resourceMetrics) { $row[$metric] = $null }
        $seen[$base] = $true

        foreach ($reason in @(Get-LogReasons $log)) { $reasons.Add($reason) }
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
                        Timestamp  = [string]$_.Timestamp
                        Time       = Get-Time $_.Timestamp
                        RootPid    = [int]$_.RootPid
                        Processes  = [int]$_.ProcessCount
                        WorkingSet = ConvertTo-Number $_.WorkingSetMB
                        Private    = ConvertTo-Number $_.PrivateBytesMB
                        CpuDelta   = ConvertTo-Number $_.CpuDeltaSeconds
                        Sample     = [int]$_.Sample
                        Interval   = ConvertTo-Number $_.IntervalSeconds
                        PrivateMissing = ConvertTo-Number $_.PrivateMissingCount
                        CpuUnreadable  = ConvertTo-Number $_.CpuUnreadableCount
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
            # The cadence is checked inside the load phase itself; the whole-run median is only context.
            $row.LoadRowsWithInvalidInterval = @($load | Where-Object { $_.Sample -eq 0 -or $null -eq $_.Interval -or $_.Interval -le 0 }).Count
            $loadIntervals = @($load | Where-Object { $_.Sample -gt 0 -and $null -ne $_.Interval -and $_.Interval -gt 0 } | ForEach-Object { $_.Interval })
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
            $row.LoadRowsWithMissingPrivate = @($load | Where-Object { $null -eq $_.Private -or $null -eq $_.PrivateMissing -or $_.PrivateMissing -gt 0 }).Count
            $row.LoadRowsWithUnreadableCpu = @($load | Where-Object { $null -eq $_.CpuDelta -or $null -eq $_.CpuUnreadable -or $_.CpuUnreadable -gt 0 }).Count
            $row.LoadRowsWithMissingWorkingSet = @($load | Where-Object { $null -eq $_.WorkingSet }).Count
            $row.LoadProcessCountMax = Get-Max @($load | ForEach-Object { [double]$_.Processes })
            $row.PrivateMetricsValid = $load.Count -gt 0 -and $row.LoadRowsWithMissingPrivate -eq 0
            $row.CpuMetricsValid = $load.Count -gt 0 -and $row.LoadRowsWithUnreadableCpu -eq 0
            $row.WorkingSetMetricsValid = $load.Count -gt 0 -and $row.LoadRowsWithMissingWorkingSet -eq 0
            $row.IdleBeforePrivateMetricsValid = $idleBefore.Count -gt 0 -and @($idleBefore | Where-Object { $null -eq $_.Private -or $null -eq $_.PrivateMissing -or $_.PrivateMissing -gt 0 }).Count -eq 0
            $row.IdleAfterPrivateMetricsValid = $idleAfter.Count -gt 0 -and @($idleAfter | Where-Object { $null -eq $_.Private -or $null -eq $_.PrivateMissing -or $_.PrivateMissing -gt 0 }).Count -eq 0
            $idleBeforeCpuRows = @($idleBefore | Where-Object { $_.Sample -gt 0 })
            $row.IdleBeforeCpuMetricsValid = $idleBeforeCpuRows.Count -gt 0 -and @($idleBeforeCpuRows | Where-Object { $null -eq $_.CpuDelta -or $null -eq $_.CpuUnreadable -or $_.CpuUnreadable -gt 0 }).Count -eq 0

            # A secondary metric with incomplete samples is not averaged over only the readable rows.
            if (-not $row.PrivateMetricsValid) { $row.LoadPrivateMBAvg = $null; $row.LoadPrivateMBMaxSample = $null }
            if (-not $row.WorkingSetMetricsValid) { $row.LoadWorkingSetMBAvg = $null; $row.LoadWorkingSetMBMaxSample = $null }
            if (-not $row.CpuMetricsValid) { $row.LoadCpuSeconds = $null }
            if (-not $row.IdleBeforePrivateMetricsValid) { $row.IdleBeforePrivateMB = $null }
            if (-not $row.IdleAfterPrivateMetricsValid) { $row.IdleAfterPrivateMB = $null }
            if (-not $row.IdleBeforeCpuMetricsValid) { $row.IdleBeforeCpuSeconds = $null }

            if ($row.LoadRowsExpected -gt 0 -and $row.LoadRows -lt $minLoadCoverage * $row.LoadRowsExpected) { $reasons.Add("load rows $($row.LoadRows) < $([int]($minLoadCoverage * 100))% of $($row.LoadRowsExpected)") }
            # Private memory is primary only in the Ram profile; an incomplete secondary private-memory metric
            # does not discard otherwise valid CPU observations in the Cpu profile.
            if ($monitorProfile -eq 'Ram' -and -not $row.PrivateMetricsValid) { $reasons.Add("$($row.LoadRowsWithMissingPrivate) load rows with missing or non-finite private memory") }
            # CPU is compared only in the Cpu profile, so unreadable CPU invalidates only those runs.
            if ($monitorProfile -eq 'Cpu' -and -not $row.CpuMetricsValid) { $reasons.Add("$($row.LoadRowsWithUnreadableCpu) load rows with missing or non-finite CPU") }
            if ($row.LoadRowsWithInvalidInterval -gt 0) { $reasons.Add("$($row.LoadRowsWithInvalidInterval) load rows with a missing, non-finite or non-positive interval") }
            if ($null -eq $row.LoadIntervalMedianSeconds -or [Math]::Abs($row.LoadIntervalMedianSeconds - $nominalInterval) -gt $maxIntervalDeviation * $nominalInterval) {
                $reasons.Add("load interval median $(Format-Number $row.LoadIntervalMedianSeconds 3) s not within $([int]($maxIntervalDeviation * 100))% of $nominalInterval s")
            }
            if ($null -ne $row.LoadIntervalMaxSeconds -and $row.LoadIntervalMaxSeconds -gt $maxIntervalFactor * $nominalInterval) {
                $reasons.Add("load gap $(Format-Number $row.LoadIntervalMaxSeconds 3) s > $maxIntervalFactor x $nominalInterval s")
            }

            $diagnosticsFile = Join-Path $runsDirectory "$base.monitor.diagnostics.csv"
            if ((Test-Path -LiteralPath $diagnosticsFile) -and $samples.Count -gt 0) {
                $rootPid = $samples[0].RootPid
                $diagnosticLoadRows = @(Import-Csv -LiteralPath $diagnosticsFile | Where-Object { $_.InTree -eq 'True' } | Where-Object {
                        $time = Get-Time $_.Timestamp; $time -ge $loadFrom -and $time -lt $loadTo
                    })
                $row.DiagnosticsPrivateMetricsValid = $load.Count -gt 0 -and $diagnosticLoadRows.Count -gt 0
                if ($row.DiagnosticsPrivateMetricsValid) {
                    foreach ($sample in $load) {
                        $atSample = @($diagnosticLoadRows | Where-Object { $_.Timestamp -eq $sample.Timestamp })
                        $atSampleBytes = @($atSample | ForEach-Object { ConvertTo-Number $_.CimPrivatePageCount })
                        if ($atSample.Count -ne $sample.Processes -or $atSampleBytes.Count -ne $atSample.Count -or @($atSampleBytes | Where-Object { $null -eq $_ }).Count -gt 0) {
                            $row.DiagnosticsPrivateMetricsValid = $false
                            break
                        }
                    }
                }
                $rootRows = @($diagnosticLoadRows | Where-Object { [int]$_.Pid -eq $rootPid })
                $rootValues = @($rootRows | ForEach-Object { ConvertTo-Number $_.CimPrivatePageCount })
                if ($rootRows.Count -ne $load.Count -or $rootValues.Count -ne $rootRows.Count -or @($rootValues | Where-Object { $null -eq $_ }).Count -gt 0) {
                    $row.DiagnosticsPrivateMetricsValid = $false
                }
                if ($row.DiagnosticsPrivateMetricsValid) {
                    $row.ExePrivateMBLoadAvg = Get-Average @($rootValues | ForEach-Object { $_ / 1MB })
                    if ($row.PrivateMetricsValid -and $null -ne $row.LoadPrivateMBAvg) {
                        $row.WebViewPrivateMBLoadAvg = $row.LoadPrivateMBAvg - $row.ExePrivateMBLoadAvg
                    }
                }
                else {
                    $row.ExePrivateMBLoadAvg = $null
                    $row.WebViewPrivateMBLoadAvg = $null
                }
            }
        }
        else {
            $reasons.Add('monitor CSV missing')
        }
        $primaryMetric = $primaryByProfile[$monitorProfile]
        if ($null -eq $row[$primaryMetric]) { $reasons.Add("$primaryMetric missing") }
        $row.Valid = $reasons.Count -eq 0
        $row.InvalidReason = $reasons -join '; '
        $runs.Add([pscustomobject]$row)
    }

    # A scheduled or logged launch without a JSON report stays in the data as an invalid run,
    # so a crash or timeout cannot drop a pair from the family.
    $expectedNames = @(@($scheduled) + @($logOrder) | Where-Object { $_ -match '^S[1-4]-pair\d+-(plain|runtime)$' } | Sort-Object -Unique)
    foreach ($name in $expectedNames) {
        if ($seen.ContainsKey($name)) { continue }
        $null = $name -match '^(S[1-4])-pair(\d+)-(plain|runtime)$'
        $log = $logByRun[$name]
        $reasons = New-Object System.Collections.Generic.List[string]
        $reasons.Add('JSON report missing')
        foreach ($reason in @(Get-LogReasons $log)) { $reasons.Add($reason) }
        $row = [ordered]@{
            Profile = $monitorProfile; Scenario = $Matches[1]; Pair = [int]$Matches[2]; Build = $Matches[3]; Directory = Split-Path -Leaf $directory
            Valid = $false; InvalidReason = $reasons -join '; '
            Passed = $false; Error = 'JSON report missing'
            ExitCode = $(if ($null -ne $log) { $log.exitCode } else { $null })
            TimedOut = $(if ($null -ne $log) { $log.timedOut } else { $null })
            Rounds = $null; PassedRounds = $null; Overruns = $null
            RequestsReceived = $null; OperationsExecuted = $null; CoalescedRequests = $null; CacheHits = $null; FailedRequests = $null
            RequestsPerSecond = $null; RoundMsP50 = $null; RoundMsP95 = $null
            MonitorExit = $(if ($null -ne $log -and $log.PSObject.Properties['monitorExit']) { $log.monitorExit } else { $null })
            MonitorRows = 0; LoadRows = 0; LoadRowsExpected = $null
            LoadRowsWithMissingPrivate = $null; LoadRowsWithUnreadableCpu = $null; LoadRowsWithMissingWorkingSet = $null
            LoadRowsWithInvalidInterval = $null; LoadProcessCountMax = $null
            PrivateMetricsValid = $false; CpuMetricsValid = $false; WorkingSetMetricsValid = $false; DiagnosticsPrivateMetricsValid = $false
            IdleBeforePrivateMetricsValid = $false; IdleAfterPrivateMetricsValid = $false; IdleBeforeCpuMetricsValid = $false
            IntervalMedianSeconds = $null; IntervalMaxSeconds = $null; LoadIntervalMedianSeconds = $null; LoadIntervalMaxSeconds = $null
            MonitorCpuSeconds = $(if ($null -ne $log -and $log.PSObject.Properties['monitorCpuSeconds']) { $log.monitorCpuSeconds } else { $null })
        }
        $row.PrivateMetricsValid = $false; $row.CpuMetricsValid = $false; $row.WorkingSetMetricsValid = $false; $row.DiagnosticsPrivateMetricsValid = $false
        $row.IdleBeforePrivateMetricsValid = $false; $row.IdleAfterPrivateMetricsValid = $false; $row.IdleBeforeCpuMetricsValid = $false
        foreach ($metric in $resourceMetrics) { $row[$metric] = $null }
        $runs.Add([pscustomobject]$row)
    }
}

if ($runs.Count -eq 0) { throw "No run reports found in $(($sources | ForEach-Object { $_.Directory }) -join ', ')" }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

$numberColumns = @($resourceMetrics + $performanceMetrics)
$formattedColumns = @($numberColumns + @('IntervalMedianSeconds', 'IntervalMaxSeconds', 'LoadIntervalMedianSeconds', 'LoadIntervalMaxSeconds'))
$runs | ForEach-Object {
    $out = [ordered]@{}
    foreach ($property in $_.PSObject.Properties) {
        if ($formattedColumns -contains $property.Name) { $out[$property.Name] = Format-Raw $property.Value }
        else { $out[$property.Name] = $property.Value }
    }
    [pscustomobject]$out
} | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'runs.csv') -NoTypeInformation -Encoding UTF8

# Paired differences; a pair is valid only if both of its runs are.
$pairRows = New-Object System.Collections.Generic.List[object]
foreach ($group in @($runs | Group-Object Profile, Scenario, Pair | Sort-Object { $_.Group[0].Profile }, { $_.Group[0].Scenario }, { $_.Group[0].Pair })) {
    $plain = @($group.Group | Where-Object { $_.Build -eq 'plain' })
    $runtime = @($group.Group | Where-Object { $_.Build -eq 'runtime' })
    $reasons = New-Object System.Collections.Generic.List[string]
    if ($plain.Count -ne 1) { $reasons.Add("plain runs: $($plain.Count)") }
    if ($runtime.Count -ne 1) { $reasons.Add("runtime runs: $($runtime.Count)") }
    foreach ($run in @($plain + $runtime)) { if (-not $run.Valid) { $reasons.Add("$($run.Build): $($run.InvalidReason)") } }
    $first = $group.Group[0]
    $pairRow = [ordered]@{ Profile = $first.Profile; Scenario = $first.Scenario; Pair = $first.Pair; Valid = $reasons.Count -eq 0; InvalidReason = $reasons -join '; ' }
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
    $out = [ordered]@{ Profile = $_.Profile; Scenario = $_.Scenario; Pair = $_.Pair; Valid = $_.Valid; InvalidReason = $_.InvalidReason }
    foreach ($metric in $numberColumns) {
        $out["Plain$metric"] = Format-Raw $_."Plain$metric"; $out["Runtime$metric"] = Format-Raw $_."Runtime$metric"; $out[$metric] = Format-Raw $_.$metric
    }
    [pscustomobject]$out
} | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'pairs.csv') -NoTypeInformation -Encoding UTF8

function Invoke-Analysis {
    # One look: per profile, scenario and metric, statistics over the valid pairs with Pair <= MaxPair.
    param([int]$MaxPair, [double]$Alpha, [string[]]$TestedKeys)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($cell in $cells) {
        $monitorProfile = $cell.Profile; $scenario = $cell.Scenario
        $inLook = @($pairRows | Where-Object { $_.Profile -eq $monitorProfile -and $_.Scenario -eq $scenario -and $_.Pair -le $MaxPair })
        $valid = @($inLook | Where-Object { $_.Valid })
        foreach ($metric in $comparedByProfile[$monitorProfile]) {
            $usable = @($valid | Where-Object { $null -ne $_.$metric })
            $diffs = [double[]]@($usable | ForEach-Object { [double]$_.$metric })
            $plainValues = [double[]]@($usable | ForEach-Object { [double]$_."Plain$metric" })
            $runtimeValues = [double[]]@($usable | ForEach-Object { [double]$_."Runtime$metric" })
            $key = "$monitorProfile/$scenario/$metric"
            $primary = $primaryByProfile[$monitorProfile] -eq $metric
            $row = [pscustomobject][ordered]@{
                Profile = $monitorProfile; Scenario = $scenario; Metric = $metric
                Role = $(if ($primary) { 'primary' } else { 'secondary' })
                PairsInLook = $inLook.Count; ValidPairs = $diffs.Count; InvalidPairs = $inLook.Count - $valid.Count
                MetricExcludedPairs = $valid.Count - $usable.Count
                ZeroDiffs = [SymmetricBenchStats]::CountZeros($diffs)
                PlainMedian = Get-Median $plainValues; RuntimeMedian = Get-Median $runtimeValues
                DiffMedian = Get-Median $diffs
                DiffMin = $(if ($diffs.Count -gt 0) { ($diffs | Measure-Object -Minimum).Minimum } else { $null })
                DiffMax = $(if ($diffs.Count -gt 0) { ($diffs | Measure-Object -Maximum).Maximum } else { $null })
                CiLevel = 1 - $Alpha; CiLow = $null; CiHigh = $null; CiCoverageMin = $null
                P = $null; PHolm = $null; Decided = $false; Verdict = ''
            }
            if ($diffs.Count -ge 1) {
                $interval = [SymmetricBenchStats]::MedianInterval($diffs, 1 - $Alpha)
                if ($null -ne $interval) { $row.CiLow = $interval[0]; $row.CiHigh = $interval[1]; $row.CiCoverageMin = $interval[2] }
            }
            if ($primary -and $TestedKeys -contains $key -and $diffs.Count -ge $minValidPairsPerLook) {
                $row.P = [SymmetricBenchStats]::SignTestP($diffs)
            }
            $rows.Add($row)
        }
    }
    # Holm over every hypothesis tested in this look. One without a p-value (too few valid
    # pairs) stays in the family with p = 1, so failed runs never weaken the correction.
    $tested = @($rows | Where-Object { $_.Role -eq 'primary' -and $TestedKeys -contains "$($_.Profile)/$($_.Scenario)/$($_.Metric)" } |
        ForEach-Object { [pscustomobject]@{ Row = $_; P = $(if ($null -eq $_.P) { 1.0 } else { [double]$_.P }) } } | Sort-Object P)
    if ($tested.Count -ne $TestedKeys.Count) { throw "Holm family has $($tested.Count) rows for $($TestedKeys.Count) hypotheses." }
    $running = 0.0
    for ($k = 0; $k -lt $tested.Count; $k++) {
        $adjusted = [Math]::Min(1.0, ($tested.Count - $k) * $tested[$k].P)
        if ($adjusted -lt $running) { $adjusted = $running }
        $running = $adjusted
        $tested[$k].Row.PHolm = $adjusted
    }
    foreach ($row in $rows) {
        if ($row.ValidPairs -eq 0) { $row.Verdict = 'no valid data'; continue }
        if ($row.Role -ne 'primary') { $row.Verdict = 'secondary: descriptive'; continue }
        if ($TestedKeys -notcontains "$($row.Profile)/$($row.Scenario)/$($row.Metric)") { continue }
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

# Cells analysed: the declared family (Cpu and Ram x S1-S4) for confirmatory results, whatever
# data exists; the cells present in the data for a pilot.
$cells = if ($phase -eq 'Confirmatory') {
    @(foreach ($profileName in @('Cpu', 'Ram')) { foreach ($scenario in $familyScenarios) { [pscustomobject]@{ Profile = $profileName; Scenario = $scenario } } })
}
else { @($pairRows | Select-Object Profile, Scenario -Unique | Sort-Object Profile, Scenario) }
$allPrimaryKeys = @($cells | ForEach-Object { "$($_.Profile)/$($_.Scenario)/$($primaryByProfile[$_.Profile])" })
$hasExtension = @($sources | Where-Object { $_.Look -eq 2 }).Count -gt 0
$looks = New-Object System.Collections.Generic.List[object]
if ($phase -eq 'Pilot') {
    $rows = Invoke-Analysis -MaxPair ([int]::MaxValue) -Alpha 0.05 -TestedKeys @()
    foreach ($row in $rows) { if ($row.Role -eq 'primary' -and $row.ValidPairs -gt 0) { $row.Verdict = 'pilot: no conclusion' } }
    $looks.Add([pscustomobject]@{ Name = 'pilot'; Rows = $rows })
}
else {
    $look1 = Invoke-Analysis -MaxPair $plannedPairsPerLook -Alpha $lookAlpha -TestedKeys $allPrimaryKeys
    $undecided = @($look1 | Where-Object { $_.Role -eq 'primary' -and -not $_.Decided } | ForEach-Object { "$($_.Profile)/$($_.Scenario)/$($_.Metric)" })
    foreach ($row in $look1) {
        if ($row.Role -eq 'primary' -and -not $row.Decided) {
            $note = $(if ($hasExtension) { 'undecided, tested again at look 2' } else { 'undecided: extend to 20 pairs' })
            $row.Verdict = $(if ($row.Verdict) { "$($row.Verdict); $note" } else { $note })
        }
    }
    $looks.Add([pscustomobject]@{ Name = 'look1'; Rows = $look1 })
    if ($hasExtension) {
        # Fail closed: every undecided hypothesis needs its own planned pairs 11-20, and the
        # extension holds exactly the undecided scenarios, so look 1 data is never re-tested as look 2.
        foreach ($profileName in @('Cpu', 'Ram')) {
            $required = @($undecided | Where-Object { $_.Split('/')[0] -eq $profileName } | ForEach-Object { $_.Split('/')[1] } | Sort-Object -Unique)
            $extensionSource = @($sources | Where-Object { $_.Look -eq 2 -and [string]$_.Configuration.profile -eq $profileName })
            $configured = if ($extensionSource.Count -eq 1) { @($extensionSource[0].Configuration.scenarios | ForEach-Object { [string]$_ } | Sort-Object -Unique) } else { @() }
            if (($required -join ',') -ne ($configured -join ',')) {
                throw "Profile ${profileName}: the extension must hold exactly the scenarios undecided at look 1 [$($required -join ', ')], got [$($configured -join ', ')]."
            }
            foreach ($scenario in $required) {
                for ($pairNumber = $plannedPairsPerLook + 1; $pairNumber -le 2 * $plannedPairsPerLook; $pairNumber++) {
                    $found = @($pairRows | Where-Object { $_.Profile -eq $profileName -and $_.Scenario -eq $scenario -and $_.Pair -eq $pairNumber }).Count
                    if ($found -ne 1) { throw "Profile $profileName ${scenario}: planned pair $pairNumber appears $found times; look 2 needs each of pairs $($plannedPairsPerLook + 1)..$(2 * $plannedPairsPerLook) once." }
                }
            }
        }
        $look2 = Invoke-Analysis -MaxPair (2 * $plannedPairsPerLook) -Alpha $lookAlpha -TestedKeys $undecided
        foreach ($row in $look2) {
            if ($row.Role -ne 'primary') { continue }
            if ($undecided -notcontains "$($row.Profile)/$($row.Scenario)/$($row.Metric)") { $row.Verdict = 'decided at look 1'; continue }
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
            if (@('P', 'PHolm', 'PlainMedian', 'RuntimeMedian', 'DiffMedian', 'DiffMin', 'DiffMax', 'CiLevel', 'CiLow', 'CiHigh', 'CiCoverageMin') -contains $property.Name) {
                $out[$property.Name] = Format-Raw $property.Value
            }
            else { $out[$property.Name] = $property.Value }
        }
        $summaryRows.Add([pscustomobject]$out)
    }
}
$summaryRows | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'summary.csv') -NoTypeInformation -Encoding UTF8

# Markdown: protocol notes, correctness, validity, then resources.
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add(('Phase: {0}. Commit {1}. {2}. Analysis: {3}.' -f $phase, $firstConfiguration.gitHead, $firstConfiguration.os, (Split-Path -Leaf $OutputDirectory)))
$lines.Add('')
foreach ($source in $sources) {
    $lines.Add(('- {0}: profile {1}, nominal monitor interval {2} s, look {3}' -f (Split-Path -Leaf $source.Directory), $source.Configuration.profile, $source.Configuration.sampleIntervalSeconds, $source.Look))
}
$lines.Add('')
$lines.Add('Estimand: median paired difference (runtime - plain) over valid pairs. Primary family: LoadCpuSeconds (Cpu profile) and LoadPrivateMBAvg (Ram profile) per scenario, Holm over all of them. MaxSample columns are the largest sampled value, not a guaranteed true peak. CI coverage is a guaranteed minimum (exact only without ties).')
$lines.Add('')
if ($deviations.Count -gt 0) {
    $lines.Add('## Protocol deviations')
    $lines.Add('')
    foreach ($deviation in $deviations) { $lines.Add("- $deviation") }
    $lines.Add('')
}
$lines.Add('## Correctness (counters per run)')
$lines.Add('')
$lines.Add('| Profile | Scenario | Pair | Build | Passed | Rounds passed | Overruns | Received | Executed | Coalesced | Cache hits | Failed | Note |')
$lines.Add('|---|---|---|---|---|---|---|---|---|---|---|---|---|')
foreach ($run in @($runs | Sort-Object Profile, Scenario, Pair, Build)) {
    $lines.Add(('| {13} | {0} | {1} | {2} | {3} | {4}/{5} | {6} | {7} | {8} | {9} | {10} | {11} | {12} |' -f $run.Scenario, $run.Pair, $run.Build, $run.Passed, $run.PassedRounds, $run.Rounds, $run.Overruns, $run.RequestsReceived, $run.OperationsExecuted, $run.CoalescedRequests, $run.CacheHits, $run.FailedRequests, $run.Error, $run.Profile))
}
$lines.Add('')
$lines.Add('## Run validity and monitoring')
$lines.Add('')
$lines.Add('| Run | Valid | Load rows / expected | Interval median: run / load; load max (s) | Monitor exit / CPU s | Reason |')
$lines.Add('|---|---|---|---|---|---|')
foreach ($run in @($runs | Sort-Object Profile, Scenario, Pair, Build)) {
    $lines.Add(('| {10} {0}-{1}-{2} | {3} | {4} / {5} | {6} / {11}; {7} | {12} / {8} | {9} |' -f $run.Scenario, $run.Pair, $run.Build, $run.Valid, $run.LoadRows, $run.LoadRowsExpected, (Format-Number $run.IntervalMedianSeconds 3), (Format-Number $run.LoadIntervalMaxSeconds 3), $run.MonitorCpuSeconds, $run.InvalidReason, $run.Profile, (Format-Number $run.LoadIntervalMedianSeconds 3), $run.MonitorExit))
}
$lines.Add('')
$invalidPairs = @($pairRows | Where-Object { -not $_.Valid })
$lines.Add(('Invalid pairs (kept in pairs.csv, left out of the statistics): {0}' -f $(if ($invalidPairs.Count -eq 0) { 'none' } else { ($invalidPairs | ForEach-Object { "$($_.Profile) $($_.Scenario) pair $($_.Pair)" }) -join ', ' })))
$lines.Add('')
foreach ($look in $looks) {
    $lines.Add("## Resources and latency, $($look.Name) (paired differences: runtime - plain)")
    $lines.Add('')
    $lines.Add('CPU metrics are not compared in the Ram profile (0.2 s WMI sampling adds observer overhead).')
    $lines.Add('')
    $lines.Add('| Profile | Scenario | Metric | Role | Valid / in look | Metric-excluded | Zero diffs | Plain median | Runtime median | Diff median | Diff min..max | CI of median diff | p (Holm) | Verdict |')
    $lines.Add('|---|---|---|---|---|---|---|---|---|---|---|---|---|---|')
    foreach ($row in @($looks | Where-Object { $_.Name -eq $look.Name } | ForEach-Object { $_.Rows })) {
        $ci = if ($null -ne $row.CiLow) { '{0}..{1} (>= {2}%)' -f (Format-Number $row.CiLow), (Format-Number $row.CiHigh), ([Math]::Floor($row.CiCoverageMin * 1000) / 10).ToString('0.#', $culture) } elseif ($row.ValidPairs -gt 0) { "too few pairs for $(([double]$row.CiLevel * 100).ToString('0.#', $culture))%" } else { '' }
        $pText = if ($null -ne $row.P) { '{0} ({1})' -f (Format-Number $row.P 4), (Format-Number $row.PHolm 4) } else { '' }
        $lines.Add(('| {0} | {1} | {2} | {3} | {4} / {5} | {6} | {7} | {8} | {9} | {10} | {11}..{12} | {13} | {14} | {15} |' -f $row.Profile, $row.Scenario, $row.Metric, $row.Role, $row.ValidPairs, $row.PairsInLook, $row.MetricExcludedPairs, $row.ZeroDiffs,
                (Format-Number $row.PlainMedian), (Format-Number $row.RuntimeMedian), (Format-Number $row.DiffMedian), (Format-Number $row.DiffMin), (Format-Number $row.DiffMax), $ci, $pText, $row.Verdict))
    }
    $lines.Add('')
}
$lines | Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.md') -Encoding UTF8
Write-Host "Wrote runs.csv, pairs.csv, summary.csv and summary.md to $OutputDirectory"
) { $reportFilesByName[$reportBase] = $reportFile }
    }
    $runNames = New-Object System.Collections.Generic.List[string]
    foreach ($candidateName in (@($scheduled) + @($logOrder) + @($reportFilesByName.Keys))) {
        if ([string]::IsNullOrWhiteSpace([string]$candidateName) -or [string]$candidateName -notmatch '^(S[1-4])-pair(\d+)-(plain|runtime)
        $row = [ordered]@{
            Profile = $monitorProfile; Scenario = $scenario; Pair = $pair; Build = $build; Directory = Split-Path -Leaf $directory
            Valid = $false; InvalidReason = ''
            Passed = $false; Error = ''
            ExitCode = $(if ($null -ne $log) { $log.exitCode } else { $null })
            TimedOut = $(if ($null -ne $log) { $log.timedOut } else { $null })
            Rounds = $null; PassedRounds = $null; Overruns = $null
            RequestsReceived = $null; OperationsExecuted = $null; CoalescedRequests = $null; CacheHits = $null; FailedRequests = $null
            RequestsPerSecond = $null; RoundMsP50 = $null; RoundMsP95 = $null
            MonitorExit = $(if ($null -ne $log -and $log.PSObject.Properties['monitorExit']) { $log.monitorExit } else { $null })
            MonitorRows = 0; LoadRows = 0; LoadRowsExpected = $null
            LoadRowsWithMissingPrivate = $null; LoadRowsWithUnreadableCpu = $null; LoadRowsWithMissingWorkingSet = $null
            LoadRowsWithInvalidInterval = $null; LoadProcessCountMax = $null
            PrivateMetricsValid = $false; CpuMetricsValid = $false; WorkingSetMetricsValid = $false; DiagnosticsPrivateMetricsValid = $false
            IdleBeforePrivateMetricsValid = $false; IdleAfterPrivateMetricsValid = $false; IdleBeforeCpuMetricsValid = $false
            IntervalMedianSeconds = $null; IntervalMaxSeconds = $null; LoadIntervalMedianSeconds = $null; LoadIntervalMaxSeconds = $null
            MonitorCpuSeconds = $(if ($null -ne $log -and $log.PSObject.Properties['monitorCpuSeconds']) { $log.monitorCpuSeconds } else { $null })
        }
        foreach ($metric in $resourceMetrics) { $row[$metric] = $null }
        $seen[$base] = $true

        foreach ($reason in @(Get-LogReasons $log)) { $reasons.Add($reason) }
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
                        Timestamp  = [string]$_.Timestamp
                        Time       = Get-Time $_.Timestamp
                        RootPid    = [int]$_.RootPid
                        Processes  = [int]$_.ProcessCount
                        WorkingSet = ConvertTo-Number $_.WorkingSetMB
                        Private    = ConvertTo-Number $_.PrivateBytesMB
                        CpuDelta   = ConvertTo-Number $_.CpuDeltaSeconds
                        Sample     = [int]$_.Sample
                        Interval   = ConvertTo-Number $_.IntervalSeconds
                        PrivateMissing = ConvertTo-Number $_.PrivateMissingCount
                        CpuUnreadable  = ConvertTo-Number $_.CpuUnreadableCount
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
            # The cadence is checked inside the load phase itself; the whole-run median is only context.
            $row.LoadRowsWithInvalidInterval = @($load | Where-Object { $_.Sample -eq 0 -or $null -eq $_.Interval -or $_.Interval -le 0 }).Count
            $loadIntervals = @($load | Where-Object { $_.Sample -gt 0 -and $null -ne $_.Interval -and $_.Interval -gt 0 } | ForEach-Object { $_.Interval })
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
            $row.LoadRowsWithMissingPrivate = @($load | Where-Object { $null -eq $_.Private -or $null -eq $_.PrivateMissing -or $_.PrivateMissing -gt 0 }).Count
            $row.LoadRowsWithUnreadableCpu = @($load | Where-Object { $null -eq $_.CpuDelta -or $null -eq $_.CpuUnreadable -or $_.CpuUnreadable -gt 0 }).Count
            $row.LoadRowsWithMissingWorkingSet = @($load | Where-Object { $null -eq $_.WorkingSet }).Count
            $row.LoadProcessCountMax = Get-Max @($load | ForEach-Object { [double]$_.Processes })
            $row.PrivateMetricsValid = $load.Count -gt 0 -and $row.LoadRowsWithMissingPrivate -eq 0
            $row.CpuMetricsValid = $load.Count -gt 0 -and $row.LoadRowsWithUnreadableCpu -eq 0
            $row.WorkingSetMetricsValid = $load.Count -gt 0 -and $row.LoadRowsWithMissingWorkingSet -eq 0
            $row.IdleBeforePrivateMetricsValid = $idleBefore.Count -gt 0 -and @($idleBefore | Where-Object { $null -eq $_.Private -or $null -eq $_.PrivateMissing -or $_.PrivateMissing -gt 0 }).Count -eq 0
            $row.IdleAfterPrivateMetricsValid = $idleAfter.Count -gt 0 -and @($idleAfter | Where-Object { $null -eq $_.Private -or $null -eq $_.PrivateMissing -or $_.PrivateMissing -gt 0 }).Count -eq 0
            $idleBeforeCpuRows = @($idleBefore | Where-Object { $_.Sample -gt 0 })
            $row.IdleBeforeCpuMetricsValid = $idleBeforeCpuRows.Count -gt 0 -and @($idleBeforeCpuRows | Where-Object { $null -eq $_.CpuDelta -or $null -eq $_.CpuUnreadable -or $_.CpuUnreadable -gt 0 }).Count -eq 0

            # A secondary metric with incomplete samples is not averaged over only the readable rows.
            if (-not $row.PrivateMetricsValid) { $row.LoadPrivateMBAvg = $null; $row.LoadPrivateMBMaxSample = $null }
            if (-not $row.WorkingSetMetricsValid) { $row.LoadWorkingSetMBAvg = $null; $row.LoadWorkingSetMBMaxSample = $null }
            if (-not $row.CpuMetricsValid) { $row.LoadCpuSeconds = $null }
            if (-not $row.IdleBeforePrivateMetricsValid) { $row.IdleBeforePrivateMB = $null }
            if (-not $row.IdleAfterPrivateMetricsValid) { $row.IdleAfterPrivateMB = $null }
            if (-not $row.IdleBeforeCpuMetricsValid) { $row.IdleBeforeCpuSeconds = $null }

            if ($row.LoadRowsExpected -gt 0 -and $row.LoadRows -lt $minLoadCoverage * $row.LoadRowsExpected) { $reasons.Add("load rows $($row.LoadRows) < $([int]($minLoadCoverage * 100))% of $($row.LoadRowsExpected)") }
            # Private memory is primary only in the Ram profile; an incomplete secondary private-memory metric
            # does not discard otherwise valid CPU observations in the Cpu profile.
            if ($monitorProfile -eq 'Ram' -and -not $row.PrivateMetricsValid) { $reasons.Add("$($row.LoadRowsWithMissingPrivate) load rows with missing or non-finite private memory") }
            # CPU is compared only in the Cpu profile, so unreadable CPU invalidates only those runs.
            if ($monitorProfile -eq 'Cpu' -and -not $row.CpuMetricsValid) { $reasons.Add("$($row.LoadRowsWithUnreadableCpu) load rows with missing or non-finite CPU") }
            if ($row.LoadRowsWithInvalidInterval -gt 0) { $reasons.Add("$($row.LoadRowsWithInvalidInterval) load rows with a missing, non-finite or non-positive interval") }
            if ($null -eq $row.LoadIntervalMedianSeconds -or [Math]::Abs($row.LoadIntervalMedianSeconds - $nominalInterval) -gt $maxIntervalDeviation * $nominalInterval) {
                $reasons.Add("load interval median $(Format-Number $row.LoadIntervalMedianSeconds 3) s not within $([int]($maxIntervalDeviation * 100))% of $nominalInterval s")
            }
            if ($null -ne $row.LoadIntervalMaxSeconds -and $row.LoadIntervalMaxSeconds -gt $maxIntervalFactor * $nominalInterval) {
                $reasons.Add("load gap $(Format-Number $row.LoadIntervalMaxSeconds 3) s > $maxIntervalFactor x $nominalInterval s")
            }

            $diagnosticsFile = Join-Path $runsDirectory "$base.monitor.diagnostics.csv"
            if ((Test-Path -LiteralPath $diagnosticsFile) -and $samples.Count -gt 0) {
                $rootPid = $samples[0].RootPid
                $diagnosticLoadRows = @(Import-Csv -LiteralPath $diagnosticsFile | Where-Object { $_.InTree -eq 'True' } | Where-Object {
                        $time = Get-Time $_.Timestamp; $time -ge $loadFrom -and $time -lt $loadTo
                    })
                $row.DiagnosticsPrivateMetricsValid = $load.Count -gt 0 -and $diagnosticLoadRows.Count -gt 0
                if ($row.DiagnosticsPrivateMetricsValid) {
                    foreach ($sample in $load) {
                        $atSample = @($diagnosticLoadRows | Where-Object { $_.Timestamp -eq $sample.Timestamp })
                        $atSampleBytes = @($atSample | ForEach-Object { ConvertTo-Number $_.CimPrivatePageCount })
                        if ($atSample.Count -ne $sample.Processes -or $atSampleBytes.Count -ne $atSample.Count -or @($atSampleBytes | Where-Object { $null -eq $_ }).Count -gt 0) {
                            $row.DiagnosticsPrivateMetricsValid = $false
                            break
                        }
                    }
                }
                $rootRows = @($diagnosticLoadRows | Where-Object { [int]$_.Pid -eq $rootPid })
                $rootValues = @($rootRows | ForEach-Object { ConvertTo-Number $_.CimPrivatePageCount })
                if ($rootRows.Count -ne $load.Count -or $rootValues.Count -ne $rootRows.Count -or @($rootValues | Where-Object { $null -eq $_ }).Count -gt 0) {
                    $row.DiagnosticsPrivateMetricsValid = $false
                }
                if ($row.DiagnosticsPrivateMetricsValid) {
                    $row.ExePrivateMBLoadAvg = Get-Average @($rootValues | ForEach-Object { $_ / 1MB })
                    if ($row.PrivateMetricsValid -and $null -ne $row.LoadPrivateMBAvg) {
                        $row.WebViewPrivateMBLoadAvg = $row.LoadPrivateMBAvg - $row.ExePrivateMBLoadAvg
                    }
                }
                else {
                    $row.ExePrivateMBLoadAvg = $null
                    $row.WebViewPrivateMBLoadAvg = $null
                }
            }
        }
        else {
            $reasons.Add('monitor CSV missing')
        }
        $primaryMetric = $primaryByProfile[$monitorProfile]
        if ($null -eq $row[$primaryMetric]) { $reasons.Add("$primaryMetric missing") }
        $row.Valid = $reasons.Count -eq 0
        $row.InvalidReason = $reasons -join '; '
        $runs.Add([pscustomobject]$row)
    }

    # A scheduled or logged launch without a JSON report stays in the data as an invalid run,
    # so a crash or timeout cannot drop a pair from the family.
    $expectedNames = @(@($scheduled) + @($logOrder) | Where-Object { $_ -match '^S[1-4]-pair\d+-(plain|runtime)$' } | Sort-Object -Unique)
    foreach ($name in $expectedNames) {
        if ($seen.ContainsKey($name)) { continue }
        $null = $name -match '^(S[1-4])-pair(\d+)-(plain|runtime)$'
        $log = $logByRun[$name]
        $reasons = New-Object System.Collections.Generic.List[string]
        $reasons.Add('JSON report missing')
        foreach ($reason in @(Get-LogReasons $log)) { $reasons.Add($reason) }
        $row = [ordered]@{
            Profile = $monitorProfile; Scenario = $Matches[1]; Pair = [int]$Matches[2]; Build = $Matches[3]; Directory = Split-Path -Leaf $directory
            Valid = $false; InvalidReason = $reasons -join '; '
            Passed = $false; Error = 'JSON report missing'
            ExitCode = $(if ($null -ne $log) { $log.exitCode } else { $null })
            TimedOut = $(if ($null -ne $log) { $log.timedOut } else { $null })
            Rounds = $null; PassedRounds = $null; Overruns = $null
            RequestsReceived = $null; OperationsExecuted = $null; CoalescedRequests = $null; CacheHits = $null; FailedRequests = $null
            RequestsPerSecond = $null; RoundMsP50 = $null; RoundMsP95 = $null
            MonitorExit = $(if ($null -ne $log -and $log.PSObject.Properties['monitorExit']) { $log.monitorExit } else { $null })
            MonitorRows = 0; LoadRows = 0; LoadRowsExpected = $null
            LoadRowsWithMissingPrivate = $null; LoadRowsWithUnreadableCpu = $null; LoadRowsWithMissingWorkingSet = $null
            LoadRowsWithInvalidInterval = $null; LoadProcessCountMax = $null
            PrivateMetricsValid = $false; CpuMetricsValid = $false; WorkingSetMetricsValid = $false; DiagnosticsPrivateMetricsValid = $false
            IdleBeforePrivateMetricsValid = $false; IdleAfterPrivateMetricsValid = $false; IdleBeforeCpuMetricsValid = $false
            IntervalMedianSeconds = $null; IntervalMaxSeconds = $null; LoadIntervalMedianSeconds = $null; LoadIntervalMaxSeconds = $null
            MonitorCpuSeconds = $(if ($null -ne $log -and $log.PSObject.Properties['monitorCpuSeconds']) { $log.monitorCpuSeconds } else { $null })
        }
        $row.PrivateMetricsValid = $false; $row.CpuMetricsValid = $false; $row.WorkingSetMetricsValid = $false; $row.DiagnosticsPrivateMetricsValid = $false
        $row.IdleBeforePrivateMetricsValid = $false; $row.IdleAfterPrivateMetricsValid = $false; $row.IdleBeforeCpuMetricsValid = $false
        foreach ($metric in $resourceMetrics) { $row[$metric] = $null }
        $runs.Add([pscustomobject]$row)
    }
}

if ($runs.Count -eq 0) { throw "No run reports found in $(($sources | ForEach-Object { $_.Directory }) -join ', ')" }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

$numberColumns = @($resourceMetrics + $performanceMetrics)
$formattedColumns = @($numberColumns + @('IntervalMedianSeconds', 'IntervalMaxSeconds', 'LoadIntervalMedianSeconds', 'LoadIntervalMaxSeconds'))
$runs | ForEach-Object {
    $out = [ordered]@{}
    foreach ($property in $_.PSObject.Properties) {
        if ($formattedColumns -contains $property.Name) { $out[$property.Name] = Format-Raw $property.Value }
        else { $out[$property.Name] = $property.Value }
    }
    [pscustomobject]$out
} | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'runs.csv') -NoTypeInformation -Encoding UTF8

# Paired differences; a pair is valid only if both of its runs are.
$pairRows = New-Object System.Collections.Generic.List[object]
foreach ($group in @($runs | Group-Object Profile, Scenario, Pair | Sort-Object { $_.Group[0].Profile }, { $_.Group[0].Scenario }, { $_.Group[0].Pair })) {
    $plain = @($group.Group | Where-Object { $_.Build -eq 'plain' })
    $runtime = @($group.Group | Where-Object { $_.Build -eq 'runtime' })
    $reasons = New-Object System.Collections.Generic.List[string]
    if ($plain.Count -ne 1) { $reasons.Add("plain runs: $($plain.Count)") }
    if ($runtime.Count -ne 1) { $reasons.Add("runtime runs: $($runtime.Count)") }
    foreach ($run in @($plain + $runtime)) { if (-not $run.Valid) { $reasons.Add("$($run.Build): $($run.InvalidReason)") } }
    $first = $group.Group[0]
    $pairRow = [ordered]@{ Profile = $first.Profile; Scenario = $first.Scenario; Pair = $first.Pair; Valid = $reasons.Count -eq 0; InvalidReason = $reasons -join '; ' }
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
    $out = [ordered]@{ Profile = $_.Profile; Scenario = $_.Scenario; Pair = $_.Pair; Valid = $_.Valid; InvalidReason = $_.InvalidReason }
    foreach ($metric in $numberColumns) {
        $out["Plain$metric"] = Format-Raw $_."Plain$metric"; $out["Runtime$metric"] = Format-Raw $_."Runtime$metric"; $out[$metric] = Format-Raw $_.$metric
    }
    [pscustomobject]$out
} | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'pairs.csv') -NoTypeInformation -Encoding UTF8

function Invoke-Analysis {
    # One look: per profile, scenario and metric, statistics over the valid pairs with Pair <= MaxPair.
    param([int]$MaxPair, [double]$Alpha, [string[]]$TestedKeys)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($cell in $cells) {
        $monitorProfile = $cell.Profile; $scenario = $cell.Scenario
        $inLook = @($pairRows | Where-Object { $_.Profile -eq $monitorProfile -and $_.Scenario -eq $scenario -and $_.Pair -le $MaxPair })
        $valid = @($inLook | Where-Object { $_.Valid })
        foreach ($metric in $comparedByProfile[$monitorProfile]) {
            $usable = @($valid | Where-Object { $null -ne $_.$metric })
            $diffs = [double[]]@($usable | ForEach-Object { [double]$_.$metric })
            $plainValues = [double[]]@($usable | ForEach-Object { [double]$_."Plain$metric" })
            $runtimeValues = [double[]]@($usable | ForEach-Object { [double]$_."Runtime$metric" })
            $key = "$monitorProfile/$scenario/$metric"
            $primary = $primaryByProfile[$monitorProfile] -eq $metric
            $row = [pscustomobject][ordered]@{
                Profile = $monitorProfile; Scenario = $scenario; Metric = $metric
                Role = $(if ($primary) { 'primary' } else { 'secondary' })
                PairsInLook = $inLook.Count; ValidPairs = $diffs.Count; InvalidPairs = $inLook.Count - $valid.Count
                MetricExcludedPairs = $valid.Count - $usable.Count
                ZeroDiffs = [SymmetricBenchStats]::CountZeros($diffs)
                PlainMedian = Get-Median $plainValues; RuntimeMedian = Get-Median $runtimeValues
                DiffMedian = Get-Median $diffs
                DiffMin = $(if ($diffs.Count -gt 0) { ($diffs | Measure-Object -Minimum).Minimum } else { $null })
                DiffMax = $(if ($diffs.Count -gt 0) { ($diffs | Measure-Object -Maximum).Maximum } else { $null })
                CiLevel = 1 - $Alpha; CiLow = $null; CiHigh = $null; CiCoverageMin = $null
                P = $null; PHolm = $null; Decided = $false; Verdict = ''
            }
            if ($diffs.Count -ge 1) {
                $interval = [SymmetricBenchStats]::MedianInterval($diffs, 1 - $Alpha)
                if ($null -ne $interval) { $row.CiLow = $interval[0]; $row.CiHigh = $interval[1]; $row.CiCoverageMin = $interval[2] }
            }
            if ($primary -and $TestedKeys -contains $key -and $diffs.Count -ge $minValidPairsPerLook) {
                $row.P = [SymmetricBenchStats]::SignTestP($diffs)
            }
            $rows.Add($row)
        }
    }
    # Holm over every hypothesis tested in this look. One without a p-value (too few valid
    # pairs) stays in the family with p = 1, so failed runs never weaken the correction.
    $tested = @($rows | Where-Object { $_.Role -eq 'primary' -and $TestedKeys -contains "$($_.Profile)/$($_.Scenario)/$($_.Metric)" } |
        ForEach-Object { [pscustomobject]@{ Row = $_; P = $(if ($null -eq $_.P) { 1.0 } else { [double]$_.P }) } } | Sort-Object P)
    if ($tested.Count -ne $TestedKeys.Count) { throw "Holm family has $($tested.Count) rows for $($TestedKeys.Count) hypotheses." }
    $running = 0.0
    for ($k = 0; $k -lt $tested.Count; $k++) {
        $adjusted = [Math]::Min(1.0, ($tested.Count - $k) * $tested[$k].P)
        if ($adjusted -lt $running) { $adjusted = $running }
        $running = $adjusted
        $tested[$k].Row.PHolm = $adjusted
    }
    foreach ($row in $rows) {
        if ($row.ValidPairs -eq 0) { $row.Verdict = 'no valid data'; continue }
        if ($row.Role -ne 'primary') { $row.Verdict = 'secondary: descriptive'; continue }
        if ($TestedKeys -notcontains "$($row.Profile)/$($row.Scenario)/$($row.Metric)") { continue }
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

# Cells analysed: the declared family (Cpu and Ram x S1-S4) for confirmatory results, whatever
# data exists; the cells present in the data for a pilot.
$cells = if ($phase -eq 'Confirmatory') {
    @(foreach ($profileName in @('Cpu', 'Ram')) { foreach ($scenario in $familyScenarios) { [pscustomobject]@{ Profile = $profileName; Scenario = $scenario } } })
}
else { @($pairRows | Select-Object Profile, Scenario -Unique | Sort-Object Profile, Scenario) }
$allPrimaryKeys = @($cells | ForEach-Object { "$($_.Profile)/$($_.Scenario)/$($primaryByProfile[$_.Profile])" })
$hasExtension = @($sources | Where-Object { $_.Look -eq 2 }).Count -gt 0
$looks = New-Object System.Collections.Generic.List[object]
if ($phase -eq 'Pilot') {
    $rows = Invoke-Analysis -MaxPair ([int]::MaxValue) -Alpha 0.05 -TestedKeys @()
    foreach ($row in $rows) { if ($row.Role -eq 'primary' -and $row.ValidPairs -gt 0) { $row.Verdict = 'pilot: no conclusion' } }
    $looks.Add([pscustomobject]@{ Name = 'pilot'; Rows = $rows })
}
else {
    $look1 = Invoke-Analysis -MaxPair $plannedPairsPerLook -Alpha $lookAlpha -TestedKeys $allPrimaryKeys
    $undecided = @($look1 | Where-Object { $_.Role -eq 'primary' -and -not $_.Decided } | ForEach-Object { "$($_.Profile)/$($_.Scenario)/$($_.Metric)" })
    foreach ($row in $look1) {
        if ($row.Role -eq 'primary' -and -not $row.Decided) {
            $note = $(if ($hasExtension) { 'undecided, tested again at look 2' } else { 'undecided: extend to 20 pairs' })
            $row.Verdict = $(if ($row.Verdict) { "$($row.Verdict); $note" } else { $note })
        }
    }
    $looks.Add([pscustomobject]@{ Name = 'look1'; Rows = $look1 })
    if ($hasExtension) {
        # Fail closed: every undecided hypothesis needs its own planned pairs 11-20, and the
        # extension holds exactly the undecided scenarios, so look 1 data is never re-tested as look 2.
        foreach ($profileName in @('Cpu', 'Ram')) {
            $required = @($undecided | Where-Object { $_.Split('/')[0] -eq $profileName } | ForEach-Object { $_.Split('/')[1] } | Sort-Object -Unique)
            $extensionSource = @($sources | Where-Object { $_.Look -eq 2 -and [string]$_.Configuration.profile -eq $profileName })
            $configured = if ($extensionSource.Count -eq 1) { @($extensionSource[0].Configuration.scenarios | ForEach-Object { [string]$_ } | Sort-Object -Unique) } else { @() }
            if (($required -join ',') -ne ($configured -join ',')) {
                throw "Profile ${profileName}: the extension must hold exactly the scenarios undecided at look 1 [$($required -join ', ')], got [$($configured -join ', ')]."
            }
            foreach ($scenario in $required) {
                for ($pairNumber = $plannedPairsPerLook + 1; $pairNumber -le 2 * $plannedPairsPerLook; $pairNumber++) {
                    $found = @($pairRows | Where-Object { $_.Profile -eq $profileName -and $_.Scenario -eq $scenario -and $_.Pair -eq $pairNumber }).Count
                    if ($found -ne 1) { throw "Profile $profileName ${scenario}: planned pair $pairNumber appears $found times; look 2 needs each of pairs $($plannedPairsPerLook + 1)..$(2 * $plannedPairsPerLook) once." }
                }
            }
        }
        $look2 = Invoke-Analysis -MaxPair (2 * $plannedPairsPerLook) -Alpha $lookAlpha -TestedKeys $undecided
        foreach ($row in $look2) {
            if ($row.Role -ne 'primary') { continue }
            if ($undecided -notcontains "$($row.Profile)/$($row.Scenario)/$($row.Metric)") { $row.Verdict = 'decided at look 1'; continue }
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
            if (@('P', 'PHolm', 'PlainMedian', 'RuntimeMedian', 'DiffMedian', 'DiffMin', 'DiffMax', 'CiLevel', 'CiLow', 'CiHigh', 'CiCoverageMin') -contains $property.Name) {
                $out[$property.Name] = Format-Raw $property.Value
            }
            else { $out[$property.Name] = $property.Value }
        }
        $summaryRows.Add([pscustomobject]$out)
    }
}
$summaryRows | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'summary.csv') -NoTypeInformation -Encoding UTF8

# Markdown: protocol notes, correctness, validity, then resources.
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add(('Phase: {0}. Commit {1}. {2}. Analysis: {3}.' -f $phase, $firstConfiguration.gitHead, $firstConfiguration.os, (Split-Path -Leaf $OutputDirectory)))
$lines.Add('')
foreach ($source in $sources) {
    $lines.Add(('- {0}: profile {1}, nominal monitor interval {2} s, look {3}' -f (Split-Path -Leaf $source.Directory), $source.Configuration.profile, $source.Configuration.sampleIntervalSeconds, $source.Look))
}
$lines.Add('')
$lines.Add('Estimand: median paired difference (runtime - plain) over valid pairs. Primary family: LoadCpuSeconds (Cpu profile) and LoadPrivateMBAvg (Ram profile) per scenario, Holm over all of them. MaxSample columns are the largest sampled value, not a guaranteed true peak. CI coverage is a guaranteed minimum (exact only without ties).')
$lines.Add('')
if ($deviations.Count -gt 0) {
    $lines.Add('## Protocol deviations')
    $lines.Add('')
    foreach ($deviation in $deviations) { $lines.Add("- $deviation") }
    $lines.Add('')
}
$lines.Add('## Correctness (counters per run)')
$lines.Add('')
$lines.Add('| Profile | Scenario | Pair | Build | Passed | Rounds passed | Overruns | Received | Executed | Coalesced | Cache hits | Failed | Note |')
$lines.Add('|---|---|---|---|---|---|---|---|---|---|---|---|---|')
foreach ($run in @($runs | Sort-Object Profile, Scenario, Pair, Build)) {
    $lines.Add(('| {13} | {0} | {1} | {2} | {3} | {4}/{5} | {6} | {7} | {8} | {9} | {10} | {11} | {12} |' -f $run.Scenario, $run.Pair, $run.Build, $run.Passed, $run.PassedRounds, $run.Rounds, $run.Overruns, $run.RequestsReceived, $run.OperationsExecuted, $run.CoalescedRequests, $run.CacheHits, $run.FailedRequests, $run.Error, $run.Profile))
}
$lines.Add('')
$lines.Add('## Run validity and monitoring')
$lines.Add('')
$lines.Add('| Run | Valid | Load rows / expected | Interval median: run / load; load max (s) | Monitor exit / CPU s | Reason |')
$lines.Add('|---|---|---|---|---|---|')
foreach ($run in @($runs | Sort-Object Profile, Scenario, Pair, Build)) {
    $lines.Add(('| {10} {0}-{1}-{2} | {3} | {4} / {5} | {6} / {11}; {7} | {12} / {8} | {9} |' -f $run.Scenario, $run.Pair, $run.Build, $run.Valid, $run.LoadRows, $run.LoadRowsExpected, (Format-Number $run.IntervalMedianSeconds 3), (Format-Number $run.LoadIntervalMaxSeconds 3), $run.MonitorCpuSeconds, $run.InvalidReason, $run.Profile, (Format-Number $run.LoadIntervalMedianSeconds 3), $run.MonitorExit))
}
$lines.Add('')
$invalidPairs = @($pairRows | Where-Object { -not $_.Valid })
$lines.Add(('Invalid pairs (kept in pairs.csv, left out of the statistics): {0}' -f $(if ($invalidPairs.Count -eq 0) { 'none' } else { ($invalidPairs | ForEach-Object { "$($_.Profile) $($_.Scenario) pair $($_.Pair)" }) -join ', ' })))
$lines.Add('')
foreach ($look in $looks) {
    $lines.Add("## Resources and latency, $($look.Name) (paired differences: runtime - plain)")
    $lines.Add('')
    $lines.Add('CPU metrics are not compared in the Ram profile (0.2 s WMI sampling adds observer overhead).')
    $lines.Add('')
    $lines.Add('| Profile | Scenario | Metric | Role | Valid / in look | Metric-excluded | Zero diffs | Plain median | Runtime median | Diff median | Diff min..max | CI of median diff | p (Holm) | Verdict |')
    $lines.Add('|---|---|---|---|---|---|---|---|---|---|---|---|---|---|')
    foreach ($row in @($looks | Where-Object { $_.Name -eq $look.Name } | ForEach-Object { $_.Rows })) {
        $ci = if ($null -ne $row.CiLow) { '{0}..{1} (>= {2}%)' -f (Format-Number $row.CiLow), (Format-Number $row.CiHigh), ([Math]::Floor($row.CiCoverageMin * 1000) / 10).ToString('0.#', $culture) } elseif ($row.ValidPairs -gt 0) { "too few pairs for $(([double]$row.CiLevel * 100).ToString('0.#', $culture))%" } else { '' }
        $pText = if ($null -ne $row.P) { '{0} ({1})' -f (Format-Number $row.P 4), (Format-Number $row.PHolm 4) } else { '' }
        $lines.Add(('| {0} | {1} | {2} | {3} | {4} / {5} | {6} | {7} | {8} | {9} | {10} | {11}..{12} | {13} | {14} | {15} |' -f $row.Profile, $row.Scenario, $row.Metric, $row.Role, $row.ValidPairs, $row.PairsInLook, $row.MetricExcludedPairs, $row.ZeroDiffs,
                (Format-Number $row.PlainMedian), (Format-Number $row.RuntimeMedian), (Format-Number $row.DiffMedian), (Format-Number $row.DiffMin), (Format-Number $row.DiffMax), $ci, $pText, $row.Verdict))
    }
    $lines.Add('')
}
$lines | Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.md') -Encoding UTF8
Write-Host "Wrote runs.csv, pairs.csv, summary.csv and summary.md to $OutputDirectory"
) { continue }
        if (-not $runNames.Contains([string]$candidateName)) { $runNames.Add([string]$candidateName) }
    }
    $seen = @{}
    foreach ($base in $runNames) {
        if ($base -notmatch '^(S[1-4])-pair(\d+)-(plain|runtime)
        $row = [ordered]@{
            Profile = $monitorProfile; Scenario = $scenario; Pair = $pair; Build = $build; Directory = Split-Path -Leaf $directory
            Valid = $false; InvalidReason = ''
            Passed = $false; Error = ''
            ExitCode = $(if ($null -ne $log) { $log.exitCode } else { $null })
            TimedOut = $(if ($null -ne $log) { $log.timedOut } else { $null })
            Rounds = $null; PassedRounds = $null; Overruns = $null
            RequestsReceived = $null; OperationsExecuted = $null; CoalescedRequests = $null; CacheHits = $null; FailedRequests = $null
            RequestsPerSecond = $null; RoundMsP50 = $null; RoundMsP95 = $null
            MonitorExit = $(if ($null -ne $log -and $log.PSObject.Properties['monitorExit']) { $log.monitorExit } else { $null })
            MonitorRows = 0; LoadRows = 0; LoadRowsExpected = $null
            LoadRowsWithMissingPrivate = $null; LoadRowsWithUnreadableCpu = $null; LoadRowsWithMissingWorkingSet = $null
            LoadRowsWithInvalidInterval = $null; LoadProcessCountMax = $null
            PrivateMetricsValid = $false; CpuMetricsValid = $false; WorkingSetMetricsValid = $false; DiagnosticsPrivateMetricsValid = $false
            IdleBeforePrivateMetricsValid = $false; IdleAfterPrivateMetricsValid = $false; IdleBeforeCpuMetricsValid = $false
            IntervalMedianSeconds = $null; IntervalMaxSeconds = $null; LoadIntervalMedianSeconds = $null; LoadIntervalMaxSeconds = $null
            MonitorCpuSeconds = $(if ($null -ne $log -and $log.PSObject.Properties['monitorCpuSeconds']) { $log.monitorCpuSeconds } else { $null })
        }
        foreach ($metric in $resourceMetrics) { $row[$metric] = $null }
        $seen[$base] = $true

        foreach ($reason in @(Get-LogReasons $log)) { $reasons.Add($reason) }
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
                        Timestamp  = [string]$_.Timestamp
                        Time       = Get-Time $_.Timestamp
                        RootPid    = [int]$_.RootPid
                        Processes  = [int]$_.ProcessCount
                        WorkingSet = ConvertTo-Number $_.WorkingSetMB
                        Private    = ConvertTo-Number $_.PrivateBytesMB
                        CpuDelta   = ConvertTo-Number $_.CpuDeltaSeconds
                        Sample     = [int]$_.Sample
                        Interval   = ConvertTo-Number $_.IntervalSeconds
                        PrivateMissing = ConvertTo-Number $_.PrivateMissingCount
                        CpuUnreadable  = ConvertTo-Number $_.CpuUnreadableCount
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
            # The cadence is checked inside the load phase itself; the whole-run median is only context.
            $row.LoadRowsWithInvalidInterval = @($load | Where-Object { $_.Sample -eq 0 -or $null -eq $_.Interval -or $_.Interval -le 0 }).Count
            $loadIntervals = @($load | Where-Object { $_.Sample -gt 0 -and $null -ne $_.Interval -and $_.Interval -gt 0 } | ForEach-Object { $_.Interval })
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
            $row.LoadRowsWithMissingPrivate = @($load | Where-Object { $null -eq $_.Private -or $null -eq $_.PrivateMissing -or $_.PrivateMissing -gt 0 }).Count
            $row.LoadRowsWithUnreadableCpu = @($load | Where-Object { $null -eq $_.CpuDelta -or $null -eq $_.CpuUnreadable -or $_.CpuUnreadable -gt 0 }).Count
            $row.LoadRowsWithMissingWorkingSet = @($load | Where-Object { $null -eq $_.WorkingSet }).Count
            $row.LoadProcessCountMax = Get-Max @($load | ForEach-Object { [double]$_.Processes })
            $row.PrivateMetricsValid = $load.Count -gt 0 -and $row.LoadRowsWithMissingPrivate -eq 0
            $row.CpuMetricsValid = $load.Count -gt 0 -and $row.LoadRowsWithUnreadableCpu -eq 0
            $row.WorkingSetMetricsValid = $load.Count -gt 0 -and $row.LoadRowsWithMissingWorkingSet -eq 0
            $row.IdleBeforePrivateMetricsValid = $idleBefore.Count -gt 0 -and @($idleBefore | Where-Object { $null -eq $_.Private -or $null -eq $_.PrivateMissing -or $_.PrivateMissing -gt 0 }).Count -eq 0
            $row.IdleAfterPrivateMetricsValid = $idleAfter.Count -gt 0 -and @($idleAfter | Where-Object { $null -eq $_.Private -or $null -eq $_.PrivateMissing -or $_.PrivateMissing -gt 0 }).Count -eq 0
            $idleBeforeCpuRows = @($idleBefore | Where-Object { $_.Sample -gt 0 })
            $row.IdleBeforeCpuMetricsValid = $idleBeforeCpuRows.Count -gt 0 -and @($idleBeforeCpuRows | Where-Object { $null -eq $_.CpuDelta -or $null -eq $_.CpuUnreadable -or $_.CpuUnreadable -gt 0 }).Count -eq 0

            # A secondary metric with incomplete samples is not averaged over only the readable rows.
            if (-not $row.PrivateMetricsValid) { $row.LoadPrivateMBAvg = $null; $row.LoadPrivateMBMaxSample = $null }
            if (-not $row.WorkingSetMetricsValid) { $row.LoadWorkingSetMBAvg = $null; $row.LoadWorkingSetMBMaxSample = $null }
            if (-not $row.CpuMetricsValid) { $row.LoadCpuSeconds = $null }
            if (-not $row.IdleBeforePrivateMetricsValid) { $row.IdleBeforePrivateMB = $null }
            if (-not $row.IdleAfterPrivateMetricsValid) { $row.IdleAfterPrivateMB = $null }
            if (-not $row.IdleBeforeCpuMetricsValid) { $row.IdleBeforeCpuSeconds = $null }

            if ($row.LoadRowsExpected -gt 0 -and $row.LoadRows -lt $minLoadCoverage * $row.LoadRowsExpected) { $reasons.Add("load rows $($row.LoadRows) < $([int]($minLoadCoverage * 100))% of $($row.LoadRowsExpected)") }
            # Private memory is primary only in the Ram profile; an incomplete secondary private-memory metric
            # does not discard otherwise valid CPU observations in the Cpu profile.
            if ($monitorProfile -eq 'Ram' -and -not $row.PrivateMetricsValid) { $reasons.Add("$($row.LoadRowsWithMissingPrivate) load rows with missing or non-finite private memory") }
            # CPU is compared only in the Cpu profile, so unreadable CPU invalidates only those runs.
            if ($monitorProfile -eq 'Cpu' -and -not $row.CpuMetricsValid) { $reasons.Add("$($row.LoadRowsWithUnreadableCpu) load rows with missing or non-finite CPU") }
            if ($row.LoadRowsWithInvalidInterval -gt 0) { $reasons.Add("$($row.LoadRowsWithInvalidInterval) load rows with a missing, non-finite or non-positive interval") }
            if ($null -eq $row.LoadIntervalMedianSeconds -or [Math]::Abs($row.LoadIntervalMedianSeconds - $nominalInterval) -gt $maxIntervalDeviation * $nominalInterval) {
                $reasons.Add("load interval median $(Format-Number $row.LoadIntervalMedianSeconds 3) s not within $([int]($maxIntervalDeviation * 100))% of $nominalInterval s")
            }
            if ($null -ne $row.LoadIntervalMaxSeconds -and $row.LoadIntervalMaxSeconds -gt $maxIntervalFactor * $nominalInterval) {
                $reasons.Add("load gap $(Format-Number $row.LoadIntervalMaxSeconds 3) s > $maxIntervalFactor x $nominalInterval s")
            }

            $diagnosticsFile = Join-Path $runsDirectory "$base.monitor.diagnostics.csv"
            if ((Test-Path -LiteralPath $diagnosticsFile) -and $samples.Count -gt 0) {
                $rootPid = $samples[0].RootPid
                $diagnosticLoadRows = @(Import-Csv -LiteralPath $diagnosticsFile | Where-Object { $_.InTree -eq 'True' } | Where-Object {
                        $time = Get-Time $_.Timestamp; $time -ge $loadFrom -and $time -lt $loadTo
                    })
                $row.DiagnosticsPrivateMetricsValid = $load.Count -gt 0 -and $diagnosticLoadRows.Count -gt 0
                if ($row.DiagnosticsPrivateMetricsValid) {
                    foreach ($sample in $load) {
                        $atSample = @($diagnosticLoadRows | Where-Object { $_.Timestamp -eq $sample.Timestamp })
                        $atSampleBytes = @($atSample | ForEach-Object { ConvertTo-Number $_.CimPrivatePageCount })
                        if ($atSample.Count -ne $sample.Processes -or $atSampleBytes.Count -ne $atSample.Count -or @($atSampleBytes | Where-Object { $null -eq $_ }).Count -gt 0) {
                            $row.DiagnosticsPrivateMetricsValid = $false
                            break
                        }
                    }
                }
                $rootRows = @($diagnosticLoadRows | Where-Object { [int]$_.Pid -eq $rootPid })
                $rootValues = @($rootRows | ForEach-Object { ConvertTo-Number $_.CimPrivatePageCount })
                if ($rootRows.Count -ne $load.Count -or $rootValues.Count -ne $rootRows.Count -or @($rootValues | Where-Object { $null -eq $_ }).Count -gt 0) {
                    $row.DiagnosticsPrivateMetricsValid = $false
                }
                if ($row.DiagnosticsPrivateMetricsValid) {
                    $row.ExePrivateMBLoadAvg = Get-Average @($rootValues | ForEach-Object { $_ / 1MB })
                    if ($row.PrivateMetricsValid -and $null -ne $row.LoadPrivateMBAvg) {
                        $row.WebViewPrivateMBLoadAvg = $row.LoadPrivateMBAvg - $row.ExePrivateMBLoadAvg
                    }
                }
                else {
                    $row.ExePrivateMBLoadAvg = $null
                    $row.WebViewPrivateMBLoadAvg = $null
                }
            }
        }
        else {
            $reasons.Add('monitor CSV missing')
        }
        $primaryMetric = $primaryByProfile[$monitorProfile]
        if ($null -eq $row[$primaryMetric]) { $reasons.Add("$primaryMetric missing") }
        $row.Valid = $reasons.Count -eq 0
        $row.InvalidReason = $reasons -join '; '
        $runs.Add([pscustomobject]$row)
    }

    # A scheduled or logged launch without a JSON report stays in the data as an invalid run,
    # so a crash or timeout cannot drop a pair from the family.
    $expectedNames = @(@($scheduled) + @($logOrder) | Where-Object { $_ -match '^S[1-4]-pair\d+-(plain|runtime)$' } | Sort-Object -Unique)
    foreach ($name in $expectedNames) {
        if ($seen.ContainsKey($name)) { continue }
        $null = $name -match '^(S[1-4])-pair(\d+)-(plain|runtime)$'
        $log = $logByRun[$name]
        $reasons = New-Object System.Collections.Generic.List[string]
        $reasons.Add('JSON report missing')
        foreach ($reason in @(Get-LogReasons $log)) { $reasons.Add($reason) }
        $row = [ordered]@{
            Profile = $monitorProfile; Scenario = $Matches[1]; Pair = [int]$Matches[2]; Build = $Matches[3]; Directory = Split-Path -Leaf $directory
            Valid = $false; InvalidReason = $reasons -join '; '
            Passed = $false; Error = 'JSON report missing'
            ExitCode = $(if ($null -ne $log) { $log.exitCode } else { $null })
            TimedOut = $(if ($null -ne $log) { $log.timedOut } else { $null })
            Rounds = $null; PassedRounds = $null; Overruns = $null
            RequestsReceived = $null; OperationsExecuted = $null; CoalescedRequests = $null; CacheHits = $null; FailedRequests = $null
            RequestsPerSecond = $null; RoundMsP50 = $null; RoundMsP95 = $null
            MonitorExit = $(if ($null -ne $log -and $log.PSObject.Properties['monitorExit']) { $log.monitorExit } else { $null })
            MonitorRows = 0; LoadRows = 0; LoadRowsExpected = $null
            LoadRowsWithMissingPrivate = $null; LoadRowsWithUnreadableCpu = $null; LoadRowsWithMissingWorkingSet = $null
            LoadRowsWithInvalidInterval = $null; LoadProcessCountMax = $null
            PrivateMetricsValid = $false; CpuMetricsValid = $false; WorkingSetMetricsValid = $false; DiagnosticsPrivateMetricsValid = $false
            IdleBeforePrivateMetricsValid = $false; IdleAfterPrivateMetricsValid = $false; IdleBeforeCpuMetricsValid = $false
            IntervalMedianSeconds = $null; IntervalMaxSeconds = $null; LoadIntervalMedianSeconds = $null; LoadIntervalMaxSeconds = $null
            MonitorCpuSeconds = $(if ($null -ne $log -and $log.PSObject.Properties['monitorCpuSeconds']) { $log.monitorCpuSeconds } else { $null })
        }
        $row.PrivateMetricsValid = $false; $row.CpuMetricsValid = $false; $row.WorkingSetMetricsValid = $false; $row.DiagnosticsPrivateMetricsValid = $false
        $row.IdleBeforePrivateMetricsValid = $false; $row.IdleAfterPrivateMetricsValid = $false; $row.IdleBeforeCpuMetricsValid = $false
        foreach ($metric in $resourceMetrics) { $row[$metric] = $null }
        $runs.Add([pscustomobject]$row)
    }
}

if ($runs.Count -eq 0) { throw "No run reports found in $(($sources | ForEach-Object { $_.Directory }) -join ', ')" }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

$numberColumns = @($resourceMetrics + $performanceMetrics)
$formattedColumns = @($numberColumns + @('IntervalMedianSeconds', 'IntervalMaxSeconds', 'LoadIntervalMedianSeconds', 'LoadIntervalMaxSeconds'))
$runs | ForEach-Object {
    $out = [ordered]@{}
    foreach ($property in $_.PSObject.Properties) {
        if ($formattedColumns -contains $property.Name) { $out[$property.Name] = Format-Raw $property.Value }
        else { $out[$property.Name] = $property.Value }
    }
    [pscustomobject]$out
} | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'runs.csv') -NoTypeInformation -Encoding UTF8

# Paired differences; a pair is valid only if both of its runs are.
$pairRows = New-Object System.Collections.Generic.List[object]
foreach ($group in @($runs | Group-Object Profile, Scenario, Pair | Sort-Object { $_.Group[0].Profile }, { $_.Group[0].Scenario }, { $_.Group[0].Pair })) {
    $plain = @($group.Group | Where-Object { $_.Build -eq 'plain' })
    $runtime = @($group.Group | Where-Object { $_.Build -eq 'runtime' })
    $reasons = New-Object System.Collections.Generic.List[string]
    if ($plain.Count -ne 1) { $reasons.Add("plain runs: $($plain.Count)") }
    if ($runtime.Count -ne 1) { $reasons.Add("runtime runs: $($runtime.Count)") }
    foreach ($run in @($plain + $runtime)) { if (-not $run.Valid) { $reasons.Add("$($run.Build): $($run.InvalidReason)") } }
    $first = $group.Group[0]
    $pairRow = [ordered]@{ Profile = $first.Profile; Scenario = $first.Scenario; Pair = $first.Pair; Valid = $reasons.Count -eq 0; InvalidReason = $reasons -join '; ' }
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
    $out = [ordered]@{ Profile = $_.Profile; Scenario = $_.Scenario; Pair = $_.Pair; Valid = $_.Valid; InvalidReason = $_.InvalidReason }
    foreach ($metric in $numberColumns) {
        $out["Plain$metric"] = Format-Raw $_."Plain$metric"; $out["Runtime$metric"] = Format-Raw $_."Runtime$metric"; $out[$metric] = Format-Raw $_.$metric
    }
    [pscustomobject]$out
} | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'pairs.csv') -NoTypeInformation -Encoding UTF8

function Invoke-Analysis {
    # One look: per profile, scenario and metric, statistics over the valid pairs with Pair <= MaxPair.
    param([int]$MaxPair, [double]$Alpha, [string[]]$TestedKeys)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($cell in $cells) {
        $monitorProfile = $cell.Profile; $scenario = $cell.Scenario
        $inLook = @($pairRows | Where-Object { $_.Profile -eq $monitorProfile -and $_.Scenario -eq $scenario -and $_.Pair -le $MaxPair })
        $valid = @($inLook | Where-Object { $_.Valid })
        foreach ($metric in $comparedByProfile[$monitorProfile]) {
            $usable = @($valid | Where-Object { $null -ne $_.$metric })
            $diffs = [double[]]@($usable | ForEach-Object { [double]$_.$metric })
            $plainValues = [double[]]@($usable | ForEach-Object { [double]$_."Plain$metric" })
            $runtimeValues = [double[]]@($usable | ForEach-Object { [double]$_."Runtime$metric" })
            $key = "$monitorProfile/$scenario/$metric"
            $primary = $primaryByProfile[$monitorProfile] -eq $metric
            $row = [pscustomobject][ordered]@{
                Profile = $monitorProfile; Scenario = $scenario; Metric = $metric
                Role = $(if ($primary) { 'primary' } else { 'secondary' })
                PairsInLook = $inLook.Count; ValidPairs = $diffs.Count; InvalidPairs = $inLook.Count - $valid.Count
                MetricExcludedPairs = $valid.Count - $usable.Count
                ZeroDiffs = [SymmetricBenchStats]::CountZeros($diffs)
                PlainMedian = Get-Median $plainValues; RuntimeMedian = Get-Median $runtimeValues
                DiffMedian = Get-Median $diffs
                DiffMin = $(if ($diffs.Count -gt 0) { ($diffs | Measure-Object -Minimum).Minimum } else { $null })
                DiffMax = $(if ($diffs.Count -gt 0) { ($diffs | Measure-Object -Maximum).Maximum } else { $null })
                CiLevel = 1 - $Alpha; CiLow = $null; CiHigh = $null; CiCoverageMin = $null
                P = $null; PHolm = $null; Decided = $false; Verdict = ''
            }
            if ($diffs.Count -ge 1) {
                $interval = [SymmetricBenchStats]::MedianInterval($diffs, 1 - $Alpha)
                if ($null -ne $interval) { $row.CiLow = $interval[0]; $row.CiHigh = $interval[1]; $row.CiCoverageMin = $interval[2] }
            }
            if ($primary -and $TestedKeys -contains $key -and $diffs.Count -ge $minValidPairsPerLook) {
                $row.P = [SymmetricBenchStats]::SignTestP($diffs)
            }
            $rows.Add($row)
        }
    }
    # Holm over every hypothesis tested in this look. One without a p-value (too few valid
    # pairs) stays in the family with p = 1, so failed runs never weaken the correction.
    $tested = @($rows | Where-Object { $_.Role -eq 'primary' -and $TestedKeys -contains "$($_.Profile)/$($_.Scenario)/$($_.Metric)" } |
        ForEach-Object { [pscustomobject]@{ Row = $_; P = $(if ($null -eq $_.P) { 1.0 } else { [double]$_.P }) } } | Sort-Object P)
    if ($tested.Count -ne $TestedKeys.Count) { throw "Holm family has $($tested.Count) rows for $($TestedKeys.Count) hypotheses." }
    $running = 0.0
    for ($k = 0; $k -lt $tested.Count; $k++) {
        $adjusted = [Math]::Min(1.0, ($tested.Count - $k) * $tested[$k].P)
        if ($adjusted -lt $running) { $adjusted = $running }
        $running = $adjusted
        $tested[$k].Row.PHolm = $adjusted
    }
    foreach ($row in $rows) {
        if ($row.ValidPairs -eq 0) { $row.Verdict = 'no valid data'; continue }
        if ($row.Role -ne 'primary') { $row.Verdict = 'secondary: descriptive'; continue }
        if ($TestedKeys -notcontains "$($row.Profile)/$($row.Scenario)/$($row.Metric)") { continue }
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

# Cells analysed: the declared family (Cpu and Ram x S1-S4) for confirmatory results, whatever
# data exists; the cells present in the data for a pilot.
$cells = if ($phase -eq 'Confirmatory') {
    @(foreach ($profileName in @('Cpu', 'Ram')) { foreach ($scenario in $familyScenarios) { [pscustomobject]@{ Profile = $profileName; Scenario = $scenario } } })
}
else { @($pairRows | Select-Object Profile, Scenario -Unique | Sort-Object Profile, Scenario) }
$allPrimaryKeys = @($cells | ForEach-Object { "$($_.Profile)/$($_.Scenario)/$($primaryByProfile[$_.Profile])" })
$hasExtension = @($sources | Where-Object { $_.Look -eq 2 }).Count -gt 0
$looks = New-Object System.Collections.Generic.List[object]
if ($phase -eq 'Pilot') {
    $rows = Invoke-Analysis -MaxPair ([int]::MaxValue) -Alpha 0.05 -TestedKeys @()
    foreach ($row in $rows) { if ($row.Role -eq 'primary' -and $row.ValidPairs -gt 0) { $row.Verdict = 'pilot: no conclusion' } }
    $looks.Add([pscustomobject]@{ Name = 'pilot'; Rows = $rows })
}
else {
    $look1 = Invoke-Analysis -MaxPair $plannedPairsPerLook -Alpha $lookAlpha -TestedKeys $allPrimaryKeys
    $undecided = @($look1 | Where-Object { $_.Role -eq 'primary' -and -not $_.Decided } | ForEach-Object { "$($_.Profile)/$($_.Scenario)/$($_.Metric)" })
    foreach ($row in $look1) {
        if ($row.Role -eq 'primary' -and -not $row.Decided) {
            $note = $(if ($hasExtension) { 'undecided, tested again at look 2' } else { 'undecided: extend to 20 pairs' })
            $row.Verdict = $(if ($row.Verdict) { "$($row.Verdict); $note" } else { $note })
        }
    }
    $looks.Add([pscustomobject]@{ Name = 'look1'; Rows = $look1 })
    if ($hasExtension) {
        # Fail closed: every undecided hypothesis needs its own planned pairs 11-20, and the
        # extension holds exactly the undecided scenarios, so look 1 data is never re-tested as look 2.
        foreach ($profileName in @('Cpu', 'Ram')) {
            $required = @($undecided | Where-Object { $_.Split('/')[0] -eq $profileName } | ForEach-Object { $_.Split('/')[1] } | Sort-Object -Unique)
            $extensionSource = @($sources | Where-Object { $_.Look -eq 2 -and [string]$_.Configuration.profile -eq $profileName })
            $configured = if ($extensionSource.Count -eq 1) { @($extensionSource[0].Configuration.scenarios | ForEach-Object { [string]$_ } | Sort-Object -Unique) } else { @() }
            if (($required -join ',') -ne ($configured -join ',')) {
                throw "Profile ${profileName}: the extension must hold exactly the scenarios undecided at look 1 [$($required -join ', ')], got [$($configured -join ', ')]."
            }
            foreach ($scenario in $required) {
                for ($pairNumber = $plannedPairsPerLook + 1; $pairNumber -le 2 * $plannedPairsPerLook; $pairNumber++) {
                    $found = @($pairRows | Where-Object { $_.Profile -eq $profileName -and $_.Scenario -eq $scenario -and $_.Pair -eq $pairNumber }).Count
                    if ($found -ne 1) { throw "Profile $profileName ${scenario}: planned pair $pairNumber appears $found times; look 2 needs each of pairs $($plannedPairsPerLook + 1)..$(2 * $plannedPairsPerLook) once." }
                }
            }
        }
        $look2 = Invoke-Analysis -MaxPair (2 * $plannedPairsPerLook) -Alpha $lookAlpha -TestedKeys $undecided
        foreach ($row in $look2) {
            if ($row.Role -ne 'primary') { continue }
            if ($undecided -notcontains "$($row.Profile)/$($row.Scenario)/$($row.Metric)") { $row.Verdict = 'decided at look 1'; continue }
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
            if (@('P', 'PHolm', 'PlainMedian', 'RuntimeMedian', 'DiffMedian', 'DiffMin', 'DiffMax', 'CiLevel', 'CiLow', 'CiHigh', 'CiCoverageMin') -contains $property.Name) {
                $out[$property.Name] = Format-Raw $property.Value
            }
            else { $out[$property.Name] = $property.Value }
        }
        $summaryRows.Add([pscustomobject]$out)
    }
}
$summaryRows | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'summary.csv') -NoTypeInformation -Encoding UTF8

# Markdown: protocol notes, correctness, validity, then resources.
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add(('Phase: {0}. Commit {1}. {2}. Analysis: {3}.' -f $phase, $firstConfiguration.gitHead, $firstConfiguration.os, (Split-Path -Leaf $OutputDirectory)))
$lines.Add('')
foreach ($source in $sources) {
    $lines.Add(('- {0}: profile {1}, nominal monitor interval {2} s, look {3}' -f (Split-Path -Leaf $source.Directory), $source.Configuration.profile, $source.Configuration.sampleIntervalSeconds, $source.Look))
}
$lines.Add('')
$lines.Add('Estimand: median paired difference (runtime - plain) over valid pairs. Primary family: LoadCpuSeconds (Cpu profile) and LoadPrivateMBAvg (Ram profile) per scenario, Holm over all of them. MaxSample columns are the largest sampled value, not a guaranteed true peak. CI coverage is a guaranteed minimum (exact only without ties).')
$lines.Add('')
if ($deviations.Count -gt 0) {
    $lines.Add('## Protocol deviations')
    $lines.Add('')
    foreach ($deviation in $deviations) { $lines.Add("- $deviation") }
    $lines.Add('')
}
$lines.Add('## Correctness (counters per run)')
$lines.Add('')
$lines.Add('| Profile | Scenario | Pair | Build | Passed | Rounds passed | Overruns | Received | Executed | Coalesced | Cache hits | Failed | Note |')
$lines.Add('|---|---|---|---|---|---|---|---|---|---|---|---|---|')
foreach ($run in @($runs | Sort-Object Profile, Scenario, Pair, Build)) {
    $lines.Add(('| {13} | {0} | {1} | {2} | {3} | {4}/{5} | {6} | {7} | {8} | {9} | {10} | {11} | {12} |' -f $run.Scenario, $run.Pair, $run.Build, $run.Passed, $run.PassedRounds, $run.Rounds, $run.Overruns, $run.RequestsReceived, $run.OperationsExecuted, $run.CoalescedRequests, $run.CacheHits, $run.FailedRequests, $run.Error, $run.Profile))
}
$lines.Add('')
$lines.Add('## Run validity and monitoring')
$lines.Add('')
$lines.Add('| Run | Valid | Load rows / expected | Interval median: run / load; load max (s) | Monitor exit / CPU s | Reason |')
$lines.Add('|---|---|---|---|---|---|')
foreach ($run in @($runs | Sort-Object Profile, Scenario, Pair, Build)) {
    $lines.Add(('| {10} {0}-{1}-{2} | {3} | {4} / {5} | {6} / {11}; {7} | {12} / {8} | {9} |' -f $run.Scenario, $run.Pair, $run.Build, $run.Valid, $run.LoadRows, $run.LoadRowsExpected, (Format-Number $run.IntervalMedianSeconds 3), (Format-Number $run.LoadIntervalMaxSeconds 3), $run.MonitorCpuSeconds, $run.InvalidReason, $run.Profile, (Format-Number $run.LoadIntervalMedianSeconds 3), $run.MonitorExit))
}
$lines.Add('')
$invalidPairs = @($pairRows | Where-Object { -not $_.Valid })
$lines.Add(('Invalid pairs (kept in pairs.csv, left out of the statistics): {0}' -f $(if ($invalidPairs.Count -eq 0) { 'none' } else { ($invalidPairs | ForEach-Object { "$($_.Profile) $($_.Scenario) pair $($_.Pair)" }) -join ', ' })))
$lines.Add('')
foreach ($look in $looks) {
    $lines.Add("## Resources and latency, $($look.Name) (paired differences: runtime - plain)")
    $lines.Add('')
    $lines.Add('CPU metrics are not compared in the Ram profile (0.2 s WMI sampling adds observer overhead).')
    $lines.Add('')
    $lines.Add('| Profile | Scenario | Metric | Role | Valid / in look | Metric-excluded | Zero diffs | Plain median | Runtime median | Diff median | Diff min..max | CI of median diff | p (Holm) | Verdict |')
    $lines.Add('|---|---|---|---|---|---|---|---|---|---|---|---|---|---|')
    foreach ($row in @($looks | Where-Object { $_.Name -eq $look.Name } | ForEach-Object { $_.Rows })) {
        $ci = if ($null -ne $row.CiLow) { '{0}..{1} (>= {2}%)' -f (Format-Number $row.CiLow), (Format-Number $row.CiHigh), ([Math]::Floor($row.CiCoverageMin * 1000) / 10).ToString('0.#', $culture) } elseif ($row.ValidPairs -gt 0) { "too few pairs for $(([double]$row.CiLevel * 100).ToString('0.#', $culture))%" } else { '' }
        $pText = if ($null -ne $row.P) { '{0} ({1})' -f (Format-Number $row.P 4), (Format-Number $row.PHolm 4) } else { '' }
        $lines.Add(('| {0} | {1} | {2} | {3} | {4} / {5} | {6} | {7} | {8} | {9} | {10} | {11}..{12} | {13} | {14} | {15} |' -f $row.Profile, $row.Scenario, $row.Metric, $row.Role, $row.ValidPairs, $row.PairsInLook, $row.MetricExcludedPairs, $row.ZeroDiffs,
                (Format-Number $row.PlainMedian), (Format-Number $row.RuntimeMedian), (Format-Number $row.DiffMedian), (Format-Number $row.DiffMin), (Format-Number $row.DiffMax), $ci, $pText, $row.Verdict))
    }
    $lines.Add('')
}
$lines | Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.md') -Encoding UTF8
Write-Host "Wrote runs.csv, pairs.csv, summary.csv and summary.md to $OutputDirectory"
) { continue }
        $scenario = $Matches[1]; $pair = [int]$Matches[2]; $build = $Matches[3]
        $log = $logByRun[$base]
        $reasons = New-Object System.Collections.Generic.List[string]
        $report = $null
        if (-not $reportFilesByName.ContainsKey($base)) { $reasons.Add('JSON report missing') }
        else {
            try { $report = Get-Content -LiteralPath $reportFilesByName[$base].FullName -Raw | ConvertFrom-Json }
            catch { $reasons.Add('report is not valid JSON') }
        }
        $row = [ordered]@{
            Profile = $monitorProfile; Scenario = $scenario; Pair = $pair; Build = $build; Directory = Split-Path -Leaf $directory
            Valid = $false; InvalidReason = ''
            Passed = $false; Error = ''
            ExitCode = $(if ($null -ne $log) { $log.exitCode } else { $null })
            TimedOut = $(if ($null -ne $log) { $log.timedOut } else { $null })
            Rounds = $null; PassedRounds = $null; Overruns = $null
            RequestsReceived = $null; OperationsExecuted = $null; CoalescedRequests = $null; CacheHits = $null; FailedRequests = $null
            RequestsPerSecond = $null; RoundMsP50 = $null; RoundMsP95 = $null
            MonitorExit = $(if ($null -ne $log -and $log.PSObject.Properties['monitorExit']) { $log.monitorExit } else { $null })
            MonitorRows = 0; LoadRows = 0; LoadRowsExpected = $null
            LoadRowsWithMissingPrivate = $null; LoadRowsWithUnreadableCpu = $null; LoadRowsWithMissingWorkingSet = $null
            LoadRowsWithInvalidInterval = $null; LoadProcessCountMax = $null
            PrivateMetricsValid = $false; CpuMetricsValid = $false; WorkingSetMetricsValid = $false; DiagnosticsPrivateMetricsValid = $false
            IdleBeforePrivateMetricsValid = $false; IdleAfterPrivateMetricsValid = $false; IdleBeforeCpuMetricsValid = $false
            IntervalMedianSeconds = $null; IntervalMaxSeconds = $null; LoadIntervalMedianSeconds = $null; LoadIntervalMaxSeconds = $null
            MonitorCpuSeconds = $(if ($null -ne $log -and $log.PSObject.Properties['monitorCpuSeconds']) { $log.monitorCpuSeconds } else { $null })
        }
        foreach ($metric in $resourceMetrics) { $row[$metric] = $null }
        $seen[$base] = $true

        foreach ($reason in @(Get-LogReasons $log)) { $reasons.Add($reason) }
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
                        Timestamp  = [string]$_.Timestamp
                        Time       = Get-Time $_.Timestamp
                        RootPid    = [int]$_.RootPid
                        Processes  = [int]$_.ProcessCount
                        WorkingSet = ConvertTo-Number $_.WorkingSetMB
                        Private    = ConvertTo-Number $_.PrivateBytesMB
                        CpuDelta   = ConvertTo-Number $_.CpuDeltaSeconds
                        Sample     = [int]$_.Sample
                        Interval   = ConvertTo-Number $_.IntervalSeconds
                        PrivateMissing = ConvertTo-Number $_.PrivateMissingCount
                        CpuUnreadable  = ConvertTo-Number $_.CpuUnreadableCount
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
            # The cadence is checked inside the load phase itself; the whole-run median is only context.
            $row.LoadRowsWithInvalidInterval = @($load | Where-Object { $_.Sample -eq 0 -or $null -eq $_.Interval -or $_.Interval -le 0 }).Count
            $loadIntervals = @($load | Where-Object { $_.Sample -gt 0 -and $null -ne $_.Interval -and $_.Interval -gt 0 } | ForEach-Object { $_.Interval })
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
            $row.LoadRowsWithMissingPrivate = @($load | Where-Object { $null -eq $_.Private -or $null -eq $_.PrivateMissing -or $_.PrivateMissing -gt 0 }).Count
            $row.LoadRowsWithUnreadableCpu = @($load | Where-Object { $null -eq $_.CpuDelta -or $null -eq $_.CpuUnreadable -or $_.CpuUnreadable -gt 0 }).Count
            $row.LoadRowsWithMissingWorkingSet = @($load | Where-Object { $null -eq $_.WorkingSet }).Count
            $row.LoadProcessCountMax = Get-Max @($load | ForEach-Object { [double]$_.Processes })
            $row.PrivateMetricsValid = $load.Count -gt 0 -and $row.LoadRowsWithMissingPrivate -eq 0
            $row.CpuMetricsValid = $load.Count -gt 0 -and $row.LoadRowsWithUnreadableCpu -eq 0
            $row.WorkingSetMetricsValid = $load.Count -gt 0 -and $row.LoadRowsWithMissingWorkingSet -eq 0
            $row.IdleBeforePrivateMetricsValid = $idleBefore.Count -gt 0 -and @($idleBefore | Where-Object { $null -eq $_.Private -or $null -eq $_.PrivateMissing -or $_.PrivateMissing -gt 0 }).Count -eq 0
            $row.IdleAfterPrivateMetricsValid = $idleAfter.Count -gt 0 -and @($idleAfter | Where-Object { $null -eq $_.Private -or $null -eq $_.PrivateMissing -or $_.PrivateMissing -gt 0 }).Count -eq 0
            $idleBeforeCpuRows = @($idleBefore | Where-Object { $_.Sample -gt 0 })
            $row.IdleBeforeCpuMetricsValid = $idleBeforeCpuRows.Count -gt 0 -and @($idleBeforeCpuRows | Where-Object { $null -eq $_.CpuDelta -or $null -eq $_.CpuUnreadable -or $_.CpuUnreadable -gt 0 }).Count -eq 0

            # A secondary metric with incomplete samples is not averaged over only the readable rows.
            if (-not $row.PrivateMetricsValid) { $row.LoadPrivateMBAvg = $null; $row.LoadPrivateMBMaxSample = $null }
            if (-not $row.WorkingSetMetricsValid) { $row.LoadWorkingSetMBAvg = $null; $row.LoadWorkingSetMBMaxSample = $null }
            if (-not $row.CpuMetricsValid) { $row.LoadCpuSeconds = $null }
            if (-not $row.IdleBeforePrivateMetricsValid) { $row.IdleBeforePrivateMB = $null }
            if (-not $row.IdleAfterPrivateMetricsValid) { $row.IdleAfterPrivateMB = $null }
            if (-not $row.IdleBeforeCpuMetricsValid) { $row.IdleBeforeCpuSeconds = $null }

            if ($row.LoadRowsExpected -gt 0 -and $row.LoadRows -lt $minLoadCoverage * $row.LoadRowsExpected) { $reasons.Add("load rows $($row.LoadRows) < $([int]($minLoadCoverage * 100))% of $($row.LoadRowsExpected)") }
            # Private memory is primary only in the Ram profile; an incomplete secondary private-memory metric
            # does not discard otherwise valid CPU observations in the Cpu profile.
            if ($monitorProfile -eq 'Ram' -and -not $row.PrivateMetricsValid) { $reasons.Add("$($row.LoadRowsWithMissingPrivate) load rows with missing or non-finite private memory") }
            # CPU is compared only in the Cpu profile, so unreadable CPU invalidates only those runs.
            if ($monitorProfile -eq 'Cpu' -and -not $row.CpuMetricsValid) { $reasons.Add("$($row.LoadRowsWithUnreadableCpu) load rows with missing or non-finite CPU") }
            if ($row.LoadRowsWithInvalidInterval -gt 0) { $reasons.Add("$($row.LoadRowsWithInvalidInterval) load rows with a missing, non-finite or non-positive interval") }
            if ($null -eq $row.LoadIntervalMedianSeconds -or [Math]::Abs($row.LoadIntervalMedianSeconds - $nominalInterval) -gt $maxIntervalDeviation * $nominalInterval) {
                $reasons.Add("load interval median $(Format-Number $row.LoadIntervalMedianSeconds 3) s not within $([int]($maxIntervalDeviation * 100))% of $nominalInterval s")
            }
            if ($null -ne $row.LoadIntervalMaxSeconds -and $row.LoadIntervalMaxSeconds -gt $maxIntervalFactor * $nominalInterval) {
                $reasons.Add("load gap $(Format-Number $row.LoadIntervalMaxSeconds 3) s > $maxIntervalFactor x $nominalInterval s")
            }

            $diagnosticsFile = Join-Path $runsDirectory "$base.monitor.diagnostics.csv"
            if ((Test-Path -LiteralPath $diagnosticsFile) -and $samples.Count -gt 0) {
                $rootPid = $samples[0].RootPid
                $diagnosticLoadRows = @(Import-Csv -LiteralPath $diagnosticsFile | Where-Object { $_.InTree -eq 'True' } | Where-Object {
                        $time = Get-Time $_.Timestamp; $time -ge $loadFrom -and $time -lt $loadTo
                    })
                $row.DiagnosticsPrivateMetricsValid = $load.Count -gt 0 -and $diagnosticLoadRows.Count -gt 0
                if ($row.DiagnosticsPrivateMetricsValid) {
                    foreach ($sample in $load) {
                        $atSample = @($diagnosticLoadRows | Where-Object { $_.Timestamp -eq $sample.Timestamp })
                        $atSampleBytes = @($atSample | ForEach-Object { ConvertTo-Number $_.CimPrivatePageCount })
                        if ($atSample.Count -ne $sample.Processes -or $atSampleBytes.Count -ne $atSample.Count -or @($atSampleBytes | Where-Object { $null -eq $_ }).Count -gt 0) {
                            $row.DiagnosticsPrivateMetricsValid = $false
                            break
                        }
                    }
                }
                $rootRows = @($diagnosticLoadRows | Where-Object { [int]$_.Pid -eq $rootPid })
                $rootValues = @($rootRows | ForEach-Object { ConvertTo-Number $_.CimPrivatePageCount })
                if ($rootRows.Count -ne $load.Count -or $rootValues.Count -ne $rootRows.Count -or @($rootValues | Where-Object { $null -eq $_ }).Count -gt 0) {
                    $row.DiagnosticsPrivateMetricsValid = $false
                }
                if ($row.DiagnosticsPrivateMetricsValid) {
                    $row.ExePrivateMBLoadAvg = Get-Average @($rootValues | ForEach-Object { $_ / 1MB })
                    if ($row.PrivateMetricsValid -and $null -ne $row.LoadPrivateMBAvg) {
                        $row.WebViewPrivateMBLoadAvg = $row.LoadPrivateMBAvg - $row.ExePrivateMBLoadAvg
                    }
                }
                else {
                    $row.ExePrivateMBLoadAvg = $null
                    $row.WebViewPrivateMBLoadAvg = $null
                }
            }
        }
        else {
            $reasons.Add('monitor CSV missing')
        }
        $primaryMetric = $primaryByProfile[$monitorProfile]
        if ($null -eq $row[$primaryMetric]) { $reasons.Add("$primaryMetric missing") }
        $row.Valid = $reasons.Count -eq 0
        $row.InvalidReason = $reasons -join '; '
        $runs.Add([pscustomobject]$row)
    }

    # A scheduled or logged launch without a JSON report stays in the data as an invalid run,
    # so a crash or timeout cannot drop a pair from the family.
    $expectedNames = @(@($scheduled) + @($logOrder) | Where-Object { $_ -match '^S[1-4]-pair\d+-(plain|runtime)$' } | Sort-Object -Unique)
    foreach ($name in $expectedNames) {
        if ($seen.ContainsKey($name)) { continue }
        $null = $name -match '^(S[1-4])-pair(\d+)-(plain|runtime)$'
        $log = $logByRun[$name]
        $reasons = New-Object System.Collections.Generic.List[string]
        $reasons.Add('JSON report missing')
        foreach ($reason in @(Get-LogReasons $log)) { $reasons.Add($reason) }
        $row = [ordered]@{
            Profile = $monitorProfile; Scenario = $Matches[1]; Pair = [int]$Matches[2]; Build = $Matches[3]; Directory = Split-Path -Leaf $directory
            Valid = $false; InvalidReason = $reasons -join '; '
            Passed = $false; Error = 'JSON report missing'
            ExitCode = $(if ($null -ne $log) { $log.exitCode } else { $null })
            TimedOut = $(if ($null -ne $log) { $log.timedOut } else { $null })
            Rounds = $null; PassedRounds = $null; Overruns = $null
            RequestsReceived = $null; OperationsExecuted = $null; CoalescedRequests = $null; CacheHits = $null; FailedRequests = $null
            RequestsPerSecond = $null; RoundMsP50 = $null; RoundMsP95 = $null
            MonitorExit = $(if ($null -ne $log -and $log.PSObject.Properties['monitorExit']) { $log.monitorExit } else { $null })
            MonitorRows = 0; LoadRows = 0; LoadRowsExpected = $null
            LoadRowsWithMissingPrivate = $null; LoadRowsWithUnreadableCpu = $null; LoadRowsWithMissingWorkingSet = $null
            LoadRowsWithInvalidInterval = $null; LoadProcessCountMax = $null
            PrivateMetricsValid = $false; CpuMetricsValid = $false; WorkingSetMetricsValid = $false; DiagnosticsPrivateMetricsValid = $false
            IdleBeforePrivateMetricsValid = $false; IdleAfterPrivateMetricsValid = $false; IdleBeforeCpuMetricsValid = $false
            IntervalMedianSeconds = $null; IntervalMaxSeconds = $null; LoadIntervalMedianSeconds = $null; LoadIntervalMaxSeconds = $null
            MonitorCpuSeconds = $(if ($null -ne $log -and $log.PSObject.Properties['monitorCpuSeconds']) { $log.monitorCpuSeconds } else { $null })
        }
        $row.PrivateMetricsValid = $false; $row.CpuMetricsValid = $false; $row.WorkingSetMetricsValid = $false; $row.DiagnosticsPrivateMetricsValid = $false
        $row.IdleBeforePrivateMetricsValid = $false; $row.IdleAfterPrivateMetricsValid = $false; $row.IdleBeforeCpuMetricsValid = $false
        foreach ($metric in $resourceMetrics) { $row[$metric] = $null }
        $runs.Add([pscustomobject]$row)
    }
}

if ($runs.Count -eq 0) { throw "No run reports found in $(($sources | ForEach-Object { $_.Directory }) -join ', ')" }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

$numberColumns = @($resourceMetrics + $performanceMetrics)
$formattedColumns = @($numberColumns + @('IntervalMedianSeconds', 'IntervalMaxSeconds', 'LoadIntervalMedianSeconds', 'LoadIntervalMaxSeconds'))
$runs | ForEach-Object {
    $out = [ordered]@{}
    foreach ($property in $_.PSObject.Properties) {
        if ($formattedColumns -contains $property.Name) { $out[$property.Name] = Format-Raw $property.Value }
        else { $out[$property.Name] = $property.Value }
    }
    [pscustomobject]$out
} | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'runs.csv') -NoTypeInformation -Encoding UTF8

# Paired differences; a pair is valid only if both of its runs are.
$pairRows = New-Object System.Collections.Generic.List[object]
foreach ($group in @($runs | Group-Object Profile, Scenario, Pair | Sort-Object { $_.Group[0].Profile }, { $_.Group[0].Scenario }, { $_.Group[0].Pair })) {
    $plain = @($group.Group | Where-Object { $_.Build -eq 'plain' })
    $runtime = @($group.Group | Where-Object { $_.Build -eq 'runtime' })
    $reasons = New-Object System.Collections.Generic.List[string]
    if ($plain.Count -ne 1) { $reasons.Add("plain runs: $($plain.Count)") }
    if ($runtime.Count -ne 1) { $reasons.Add("runtime runs: $($runtime.Count)") }
    foreach ($run in @($plain + $runtime)) { if (-not $run.Valid) { $reasons.Add("$($run.Build): $($run.InvalidReason)") } }
    $first = $group.Group[0]
    $pairRow = [ordered]@{ Profile = $first.Profile; Scenario = $first.Scenario; Pair = $first.Pair; Valid = $reasons.Count -eq 0; InvalidReason = $reasons -join '; ' }
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
    $out = [ordered]@{ Profile = $_.Profile; Scenario = $_.Scenario; Pair = $_.Pair; Valid = $_.Valid; InvalidReason = $_.InvalidReason }
    foreach ($metric in $numberColumns) {
        $out["Plain$metric"] = Format-Raw $_."Plain$metric"; $out["Runtime$metric"] = Format-Raw $_."Runtime$metric"; $out[$metric] = Format-Raw $_.$metric
    }
    [pscustomobject]$out
} | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'pairs.csv') -NoTypeInformation -Encoding UTF8

function Invoke-Analysis {
    # One look: per profile, scenario and metric, statistics over the valid pairs with Pair <= MaxPair.
    param([int]$MaxPair, [double]$Alpha, [string[]]$TestedKeys)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($cell in $cells) {
        $monitorProfile = $cell.Profile; $scenario = $cell.Scenario
        $inLook = @($pairRows | Where-Object { $_.Profile -eq $monitorProfile -and $_.Scenario -eq $scenario -and $_.Pair -le $MaxPair })
        $valid = @($inLook | Where-Object { $_.Valid })
        foreach ($metric in $comparedByProfile[$monitorProfile]) {
            $usable = @($valid | Where-Object { $null -ne $_.$metric })
            $diffs = [double[]]@($usable | ForEach-Object { [double]$_.$metric })
            $plainValues = [double[]]@($usable | ForEach-Object { [double]$_."Plain$metric" })
            $runtimeValues = [double[]]@($usable | ForEach-Object { [double]$_."Runtime$metric" })
            $key = "$monitorProfile/$scenario/$metric"
            $primary = $primaryByProfile[$monitorProfile] -eq $metric
            $row = [pscustomobject][ordered]@{
                Profile = $monitorProfile; Scenario = $scenario; Metric = $metric
                Role = $(if ($primary) { 'primary' } else { 'secondary' })
                PairsInLook = $inLook.Count; ValidPairs = $diffs.Count; InvalidPairs = $inLook.Count - $valid.Count
                MetricExcludedPairs = $valid.Count - $usable.Count
                ZeroDiffs = [SymmetricBenchStats]::CountZeros($diffs)
                PlainMedian = Get-Median $plainValues; RuntimeMedian = Get-Median $runtimeValues
                DiffMedian = Get-Median $diffs
                DiffMin = $(if ($diffs.Count -gt 0) { ($diffs | Measure-Object -Minimum).Minimum } else { $null })
                DiffMax = $(if ($diffs.Count -gt 0) { ($diffs | Measure-Object -Maximum).Maximum } else { $null })
                CiLevel = 1 - $Alpha; CiLow = $null; CiHigh = $null; CiCoverageMin = $null
                P = $null; PHolm = $null; Decided = $false; Verdict = ''
            }
            if ($diffs.Count -ge 1) {
                $interval = [SymmetricBenchStats]::MedianInterval($diffs, 1 - $Alpha)
                if ($null -ne $interval) { $row.CiLow = $interval[0]; $row.CiHigh = $interval[1]; $row.CiCoverageMin = $interval[2] }
            }
            if ($primary -and $TestedKeys -contains $key -and $diffs.Count -ge $minValidPairsPerLook) {
                $row.P = [SymmetricBenchStats]::SignTestP($diffs)
            }
            $rows.Add($row)
        }
    }
    # Holm over every hypothesis tested in this look. One without a p-value (too few valid
    # pairs) stays in the family with p = 1, so failed runs never weaken the correction.
    $tested = @($rows | Where-Object { $_.Role -eq 'primary' -and $TestedKeys -contains "$($_.Profile)/$($_.Scenario)/$($_.Metric)" } |
        ForEach-Object { [pscustomobject]@{ Row = $_; P = $(if ($null -eq $_.P) { 1.0 } else { [double]$_.P }) } } | Sort-Object P)
    if ($tested.Count -ne $TestedKeys.Count) { throw "Holm family has $($tested.Count) rows for $($TestedKeys.Count) hypotheses." }
    $running = 0.0
    for ($k = 0; $k -lt $tested.Count; $k++) {
        $adjusted = [Math]::Min(1.0, ($tested.Count - $k) * $tested[$k].P)
        if ($adjusted -lt $running) { $adjusted = $running }
        $running = $adjusted
        $tested[$k].Row.PHolm = $adjusted
    }
    foreach ($row in $rows) {
        if ($row.ValidPairs -eq 0) { $row.Verdict = 'no valid data'; continue }
        if ($row.Role -ne 'primary') { $row.Verdict = 'secondary: descriptive'; continue }
        if ($TestedKeys -notcontains "$($row.Profile)/$($row.Scenario)/$($row.Metric)") { continue }
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

# Cells analysed: the declared family (Cpu and Ram x S1-S4) for confirmatory results, whatever
# data exists; the cells present in the data for a pilot.
$cells = if ($phase -eq 'Confirmatory') {
    @(foreach ($profileName in @('Cpu', 'Ram')) { foreach ($scenario in $familyScenarios) { [pscustomobject]@{ Profile = $profileName; Scenario = $scenario } } })
}
else { @($pairRows | Select-Object Profile, Scenario -Unique | Sort-Object Profile, Scenario) }
$allPrimaryKeys = @($cells | ForEach-Object { "$($_.Profile)/$($_.Scenario)/$($primaryByProfile[$_.Profile])" })
$hasExtension = @($sources | Where-Object { $_.Look -eq 2 }).Count -gt 0
$looks = New-Object System.Collections.Generic.List[object]
if ($phase -eq 'Pilot') {
    $rows = Invoke-Analysis -MaxPair ([int]::MaxValue) -Alpha 0.05 -TestedKeys @()
    foreach ($row in $rows) { if ($row.Role -eq 'primary' -and $row.ValidPairs -gt 0) { $row.Verdict = 'pilot: no conclusion' } }
    $looks.Add([pscustomobject]@{ Name = 'pilot'; Rows = $rows })
}
else {
    $look1 = Invoke-Analysis -MaxPair $plannedPairsPerLook -Alpha $lookAlpha -TestedKeys $allPrimaryKeys
    $undecided = @($look1 | Where-Object { $_.Role -eq 'primary' -and -not $_.Decided } | ForEach-Object { "$($_.Profile)/$($_.Scenario)/$($_.Metric)" })
    foreach ($row in $look1) {
        if ($row.Role -eq 'primary' -and -not $row.Decided) {
            $note = $(if ($hasExtension) { 'undecided, tested again at look 2' } else { 'undecided: extend to 20 pairs' })
            $row.Verdict = $(if ($row.Verdict) { "$($row.Verdict); $note" } else { $note })
        }
    }
    $looks.Add([pscustomobject]@{ Name = 'look1'; Rows = $look1 })
    if ($hasExtension) {
        # Fail closed: every undecided hypothesis needs its own planned pairs 11-20, and the
        # extension holds exactly the undecided scenarios, so look 1 data is never re-tested as look 2.
        foreach ($profileName in @('Cpu', 'Ram')) {
            $required = @($undecided | Where-Object { $_.Split('/')[0] -eq $profileName } | ForEach-Object { $_.Split('/')[1] } | Sort-Object -Unique)
            $extensionSource = @($sources | Where-Object { $_.Look -eq 2 -and [string]$_.Configuration.profile -eq $profileName })
            $configured = if ($extensionSource.Count -eq 1) { @($extensionSource[0].Configuration.scenarios | ForEach-Object { [string]$_ } | Sort-Object -Unique) } else { @() }
            if (($required -join ',') -ne ($configured -join ',')) {
                throw "Profile ${profileName}: the extension must hold exactly the scenarios undecided at look 1 [$($required -join ', ')], got [$($configured -join ', ')]."
            }
            foreach ($scenario in $required) {
                for ($pairNumber = $plannedPairsPerLook + 1; $pairNumber -le 2 * $plannedPairsPerLook; $pairNumber++) {
                    $found = @($pairRows | Where-Object { $_.Profile -eq $profileName -and $_.Scenario -eq $scenario -and $_.Pair -eq $pairNumber }).Count
                    if ($found -ne 1) { throw "Profile $profileName ${scenario}: planned pair $pairNumber appears $found times; look 2 needs each of pairs $($plannedPairsPerLook + 1)..$(2 * $plannedPairsPerLook) once." }
                }
            }
        }
        $look2 = Invoke-Analysis -MaxPair (2 * $plannedPairsPerLook) -Alpha $lookAlpha -TestedKeys $undecided
        foreach ($row in $look2) {
            if ($row.Role -ne 'primary') { continue }
            if ($undecided -notcontains "$($row.Profile)/$($row.Scenario)/$($row.Metric)") { $row.Verdict = 'decided at look 1'; continue }
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
            if (@('P', 'PHolm', 'PlainMedian', 'RuntimeMedian', 'DiffMedian', 'DiffMin', 'DiffMax', 'CiLevel', 'CiLow', 'CiHigh', 'CiCoverageMin') -contains $property.Name) {
                $out[$property.Name] = Format-Raw $property.Value
            }
            else { $out[$property.Name] = $property.Value }
        }
        $summaryRows.Add([pscustomobject]$out)
    }
}
$summaryRows | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'summary.csv') -NoTypeInformation -Encoding UTF8

# Markdown: protocol notes, correctness, validity, then resources.
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add(('Phase: {0}. Commit {1}. {2}. Analysis: {3}.' -f $phase, $firstConfiguration.gitHead, $firstConfiguration.os, (Split-Path -Leaf $OutputDirectory)))
$lines.Add('')
foreach ($source in $sources) {
    $lines.Add(('- {0}: profile {1}, nominal monitor interval {2} s, look {3}' -f (Split-Path -Leaf $source.Directory), $source.Configuration.profile, $source.Configuration.sampleIntervalSeconds, $source.Look))
}
$lines.Add('')
$lines.Add('Estimand: median paired difference (runtime - plain) over valid pairs. Primary family: LoadCpuSeconds (Cpu profile) and LoadPrivateMBAvg (Ram profile) per scenario, Holm over all of them. MaxSample columns are the largest sampled value, not a guaranteed true peak. CI coverage is a guaranteed minimum (exact only without ties).')
$lines.Add('')
if ($deviations.Count -gt 0) {
    $lines.Add('## Protocol deviations')
    $lines.Add('')
    foreach ($deviation in $deviations) { $lines.Add("- $deviation") }
    $lines.Add('')
}
$lines.Add('## Correctness (counters per run)')
$lines.Add('')
$lines.Add('| Profile | Scenario | Pair | Build | Passed | Rounds passed | Overruns | Received | Executed | Coalesced | Cache hits | Failed | Note |')
$lines.Add('|---|---|---|---|---|---|---|---|---|---|---|---|---|')
foreach ($run in @($runs | Sort-Object Profile, Scenario, Pair, Build)) {
    $lines.Add(('| {13} | {0} | {1} | {2} | {3} | {4}/{5} | {6} | {7} | {8} | {9} | {10} | {11} | {12} |' -f $run.Scenario, $run.Pair, $run.Build, $run.Passed, $run.PassedRounds, $run.Rounds, $run.Overruns, $run.RequestsReceived, $run.OperationsExecuted, $run.CoalescedRequests, $run.CacheHits, $run.FailedRequests, $run.Error, $run.Profile))
}
$lines.Add('')
$lines.Add('## Run validity and monitoring')
$lines.Add('')
$lines.Add('| Run | Valid | Load rows / expected | Interval median: run / load; load max (s) | Monitor exit / CPU s | Reason |')
$lines.Add('|---|---|---|---|---|---|')
foreach ($run in @($runs | Sort-Object Profile, Scenario, Pair, Build)) {
    $lines.Add(('| {10} {0}-{1}-{2} | {3} | {4} / {5} | {6} / {11}; {7} | {12} / {8} | {9} |' -f $run.Scenario, $run.Pair, $run.Build, $run.Valid, $run.LoadRows, $run.LoadRowsExpected, (Format-Number $run.IntervalMedianSeconds 3), (Format-Number $run.LoadIntervalMaxSeconds 3), $run.MonitorCpuSeconds, $run.InvalidReason, $run.Profile, (Format-Number $run.LoadIntervalMedianSeconds 3), $run.MonitorExit))
}
$lines.Add('')
$invalidPairs = @($pairRows | Where-Object { -not $_.Valid })
$lines.Add(('Invalid pairs (kept in pairs.csv, left out of the statistics): {0}' -f $(if ($invalidPairs.Count -eq 0) { 'none' } else { ($invalidPairs | ForEach-Object { "$($_.Profile) $($_.Scenario) pair $($_.Pair)" }) -join ', ' })))
$lines.Add('')
foreach ($look in $looks) {
    $lines.Add("## Resources and latency, $($look.Name) (paired differences: runtime - plain)")
    $lines.Add('')
    $lines.Add('CPU metrics are not compared in the Ram profile (0.2 s WMI sampling adds observer overhead).')
    $lines.Add('')
    $lines.Add('| Profile | Scenario | Metric | Role | Valid / in look | Metric-excluded | Zero diffs | Plain median | Runtime median | Diff median | Diff min..max | CI of median diff | p (Holm) | Verdict |')
    $lines.Add('|---|---|---|---|---|---|---|---|---|---|---|---|---|---|')
    foreach ($row in @($looks | Where-Object { $_.Name -eq $look.Name } | ForEach-Object { $_.Rows })) {
        $ci = if ($null -ne $row.CiLow) { '{0}..{1} (>= {2}%)' -f (Format-Number $row.CiLow), (Format-Number $row.CiHigh), ([Math]::Floor($row.CiCoverageMin * 1000) / 10).ToString('0.#', $culture) } elseif ($row.ValidPairs -gt 0) { "too few pairs for $(([double]$row.CiLevel * 100).ToString('0.#', $culture))%" } else { '' }
        $pText = if ($null -ne $row.P) { '{0} ({1})' -f (Format-Number $row.P 4), (Format-Number $row.PHolm 4) } else { '' }
        $lines.Add(('| {0} | {1} | {2} | {3} | {4} / {5} | {6} | {7} | {8} | {9} | {10} | {11}..{12} | {13} | {14} | {15} |' -f $row.Profile, $row.Scenario, $row.Metric, $row.Role, $row.ValidPairs, $row.PairsInLook, $row.MetricExcludedPairs, $row.ZeroDiffs,
                (Format-Number $row.PlainMedian), (Format-Number $row.RuntimeMedian), (Format-Number $row.DiffMedian), (Format-Number $row.DiffMin), (Format-Number $row.DiffMax), $ci, $pText, $row.Verdict))
    }
    $lines.Add('')
}
$lines | Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.md') -Encoding UTF8
Write-Host "Wrote runs.csv, pairs.csv, summary.csv and summary.md to $OutputDirectory"
