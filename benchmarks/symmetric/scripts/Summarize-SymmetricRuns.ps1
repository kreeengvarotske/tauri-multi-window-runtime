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
- Test: exact two-sided sign test (zero differences dropped), Holm over the
  whole family within a look. Interval: closed order-statistic interval for
  the median over all differences, with a guaranteed minimum coverage
  (exact only without ties; see SymmetricBenchStats.cs).
- Confirmatory looks: look 1 after 10 pairs at alpha 0.025; look 2, only for
  tests undecided at look 1, after 20 pairs at alpha 0.025.
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

    # Look 2: the directories of the 10 extension pairs (Run-SymmetricPairs.ps1 -FirstPair 11),
    # one per profile that still has an undecided test after look 1.
    [string[]]$ExtensionDirectory = @(),

    [string]$OutputDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$culture = [System.Globalization.CultureInfo]::InvariantCulture

if (-not ('SymmetricBenchStats' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'SymmetricBenchStats.cs')
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
    'iterations', 'bufferMb', 'requestsPerWindow', 'roundIntervalMs')
$sources = New-Object System.Collections.Generic.List[object]
foreach ($path in $ResultsDirectory) {
    $directory = (Resolve-Path -LiteralPath $path).Path
    $sources.Add([pscustomobject]@{ Directory = $directory; Configuration = (Read-Configuration $directory); Look = 1 })
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
        if ([int](Get-ConfigValue $source.Configuration 'firstPair' 1) -ne 1 -or [int]$source.Configuration.pairs -ne $plannedPairsPerLook) {
            throw "Confirmatory look 1 must be pairs 1..$plannedPairsPerLook (got firstPair $(Get-ConfigValue $source.Configuration 'firstPair' 1), pairs $($source.Configuration.pairs))."
        }
    }
}
if ($ExtensionDirectory.Count -gt 0 -and $phase -ne 'Confirmatory') { throw 'An extension (look 2) exists only for Confirmatory results.' }
foreach ($path in $ExtensionDirectory) {
    $directory = (Resolve-Path -LiteralPath $path).Path
    $extension = Read-Configuration $directory
    $base = @($sources | Where-Object { $_.Look -eq 1 -and [string]$_.Configuration.profile -eq [string]$extension.profile })
    if ($base.Count -ne 1) { throw "Extension $directory has profile '$($extension.profile)' without a look 1 directory for it." }
    if (@($sources | Where-Object { $_.Look -eq 2 -and [string]$_.Configuration.profile -eq [string]$extension.profile }).Count -gt 0) { throw "Two extensions for profile '$($extension.profile)'." }
    foreach ($name in @($identityFields + @('profile', 'phase', 'monitorSha256', 'sampleIntervalSeconds'))) {
        if ([string](Get-ConfigValue $base[0].Configuration $name '') -ne [string](Get-ConfigValue $extension $name '')) {
            throw "Extension differs from look 1 in '$name' ('$(Get-ConfigValue $base[0].Configuration $name '')' vs '$(Get-ConfigValue $extension $name '')'); it cannot be pooled."
        }
    }
    if ([int](Get-ConfigValue $extension 'firstPair' 1) -ne $plannedPairsPerLook + 1 -or [int]$extension.pairs -ne $plannedPairsPerLook) {
        throw "The extension must be pairs $($plannedPairsPerLook + 1)..$(2 * $plannedPairsPerLook) (-FirstPair $($plannedPairsPerLook + 1) -Pairs $plannedPairsPerLook)."
    }
    $sources.Add([pscustomobject]@{ Directory = $directory; Configuration = $extension; Look = 2 })
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

    # Keep every planned/logged launch, including launches that never produce JSON.
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

    $reportFilesByName = @{}
    foreach ($reportFile in @(Get-ChildItem -LiteralPath $runsDirectory -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $reportFilesByName[[System.IO.Path]::GetFileNameWithoutExtension($reportFile.Name)] = $reportFile
    }
    $runNames = New-Object System.Collections.Generic.List[string]
    foreach ($candidateName in (@($scheduled) + @($logOrder) + @($reportFilesByName.Keys))) {
        if ([string]::IsNullOrWhiteSpace([string]$candidateName) -or [string]$candidateName -notmatch '^(S[1-4])-pair(\d+)-(plain|runtime)$') { continue }
        if (-not $runNames.Contains([string]$candidateName)) { $runNames.Add([string]$candidateName) }
    }
    foreach ($base in $runNames) {
        if ($base -notmatch '^(S[1-4])-pair(\d+)-(plain|runtime)$') { continue }
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
            MonitorRows = 0; LoadRows = 0; LoadRowsExpected = $null; LoadRowsWithMissingValues = $null; LoadProcessCountMax = $null
            IntervalMedianSeconds = $null; IntervalMaxSeconds = $null; LoadIntervalMaxSeconds = $null
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
            if ($null -ne $report -and $report.PSObject.Properties['configError']) { $row.Error = [string]$report.configError }
            elseif ($null -ne $report -and $report.PSObject.Properties['error']) { $row.Error = [string]$report.error }
            if ($reasons.Count -eq 0) { $reasons.Add('no summary in report') }
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
                        Interval   = ConvertTo-Number $_.IntervalSeconds
                        Missing    = [int](ConvertTo-Number $_.PrivateMissingCount) + [int](ConvertTo-Number $_.CpuUnreadableCount)
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
            $row.LoadIntervalMaxSeconds = Get-Max @($load | Where-Object { $_.Sample -gt 0 -and $null -ne $_.Interval } | ForEach-Object { $_.Interval })
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
            $row.LoadRowsWithMissingValues = @($load | Where-Object { $_.Missing -gt 0 }).Count
            $row.LoadProcessCountMax = Get-Max @($load | ForEach-Object { [double]$_.Processes })

            if ($row.LoadRowsExpected -gt 0 -and $row.LoadRows -lt $minLoadCoverage * $row.LoadRowsExpected) { $reasons.Add("load rows $($row.LoadRows) < $([int]($minLoadCoverage * 100))% of $($row.LoadRowsExpected)") }
            if ($row.LoadRowsWithMissingValues -gt 0) { $reasons.Add("$($row.LoadRowsWithMissingValues) load rows with missing values") }
            if ($null -eq $row.IntervalMedianSeconds -or [Math]::Abs($row.IntervalMedianSeconds - $nominalInterval) -gt $maxIntervalDeviation * $nominalInterval) {
                $reasons.Add("interval median $(Format-Number $row.IntervalMedianSeconds 3) s not within $([int]($maxIntervalDeviation * 100))% of $nominalInterval s")
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
        $primaryMetric = $primaryByProfile[$monitorProfile]
        if ($null -eq $row[$primaryMetric]) { $reasons.Add("$primaryMetric missing") }
        $row.Valid = $reasons.Count -eq 0
        $row.InvalidReason = $reasons -join '; '
        $runs.Add([pscustomobject]$row)
    }
}

if ($runs.Count -eq 0) { throw "No run reports found in $(($sources | ForEach-Object { $_.Directory }) -join ', ')" }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

$numberColumns = @($resourceMetrics + $performanceMetrics)
$formattedColumns = @($numberColumns + @('IntervalMedianSeconds', 'IntervalMaxSeconds', 'LoadIntervalMaxSeconds'))
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
    foreach ($cell in @($pairRows | Select-Object Profile, Scenario -Unique | Sort-Object Profile, Scenario)) {
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
    # Holm over the primary tests of this look (the whole family, both profiles).
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

$allPrimaryKeys = @($pairRows | Select-Object Profile, Scenario -Unique | ForEach-Object { "$($_.Profile)/$($_.Scenario)/$($primaryByProfile[$_.Profile])" })
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
        foreach ($key in $undecided) {
            $keyProfile = $key.Split('/')[0]
            if (@($sources | Where-Object { $_.Look -eq 2 -and [string]$_.Configuration.profile -eq $keyProfile }).Count -eq 0) {
                throw "Test $key is undecided after look 1, but there is no extension directory for profile $keyProfile."
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
$lines.Add('| Run | Valid | Load rows / expected | Interval median / load max (s) | Monitor CPU s | Reason |')
$lines.Add('|---|---|---|---|---|---|')
foreach ($run in @($runs | Sort-Object Profile, Scenario, Pair, Build)) {
    $lines.Add(('| {10} {0}-{1}-{2} | {3} | {4} / {5} | {6} / {7} | {8} | {9} |' -f $run.Scenario, $run.Pair, $run.Build, $run.Valid, $run.LoadRows, $run.LoadRowsExpected, (Format-Number $run.IntervalMedianSeconds 3), (Format-Number $run.LoadIntervalMaxSeconds 3), $run.MonitorCpuSeconds, $run.InvalidReason, $run.Profile))
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
    $lines.Add('| Profile | Scenario | Metric | Role | Valid / in look (zero diffs) | Plain median | Runtime median | Diff median | Diff min..max | CI of median diff | p (Holm) | Verdict |')
    $lines.Add('|---|---|---|---|---|---|---|---|---|---|---|---|')
    foreach ($row in @($looks | Where-Object { $_.Name -eq $look.Name } | ForEach-Object { $_.Rows })) {
        $ci = if ($null -ne $row.CiLow) { '{0}..{1} (>= {2}%)' -f (Format-Number $row.CiLow), (Format-Number $row.CiHigh), ([Math]::Floor($row.CiCoverageMin * 1000) / 10).ToString('0.#', $culture) } elseif ($row.ValidPairs -gt 0) { "too few pairs for $(([double]$row.CiLevel * 100).ToString('0.#', $culture))%" } else { '' }
        $pText = if ($null -ne $row.P) { '{0} ({1})' -f (Format-Number $row.P 4), (Format-Number $row.PHolm 4) } else { '' }
        $lines.Add(('| {0} | {1} | {2} | {3} | {4} / {5} ({6}) | {7} | {8} | {9} | {10}..{11} | {12} | {13} | {14} |' -f $row.Profile, $row.Scenario, $row.Metric, $row.Role, $row.ValidPairs, $row.PairsInLook, $row.ZeroDiffs,
                (Format-Number $row.PlainMedian), (Format-Number $row.RuntimeMedian), (Format-Number $row.DiffMedian), (Format-Number $row.DiffMin), (Format-Number $row.DiffMax), $ci, $pText, $row.Verdict))
    }
    $lines.Add('')
}
$lines | Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.md') -Encoding UTF8
Write-Host "Wrote runs.csv, pairs.csv, summary.csv and summary.md to $OutputDirectory"
