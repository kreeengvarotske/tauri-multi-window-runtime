<#
.SYNOPSIS
Summarizes Run-CatalogTriplets.ps1 results for memory scenario M: one row per
run with its validity and measures, the differences inside each triplet, and
descriptive statistics per cell and arm.

.DESCRIPTION
Descriptive only: smoke and pilot results carry "descriptive, no conclusion"
whatever the numbers. Confirmatory input mode assembles tables and frozen
sign-test evidence from validated sessions. It does not issue conclusions
under protocol §8b.

Co-primary measures (protocol revision 3, §3, §8c):
- RAM: LoadPrivateMBAvg, the time average over the load phase of the sum of
  Private Bytes over the process tree (host and every WebView2 process);
- CPU: RunCpuSeconds. With cpuSource = job in configuration.json (runner
  with CatalogJobCpu.ps1; every run then needs runs\<run>.job.csv and
  runs\<run>.job.messages.csv, and a run without them is invalid): the CPU time (user + kernel) of the run's Job Object,
  which holds every process of the tree from the first instruction, read at
  the last job row at or before the end of the idle-after phase (checks in
  Get-CatalogJobCpu). Results without cpuSource (legacy, smokes 1 to 3): for every process of the
  tree its last readable cumulative CPU time from the monitor diagnostics at
  or before the end of the idle-after phase, summed; the monitor values are
  kept as MonitorRunCpuSeconds when the job is the source. StartupCpuSeconds is the
  same at the start of the warm-up; LoadCpuSeconds the sum of the monitor's
  per-sample deltas in the load phase.
Working Set is shown only as a diagnostic upper bound (shared pages counted
once per process) and never used for a claim.

Validity (protocol §7): the report exists and passed; exit codes are 0; the
monitor covers at least 80 % of expected load samples; the median load
interval is within 20 % of 1 s and none is longer than 5 s; the process
tree is verified (below); both co-primary measures are finite.

Process tree. With a monitor that records process identities (PID and
creation time: ProcessKeys, UnverifiedProcessCount, RejectedPidReuseCount;
#43), every load row must have UnverifiedProcessCount = 0 and the monitor
diagnostics must show no WebView2 process of the app outside the tree
during the run. A change in the process count during load is then allowed
and reported: a short-lived child seen in some samples is a verified part
of the tree and is in the sums of those samples (TransientProcesses counts
such identities). A child that starts and exits between two samples is
never seen; that limit stays. With an older monitor CSV that has no
identities, the earlier rule applies unchanged: the process count must be
the same in every load sample. Whole-run CPU adds its own checks over the whole measured interval
(first sample to the end of the idle-after phase, post-load idle included):
the first sample is no later than the start of the idle-before phase; no
monitor row has an unreadable CPU value and every in-tree diagnostics row
has a cumulative CPU value; coverage is at least 80 % and no interval is
longer than 5 s. A process that leaves the tree before the end contributes
its last observed value, so its CPU after that sample (at most one interval)
is missing; such processes are counted in CpuExitedProcesses and do not
invalidate the run. A difference inside a triplet uses only valid runs. Invalid runs stay in
runs.csv with their reasons.

Output goes to a new directory (default <results>\analysis-<timestamp>);
raw data is never changed.
#>
[CmdletBinding(DefaultParameterSetName = 'Descriptive')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Descriptive')]
    [string]$ResultsDirectory,

    [Parameter(Mandatory = $true, ParameterSetName = 'Confirmatory')]
    [string[]]$ConfirmatoryDirectories,
    [Parameter(Mandatory = $true, ParameterSetName = 'Confirmatory')]
    [string]$FrozenManifestPath,
    [Parameter(Mandatory = $true, ParameterSetName = 'Confirmatory')]
    [string]$FrozenManifestSha256,
    [Parameter(Mandatory = $true, ParameterSetName = 'Confirmatory')]
    [string]$ThresholdsPath,
    [Parameter(Mandatory = $true, ParameterSetName = 'Confirmatory')]
    [string]$ThresholdsSha256,

    [string]$OutputDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CatalogJobCpu.ps1')
. (Join-Path $PSScriptRoot 'CatalogSignAnalysis.ps1')
$culture = [System.Globalization.CultureInfo]::InvariantCulture

$minLoadCoverage = 0.8
$maxIntervalDeviation = 0.2
$maxIntervalSeconds = 5
$comparisons = @(@('B', 'A'), @('C', 'A'), @('C', 'B'))

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
    $sorted = [double[]]($Values | Sort-Object)
    $middle = [int][Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) { return $sorted[$middle] }
    return ($sorted[$middle - 1] + $sorted[$middle]) / 2
}

function Get-Stat {
    param([double[]]$Values, [ValidateSet('Average', 'Minimum', 'Maximum')][string]$Kind)
    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
    return ($Values | Measure-Object -Average -Minimum -Maximum).$Kind
}

function Get-GuardrailRows {
    param([object[]]$Runs)
    foreach ($cell in ($Runs | Group-Object Cell)) {
        $validByArm = @{}
        foreach ($arm in 'A', 'B', 'C') {
            $validByArm[$arm] = @($cell.Group | Where-Object { $_.Arm -eq $arm -and $_.Valid })
        }
        $p95A = Get-Median @($validByArm['A'] | ForEach-Object P95LatencyMsMax | Where-Object { $null -ne $_ })
        $p95B = Get-Median @($validByArm['B'] | ForEach-Object P95LatencyMsMax | Where-Object { $null -ne $_ })
        $firstA = Get-Median @($validByArm['A'] | ForEach-Object TimeToFirstPageMsMax | Where-Object { $null -ne $_ })
        foreach ($arm in 'B', 'C') {
            $all = @($cell.Group | Where-Object { $_.Arm -eq $arm })
            if ($all.Count -eq 0) { continue }
            $valid = $validByArm[$arm]
            $p95 = Get-Median @($valid | ForEach-Object P95LatencyMsMax | Where-Object { $null -ne $_ })
            $first = Get-Median @($valid | ForEach-Object TimeToFirstPageMsMax | Where-Object { $null -ne $_ })
            [pscustomobject][ordered]@{
                Cell = $cell.Name; Arm = $arm; Runs = $all.Count; ValidRuns = $valid.Count
                RunsWithErrors = @($all | Where-Object { $_.Failures -gt 0 -or $_.Mismatches -gt 0 }).Count
                RunsWithIncompleteSteps = @($all | Where-Object {
                    $null -ne $_.CompletedSteps -and $null -ne $_.ScheduledSteps -and $_.CompletedSteps -lt $_.ScheduledSteps
                }).Count
                RunsMissingCounts = @($all | Where-Object {
                    $null -eq $_.Failures -or $null -eq $_.Mismatches -or
                    $null -eq $_.CompletedSteps -or $null -eq $_.ScheduledSteps
                }).Count
                P95MedianMs = $p95
                P95LimitVsAMs = $(if ($null -ne $p95A) { [Math]::Max(1.5 * $p95A, $p95A + 20) })
                P95AbsoluteLimitMs = 100
                P95LimitVsBMs = $(if ($arm -eq 'C' -and $null -ne $p95B) { 1.2 * $p95B + 5 })
                FirstPageMedianMs = $first
                FirstPageLimitVsAMs = $(if ($null -ne $firstA) { 1.5 * $firstA + 200 })
            }
        }
    }
}

function Format-Number {
    param([AllowNull()][object]$Value, [int]$Digits = 1)
    if ($null -eq $Value -or '' -eq $Value) { return '' }
    return ([double]$Value).ToString(("F{0}" -f $Digits), $culture)
}

function Format-Raw {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or '' -eq $Value) { return '' }
    if ($Value -is [bool] -or $Value -is [string]) { return [string]$Value }
    return ([double]$Value).ToString('R', $culture)
}

function Get-Time {
    param([object]$Value)
    ConvertTo-CatalogTimestamp $Value
}

function Select-Phase {
    param([object[]]$Rows, [DateTimeOffset]$From, [DateTimeOffset]$To)
    @($Rows | Where-Object { $_.Time -ge $From -and $_.Time -lt $To })
}

function Get-Property {
    param([AllowNull()][object]$Object, [string]$Name)
    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) { return $null }
    return $Object.$Name
}

$checked = $null
$runDirectories = @{}
$logs = @{}
if ($PSCmdlet.ParameterSetName -eq 'Confirmatory') {
    . (Join-Path $PSScriptRoot 'CatalogSchedule.ps1')
    . (Join-Path $PSScriptRoot 'CatalogManifest.ps1')
    . (Join-Path $PSScriptRoot 'CatalogConfirmatory.ps1')
    $checked = Assert-CatalogConfirmatoryInputs -ResultsDirectories $ConfirmatoryDirectories -FrozenManifestPath $FrozenManifestPath -FrozenManifestSha256 $FrozenManifestSha256 -ThresholdsPath $ThresholdsPath -ThresholdsSha256 $ThresholdsSha256
    foreach ($run in $checked.Runs) {
        $runDirectories[$run.Name] = Join-Path $run.Directory 'runs'
        $logs[$run.Name] = $run.Log
    }
    $ResultsDirectory = $ConfirmatoryDirectories[0]
}
$ResultsDirectory = (Resolve-Path -LiteralPath $ResultsDirectory).Path
$configurationFile = Join-Path $ResultsDirectory 'configuration.json'
$scheduleFile = Join-Path $ResultsDirectory 'schedule.csv'
if ($checked) { $configuration = $checked.Manifest }
else {
    foreach ($file in @($configurationFile, $scheduleFile)) {
        if (-not (Test-Path -LiteralPath $file)) { throw "Missing $file" }
    }
    $configuration = Get-Content -LiteralPath $configurationFile -Raw | ConvertFrom-Json
    if ([string]$configuration.scenario -ne 'M') { throw "$configurationFile is not a scenario M run." }
}
$nominalInterval = [double]$configuration.sampleIntervalSeconds
if ($checked -and ($nominalInterval -le 0 -or (Get-Property $configuration 'cpuSource') -ne 'job')) {
    throw 'Confirmatory analysis requires a positive frozen sample interval and job CPU.'
}
# The CPU source is fixed by the runner in configuration.json, never inferred
# from which files exist: with cpuSource = job every run needs its job files,
# and a run without them is invalid. Results without cpuSource (written before
# the job runner, smokes 1 to 3) are legacy and keep the monitor rule.
$cpuSource = [string](Get-Property $configuration 'cpuSource')
if ([string]::IsNullOrEmpty($cpuSource)) { $cpuSource = 'legacy-monitor' }
elseif ($cpuSource -ne 'job') { throw "$configurationFile has an unknown cpuSource '$cpuSource'." }
$schedule = @(if ($checked) { $checked.Schedule } else { Import-Csv -LiteralPath $scheduleFile | Sort-Object { [int]$_.Seq } })
if (-not $checked) {
    $runLog = Join-Path $ResultsDirectory 'runs.log'
    if (Test-Path -LiteralPath $runLog) {
        foreach ($line in Get-Content -LiteralPath $runLog) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $entry = $line | ConvertFrom-Json
            $logs[[string]$entry.name] = $entry
        }
    }
}
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $ResultsDirectory ("analysis-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }
if (Test-Path -LiteralPath $OutputDirectory) { throw "$OutputDirectory exists; analyses are never overwritten." }

$runs = New-Object System.Collections.Generic.List[object]
$processes = New-Object System.Collections.Generic.List[object]
foreach ($planned in $schedule) {
    $name = [string]$planned.Name
    $runsDirectory = if ($checked) { $runDirectories[$name] } else { Join-Path $ResultsDirectory 'runs' }
    $reasons = New-Object System.Collections.Generic.List[string]
    $row = [ordered]@{
        Seq = [int]$planned.Seq; Name = $name; Cell = $planned.Cell; Windows = [int]$planned.Windows; DataMib = [int]$planned.DataMib
        Triplet = [int]$planned.Triplet; Position = [int]$planned.Position; Arm = $planned.Arm; Permutation = $planned.Permutation
        Valid = $false; InvalidReason = ''
        Passed = $null; ScheduledSteps = $null; CompletedSteps = $null; Failures = $null; Mismatches = $null; Overruns = $null
        P95LatencyMsMax = $null; TimeToFirstPageMsMax = $null; JsHeapLoadAvgMB = $null; Records = $null; RustDataMB = $null
        MonitorRows = $null; LoadRows = $null; LoadRowsExpected = $null; LoadCoverage = $null
        LoadIntervalMedianSeconds = $null; LoadIntervalMaxSeconds = $null; LoadProcessCountMin = $null; LoadProcessCountMax = $null
        TreeIdentity = $null; TransientProcesses = $null; RejectedPidReuseRows = $null
        LoadPrivateMBAvg = $null; LoadPrivateMBMaxSample = $null; SteadyPrivateMBAvg = $null; IdleBeforePrivateMBAvg = $null
        ExePrivateMBLoadAvg = $null; WebViewPrivateMBLoadAvg = $null; LoadCpuSeconds = $null; LoadWorkingSetMBUpperBound = $null
        RunCpuSeconds = $null; StartupCpuSeconds = $null; CpuExitedProcesses = $null; CpuProcesses = $null
        RunRows = $null; RunCoverage = $null; RunIntervalMaxSeconds = $null
        CpuSource = $null; MonitorRunCpuSeconds = $null; MonitorStartupCpuSeconds = $null; MonitorLoadCpuSeconds = $null; MonitorCpuNotes = ''
        JobProcesses = $null; JobProcessesNeverSeenByMonitor = $null; MonitorProcessesInJob = $null; JobEndGapSeconds = $null
        JobMaxRowIntervalSeconds = $null; JobMaxClockDriftSeconds = $null; JobNotes = ''
        MonitorCpuSeconds = $null
    }

    $log = $logs[$name]
    if ($null -eq $log) { $reasons.Add('no runs.log entry (not run)') }
    else {
        if ($null -eq (Get-Property $log 'exitCode') -or [int]$log.exitCode -ne 0) { $reasons.Add("app exit code '$(Get-Property $log 'exitCode')'") }
        if (Get-Property $log 'timedOut') { $reasons.Add('timed out') }
        if ($null -eq (Get-Property $log 'monitorExit') -or [int]$log.monitorExit -ne 0) { $reasons.Add("monitor exit code '$(Get-Property $log 'monitorExit')'") }
        $row.MonitorCpuSeconds = Get-Property $log 'monitorCpuSeconds'
    }

    $reportFile = Join-Path $runsDirectory "$name.json"
    $report = $null
    if (-not (Test-Path -LiteralPath $reportFile)) { $reasons.Add('no report') }
    else {
        try { $report = Get-Content -LiteralPath $reportFile -Raw | ConvertFrom-Json }
        catch { $reasons.Add("unreadable report: $($_.Exception.Message)") }
    }
    if ($null -ne $report -and $null -eq (Get-Property $report 'phases')) {
        $reasons.Add("report without phases: $(Get-Property $report 'configError')")
        $report = $null
    }
    if ($null -ne $report) {
        $row.Passed = [bool]$report.passed
        if (-not $row.Passed) { $reasons.Add('report not passed: ' + (@($report.problems) -join ' | ')) }
        if ([string]$report.config.arm -ne [string]$planned.Arm) { $reasons.Add("report arm $($report.config.arm) is not the scheduled $($planned.Arm)") }
        if ([int]$report.config.windows -ne [int]$planned.Windows -or [int]$report.config.dataMib -ne [int]$planned.DataMib) { $reasons.Add('report cell differs from schedule') }
        $row.ScheduledSteps = $report.totals.scheduledSteps
        $row.CompletedSteps = $report.totals.completedSteps
        $row.Failures = $report.totals.failures
        $row.Mismatches = $report.totals.mismatches
        $row.Overruns = $report.totals.overruns
        $row.P95LatencyMsMax = $report.totals.maxP95LatencyMs
        $row.TimeToFirstPageMsMax = $report.totals.maxTimeToFirstPageMs
        if ($null -ne $report.totals.loadJsHeapAvgBytes) { $row.JsHeapLoadAvgMB = [double]$report.totals.loadJsHeapAvgBytes / 1MB }
        $row.Records = $report.config.records
        $row.RustDataMB = [double]$report.config.rustDataBytes / 1MB

        $monitorFile = Join-Path $runsDirectory "$name.monitor.csv"
        if (-not (Test-Path -LiteralPath $monitorFile)) { $reasons.Add('no monitor CSV') }
        else {
            $monitorRows = @(Import-Csv -LiteralPath $monitorFile)
            $hasIdentity = $monitorRows.Count -gt 0 -and $null -ne $monitorRows[0].PSObject.Properties['ProcessKeys'] -and $null -ne $monitorRows[0].PSObject.Properties['UnverifiedProcessCount']
            $row.TreeIdentity = $hasIdentity
            $samples = @($monitorRows | ForEach-Object {
                    [pscustomobject]@{
                        Timestamp      = [string]$_.Timestamp
                        Time           = Get-Time $_.Timestamp
                        RootPid        = [int]$_.RootPid
                        Processes      = [int]$_.ProcessCount
                        WorkingSet     = ConvertTo-Number $_.WorkingSetMB
                        Private        = ConvertTo-Number $_.PrivateBytesMB
                        CpuDelta       = ConvertTo-Number $_.CpuDeltaSeconds
                        Sample         = [int]$_.Sample
                        Interval       = ConvertTo-Number $_.IntervalSeconds
                        PrivateMissing = ConvertTo-Number $_.PrivateMissingCount
                        CpuUnreadable  = ConvertTo-Number $_.CpuUnreadableCount
                        Keys           = if ($hasIdentity) { @(([string]$_.ProcessKeys).Split(';') | Where-Object { $_ -ne '' }) } else { @() }
                        Unverified     = if ($hasIdentity) { ConvertTo-Number $_.UnverifiedProcessCount } else { $null }
                        Rejected       = if ($hasIdentity) { ConvertTo-Number (Get-Property $_ 'RejectedPidReuseCount') } else { $null }
                        # Why CPU values are missing (monitor #43 167a67d and later): reason and PIDs.
                        CpuReasons     = @(foreach ($reason in 'ExitedUnread', 'AccessDenied', 'IdentityChanged', 'LeftTree', 'ReadError') { $ids = [string](Get-Property $_ "Cpu${reason}Ids"); if ($ids -ne '') { "${reason} $ids" } })
                    }
                })
            $row.MonitorRows = $samples.Count
            $loadFrom = Get-Time $report.phases.loadStartedAt
            $loadTo = Get-Time $report.phases.loadEndedAt
            $load = @(Select-Phase $samples $loadFrom $loadTo)
            $idleBefore = @(Select-Phase $samples (Get-Time $report.phases.idleBeforeStartedAt) (Get-Time $report.phases.warmupStartedAt))
            $idleAfter = @(Select-Phase $samples $loadTo (Get-Time $report.phases.endedAt))
            $row.LoadRows = $load.Count
            $row.LoadRowsExpected = [Math]::Floor(($loadTo - $loadFrom).TotalSeconds / $nominalInterval)
            $row.LoadCoverage = if ($row.LoadRowsExpected -gt 0) { $load.Count / $row.LoadRowsExpected } else { $null }
            $intervals = [double[]]@($load | Where-Object { $_.Sample -gt 0 -and $null -ne $_.Interval -and $_.Interval -gt 0 } | ForEach-Object { $_.Interval })
            $row.LoadIntervalMedianSeconds = Get-Median $intervals
            $row.LoadIntervalMaxSeconds = Get-Stat $intervals Maximum
            $counts = [double[]]@($load | ForEach-Object { $_.Processes })
            $row.LoadProcessCountMin = Get-Stat $counts Minimum
            $row.LoadProcessCountMax = Get-Stat $counts Maximum
            $privateComplete = { param($rows) $rows.Count -gt 0 -and @($rows | Where-Object { $null -eq $_.Private -or $null -eq $_.PrivateMissing -or $_.PrivateMissing -gt 0 }).Count -eq 0 }
            if (& $privateComplete $load) {
                $row.LoadPrivateMBAvg = Get-Stat ([double[]]@($load | ForEach-Object { $_.Private })) Average
                $row.LoadPrivateMBMaxSample = Get-Stat ([double[]]@($load | ForEach-Object { $_.Private })) Maximum
            }
            else { $reasons.Add('missing or non-finite private memory in the load phase') }
            if (& $privateComplete $idleAfter) { $row.SteadyPrivateMBAvg = Get-Stat ([double[]]@($idleAfter | ForEach-Object { $_.Private })) Average }
            if (& $privateComplete $idleBefore) { $row.IdleBeforePrivateMBAvg = Get-Stat ([double[]]@($idleBefore | ForEach-Object { $_.Private })) Average }
            if ($load.Count -gt 0 -and @($load | Where-Object { $null -eq $_.CpuDelta -or $null -eq $_.CpuUnreadable -or $_.CpuUnreadable -gt 0 }).Count -eq 0) {
                $row.LoadCpuSeconds = (@($load | ForEach-Object { $_.CpuDelta }) | Measure-Object -Sum).Sum
            }
            if ($load.Count -gt 0 -and @($load | Where-Object { $null -eq $_.WorkingSet }).Count -eq 0) {
                $row.LoadWorkingSetMBUpperBound = Get-Stat ([double[]]@($load | ForEach-Object { $_.WorkingSet })) Average
            }

            if ($null -eq $row.LoadCoverage -or $row.LoadCoverage -lt $minLoadCoverage) { $reasons.Add("load coverage $(Format-Number $row.LoadCoverage 2) < $minLoadCoverage") }
            if ($null -eq $row.LoadIntervalMedianSeconds -or [Math]::Abs($row.LoadIntervalMedianSeconds - $nominalInterval) -gt $maxIntervalDeviation * $nominalInterval) {
                $reasons.Add("median load interval $(Format-Number $row.LoadIntervalMedianSeconds 3) s not within $($maxIntervalDeviation * 100) % of $nominalInterval s")
            }
            if ($null -ne $row.LoadIntervalMaxSeconds -and $row.LoadIntervalMaxSeconds -gt $maxIntervalSeconds) { $reasons.Add("load gap $(Format-Number $row.LoadIntervalMaxSeconds 3) s > $maxIntervalSeconds s") }
            if ($hasIdentity) {
                $unverifiedRows = @($load | Where-Object { $null -eq $_.Unverified -or $_.Unverified -gt 0 }).Count
                if ($unverifiedRows -gt 0) { $reasons.Add("process tree not verified in $unverifiedRows load row(s) (unverified processes)") }
                $loadKeys = @($load | ForEach-Object { $_.Keys } | Sort-Object -Unique)
                $row.TransientProcesses = @($loadKeys | Where-Object { $key = $_; @($load | Where-Object { $_.Keys -notcontains $key }).Count -gt 0 }).Count
                $row.RejectedPidReuseRows = @($samples | Where-Object { $null -ne $_.Rejected -and $_.Rejected -gt 0 }).Count
            }
            elseif ($null -ne $row.LoadProcessCountMin -and $row.LoadProcessCountMin -ne $row.LoadProcessCountMax) {
                $reasons.Add("process count changed during load ($($row.LoadProcessCountMin)-$($row.LoadProcessCountMax))")
            }

            # Host vs WebView2 split, per-process detail and whole-run CPU, from the monitor's diagnostics.
            $diagnosticsFile = Join-Path $runsDirectory "$name.monitor.diagnostics.csv"
            $monitorKeys = @()
            $runEnd = Get-Time $report.phases.endedAt
            $runSamples = @($samples | Where-Object { $_.Time -le $runEnd })
            $row.RunRows = $runSamples.Count
            if ($runSamples.Count -gt 0) {
                $runSpan = ($runEnd - $runSamples[0].Time).TotalSeconds
                $row.RunCoverage = if ($runSpan -gt 0) { $runSamples.Count / [Math]::Floor($runSpan / $nominalInterval + 1) } else { $null }
                $runIntervals = [double[]]@($runSamples | Where-Object { $_.Sample -gt 0 -and $null -ne $_.Interval -and $_.Interval -gt 0 } | ForEach-Object { $_.Interval })
                $row.RunIntervalMaxSeconds = Get-Stat $runIntervals Maximum
            }
            $cpuReasons = New-Object System.Collections.Generic.List[string]
            if ($runSamples.Count -eq 0) { $cpuReasons.Add('no monitor sample before the end of the run') }
            else {
                if ($runSamples[0].Time -gt (Get-Time $report.phases.idleBeforeStartedAt)) { $cpuReasons.Add('first monitor sample after the idle-before phase started') }
                $unreadableRows = @($runSamples | Where-Object { $null -eq $_.CpuUnreadable -or $_.CpuUnreadable -gt 0 })
                if ($unreadableRows.Count -gt 0) {
                    $why = @($unreadableRows | ForEach-Object { $_.CpuReasons } | Sort-Object -Unique)
                    $cpuReasons.Add('unreadable CPU in a monitor row' + $(if ($why.Count -gt 0) { " ($($why -join '; '))" } else { '' }))
                }
                if ($hasIdentity -and @($runSamples | Where-Object { $null -eq $_.Unverified -or $_.Unverified -gt 0 }).Count -gt 0) { $cpuReasons.Add('unverified processes in a monitor row') }
                if ($null -eq $row.RunCoverage -or $row.RunCoverage -lt $minLoadCoverage) { $cpuReasons.Add("coverage $(Format-Number $row.RunCoverage 2) < $minLoadCoverage") }
                if ($null -ne $row.RunIntervalMaxSeconds -and $row.RunIntervalMaxSeconds -gt $maxIntervalSeconds) { $cpuReasons.Add("gap $(Format-Number $row.RunIntervalMaxSeconds 3) s > $maxIntervalSeconds s") }
            }
            if (-not (Test-Path -LiteralPath $diagnosticsFile)) { $cpuReasons.Add('no monitor diagnostics CSV') }
            if ((Test-Path -LiteralPath $diagnosticsFile) -and $samples.Count -gt 0) {
                $rootPid = $samples[0].RootPid
                $allDiagnostics = @(Import-Csv -LiteralPath $diagnosticsFile)
                if ($hasIdentity) {
                    $runStart = $samples[0].Time
                    $outside = @($allDiagnostics | Where-Object { $_.InTree -ne 'True' } | Where-Object { $time = Get-Time $_.Timestamp; $time -ge $runStart -and $time -le $runEnd } | ForEach-Object { $_.Pid } | Sort-Object -Unique)
                    if ($outside.Count -gt 0) { $reasons.Add("WebView2 process(es) of the app outside the monitored tree: $($outside -join ', ')") }
                }
                # Processes are told apart by identity (PID and creation time) when the monitor records it, else by PID.
                $diagnosticRows = @($allDiagnostics | Where-Object { $_.InTree -eq 'True' } | ForEach-Object {
                        $identity = Get-Property $_ 'ProcessKey'
                        if ([string]::IsNullOrEmpty([string]$identity)) { $identity = [string]$_.Pid }
                        [pscustomobject]@{ Row = $_; Time = Get-Time $_.Timestamp; Pid = [int]$_.Pid; Identity = $identity; Cpu = ConvertTo-Number (Get-Property $_ 'ProcTotalProcessorSeconds') }
                    })
                if ($hasIdentity) { $monitorKeys = @($diagnosticRows | ForEach-Object { [string]$_.Identity } | Sort-Object -Unique) }
                $runDiagnostics = @($diagnosticRows | Where-Object { $_.Time -le $runEnd })
                if (@($runDiagnostics | Where-Object { $null -eq $_.Cpu }).Count -gt 0) { $cpuReasons.Add('missing cumulative CPU in a diagnostics row') }
                elseif ($runDiagnostics.Count -gt 0 -and $runSamples.Count -gt 0) {
                    $lastSampleTime = $runSamples[$runSamples.Count - 1].Time
                    $warmupFrom = Get-Time $report.phases.warmupStartedAt
                    $runCpu = 0.0; $startupCpu = 0.0; $exited = 0; $cpuProcesses = 0
                    foreach ($group in ($runDiagnostics | Group-Object Identity)) {
                        $ordered = @($group.Group | Sort-Object Time)
                        $last = $ordered[$ordered.Count - 1]
                        $runCpu += $last.Cpu
                        $cpuProcesses++
                        if ($last.Time -lt $lastSampleTime) { $exited++ }
                        $beforeWarmup = @($ordered | Where-Object { $_.Time -le $warmupFrom })
                        if ($beforeWarmup.Count -gt 0) { $startupCpu += $beforeWarmup[$beforeWarmup.Count - 1].Cpu }
                    }
                    $row.RunCpuSeconds = $runCpu
                    $row.StartupCpuSeconds = $startupCpu
                    $row.CpuExitedProcesses = $exited
                    $row.CpuProcesses = $cpuProcesses
                }
                $diagnosticLoadRows = @($diagnosticRows | Where-Object { $_.Time -ge $loadFrom -and $_.Time -lt $loadTo } | ForEach-Object { $_.Row })
                foreach ($group in ($diagnosticLoadRows | Group-Object Pid)) {
                    $values = [double[]]@($group.Group | ForEach-Object { ConvertTo-Number $_.CimPrivatePageCount } | Where-Object { $null -ne $_ })
                    $first = $group.Group[0]
                    $processName = Get-Property $first 'Name'
                    if ($null -eq $processName) { $processName = Get-Property $first 'ProcessName' }
                    $processes.Add([pscustomobject][ordered]@{
                            Name = $name; Cell = $planned.Cell; Arm = $planned.Arm; Triplet = [int]$planned.Triplet; Pid = [int]$group.Name
                            ProcessName = $processName; Host = ([int]$group.Name -eq $rootPid); LoadRows = $group.Count
                            PrivateMBLoadAvg = if ($values.Count -gt 0) { (Get-Stat $values Average) / 1MB } else { $null }
                        })
                }
                $rootValues = [double[]]@($diagnosticLoadRows | Where-Object { [int]$_.Pid -eq $rootPid } | ForEach-Object { ConvertTo-Number $_.CimPrivatePageCount } | Where-Object { $null -ne $_ })
                if ($rootValues.Count -gt 0 -and $rootValues.Count -eq $load.Count) {
                    $row.ExePrivateMBLoadAvg = (Get-Stat $rootValues Average) / 1MB
                    if ($null -ne $row.LoadPrivateMBAvg) { $row.WebViewPrivateMBLoadAvg = $row.LoadPrivateMBAvg - $row.ExePrivateMBLoadAvg }
                }
            }
            if ($cpuReasons.Count -eq 0 -and $null -eq $row.RunCpuSeconds) { $cpuReasons.Add('no cumulative CPU value') }
            if ($cpuSource -eq 'job') {
                # Protocol §7 (revision with job CPU): whole-run CPU from the run's Job Object. The
                # monitor's CPU values stay as a diagnostic; its reasons for a missing CPU value
                # (ExitedUnread etc.) no longer decide CPU validity, because the job counts every
                # process of the tree. RAM keeps its own checks above, unchanged.
                $row.CpuSource = 'job'
                $row.MonitorRunCpuSeconds = $row.RunCpuSeconds
                $row.MonitorStartupCpuSeconds = $row.StartupCpuSeconds
                $row.MonitorLoadCpuSeconds = $row.LoadCpuSeconds
                $row.MonitorCpuNotes = $cpuReasons -join '; '
                $row.RunCpuSeconds = $null; $row.StartupCpuSeconds = $null; $row.LoadCpuSeconds = $null
                $jobProblems = New-Object System.Collections.Generic.List[string]
                if ($null -ne $log) {
                    if ($null -ne (Get-Property $log 'jobError')) { $jobProblems.Add("runner: $($log.jobError)") }
                    if ([bool](Get-Property $log 'jobTerminated')) { $jobProblems.Add("the runner terminated the job ($(Get-Property $log 'jobLeftoverProcesses') process(es) left after the app exited, or a timeout)") }
                }
                if (-not $hasIdentity) { $jobProblems.Add('the monitor records no process identities; membership not verified') }
                # The full set of job artifacts is required; a missing one is never replaced by the monitor.
                $jobFile = Join-Path $runsDirectory "$name.job.csv"
                $messagesFile = Join-Path $runsDirectory "$name.job.messages.csv"
                $missing = @(@($jobFile, $messagesFile) | Where-Object { -not (Test-Path -LiteralPath $_) } | ForEach-Object { Split-Path -Leaf $_ })
                if ($missing.Count -gt 0) { $jobProblems.Add("missing job artifact(s): $($missing -join ', ')") }
                else {
                    $job = Get-CatalogJobCpu -Rows @(Import-Csv -LiteralPath $jobFile) -Messages @(Import-Csv -LiteralPath $messagesFile) -Phases $report.phases -MonitorKeys $monitorKeys
                    foreach ($problem in $job.Problems) { $jobProblems.Add($problem) }
                    $row.JobProcesses = $job.JobProcesses
                    $row.JobProcessesNeverSeenByMonitor = $job.JobProcessesNeverSeenByMonitor
                    $row.MonitorProcessesInJob = $job.MonitorProcessesInJob
                    $row.JobEndGapSeconds = $job.EndGapSeconds
                    $row.JobMaxRowIntervalSeconds = $job.MaxRowIntervalSeconds
                    $row.JobMaxClockDriftSeconds = $job.MaxClockDriftSeconds
                    $row.JobNotes = @($job.Notes) -join '; '
                }
                if ($jobProblems.Count -eq 0) {
                    $row.RunCpuSeconds = $job.RunCpuSeconds
                    $row.StartupCpuSeconds = $job.StartupCpuSeconds
                    $row.LoadCpuSeconds = $job.LoadCpuSeconds
                }
                foreach ($problem in $jobProblems) { $reasons.Add("whole-run CPU (job): $problem") }
            }
            else {
                # Legacy results without cpuSource (smokes 1 to 3): the monitor rule, unchanged.
                $row.CpuSource = 'legacy-monitor'
                foreach ($reason in $cpuReasons) { $reasons.Add("whole-run CPU: $reason") }
            }
        }
    }
    $row.Valid = $reasons.Count -eq 0
    $row.InvalidReason = $reasons -join '; '
    $runs.Add([pscustomobject]$row)
}

# Differences inside each triplet, valid runs only.
$triplets = New-Object System.Collections.Generic.List[object]
foreach ($group in ($runs | Group-Object Cell, Triplet)) {
    $byArm = @{}
    foreach ($run in $group.Group) { $byArm[[string]$run.Arm] = $run }
    $first = @($group.Group | Sort-Object Position)[0]
    foreach ($pair in $comparisons) {
        $x = $byArm[$pair[0]]; $y = $byArm[$pair[1]]
        if ($null -eq $x -or $null -eq $y) { continue }
        $valid = $x.Valid -and $y.Valid
        $triplets.Add([pscustomobject][ordered]@{
                Cell = $first.Cell; Triplet = $first.Triplet; Permutation = $first.Permutation; FirstArm = $first.Arm
                Comparison = "$($pair[0])-$($pair[1])"; Valid = $valid
                InvalidReason = (@($x, $y) | Where-Object { -not $_.Valid } | ForEach-Object { "$($_.Arm): $($_.InvalidReason)" }) -join ' | '
                LoadPrivateMBDiff = if ($valid) { $x.LoadPrivateMBAvg - $y.LoadPrivateMBAvg } else { $null }
                ExePrivateMBDiff = if ($valid -and $null -ne $x.ExePrivateMBLoadAvg -and $null -ne $y.ExePrivateMBLoadAvg) { $x.ExePrivateMBLoadAvg - $y.ExePrivateMBLoadAvg } else { $null }
                WebViewPrivateMBDiff = if ($valid -and $null -ne $x.WebViewPrivateMBLoadAvg -and $null -ne $y.WebViewPrivateMBLoadAvg) { $x.WebViewPrivateMBLoadAvg - $y.WebViewPrivateMBLoadAvg } else { $null }
                RunCpuSecondsDiff = if ($valid) { $x.RunCpuSeconds - $y.RunCpuSeconds } else { $null }
                StartupCpuSecondsDiff = if ($valid -and $null -ne $x.StartupCpuSeconds -and $null -ne $y.StartupCpuSeconds) { $x.StartupCpuSeconds - $y.StartupCpuSeconds } else { $null }
                LoadCpuSecondsDiff = if ($valid -and $null -ne $x.LoadCpuSeconds -and $null -ne $y.LoadCpuSeconds) { $x.LoadCpuSeconds - $y.LoadCpuSeconds } else { $null }
            })
    }
}

# Descriptive statistics per cell and arm, and per cell and comparison.
$measures = @('LoadPrivateMBAvg', 'RunCpuSeconds', 'StartupCpuSeconds', 'ExePrivateMBLoadAvg', 'WebViewPrivateMBLoadAvg', 'SteadyPrivateMBAvg', 'LoadPrivateMBMaxSample', 'LoadCpuSeconds', 'CpuExitedProcesses', 'P95LatencyMsMax', 'TimeToFirstPageMsMax', 'JsHeapLoadAvgMB', 'RustDataMB')
$summary = New-Object System.Collections.Generic.List[object]
foreach ($group in ($runs | Group-Object Cell, Arm)) {
    $valid = @($group.Group | Where-Object { $_.Valid })
    foreach ($measure in $measures) {
        $values = [double[]]@($valid | ForEach-Object { $_.$measure } | Where-Object { $null -ne $_ })
        $summary.Add([pscustomobject][ordered]@{
                Cell = $group.Group[0].Cell; Group = "arm $($group.Group[0].Arm)"; Measure = $measure; Runs = $group.Count; ValidRuns = $valid.Count; N = $values.Count
                Median = Get-Median $values; Min = Get-Stat $values Minimum; Max = Get-Stat $values Maximum
            })
    }
}
foreach ($group in ($triplets | Group-Object Cell, Comparison)) {
    $valid = @($group.Group | Where-Object { $_.Valid })
    foreach ($measure in @('LoadPrivateMBDiff', 'RunCpuSecondsDiff', 'StartupCpuSecondsDiff', 'ExePrivateMBDiff', 'WebViewPrivateMBDiff', 'LoadCpuSecondsDiff')) {
        $values = [double[]]@($valid | ForEach-Object { $_.$measure } | Where-Object { $null -ne $_ })
        $summary.Add([pscustomobject][ordered]@{
                Cell = $group.Group[0].Cell; Group = $group.Group[0].Comparison; Measure = $measure; Runs = $group.Count; ValidRuns = $valid.Count; N = $values.Count
                Median = Get-Median $values; Min = Get-Stat $values Minimum; Max = Get-Stat $values Maximum
            })
    }
}

function Export-Rows {
    param([object[]]$Rows, [string]$File)
    $Rows | ForEach-Object {
        $out = [ordered]@{}
        foreach ($property in $_.PSObject.Properties) { $out[$property.Name] = Format-Raw $property.Value }
        [pscustomobject]$out
    } | Export-Csv -LiteralPath (Join-Path $OutputDirectory $File) -NoTypeInformation -Encoding UTF8
}
$signResults = if ($checked) { Get-CatalogCheckedSignResults -CheckedInputs $checked -PairRows $triplets.ToArray() }
New-Item -ItemType Directory -Path $OutputDirectory -ErrorAction Stop | Out-Null
Export-Rows $runs.ToArray() 'runs.csv'
Export-Rows $triplets.ToArray() 'triplets.csv'
Export-Rows $summary.ToArray() 'summary.csv'
Export-Rows @(Get-GuardrailRows -Runs $runs.ToArray()) 'guardrail-evidence.csv'
if ($processes.Count -gt 0) { Export-Rows $processes.ToArray() 'processes.csv' }
if ($checked) {
    $signResults | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'sign-evidence.json') -Encoding UTF8
}

# Retained size check (protocol §4): host Private above the D0 cell with the same windows, against the generator's size.
$retained = New-Object System.Collections.Generic.List[string]
foreach ($group in ($runs | Where-Object { $_.Valid -and $_.DataMib -gt 0 } | Group-Object Cell, Arm)) {
    $sample = $group.Group[0]
    $control = @($runs | Where-Object { $_.Valid -and $_.DataMib -eq 0 -and $_.Windows -eq $sample.Windows -and $_.Arm -eq $sample.Arm })
    $hostNow = Get-Median ([double[]]@($group.Group | ForEach-Object { $_.ExePrivateMBLoadAvg } | Where-Object { $null -ne $_ }))
    $hostControl = Get-Median ([double[]]@($control | ForEach-Object { $_.ExePrivateMBLoadAvg } | Where-Object { $null -ne $_ }))
    $webNow = Get-Median ([double[]]@($group.Group | ForEach-Object { $_.WebViewPrivateMBLoadAvg } | Where-Object { $null -ne $_ }))
    $webControl = Get-Median ([double[]]@($control | ForEach-Object { $_.WebViewPrivateMBLoadAvg } | Where-Object { $null -ne $_ }))
    $rust = Get-Median ([double[]]@($group.Group | ForEach-Object { $_.RustDataMB }))
    $heap = Get-Median ([double[]]@($group.Group | ForEach-Object { $_.JsHeapLoadAvgMB } | Where-Object { $null -ne $_ }))
    $hostDelta = if ($null -ne $hostNow -and $null -ne $hostControl) { $hostNow - $hostControl } else { $null }
    $webDelta = if ($null -ne $webNow -and $null -ne $webControl) { $webNow - $webControl } else { $null }
    $retained.Add(("| {0} | {1} | {2} | {3} | {4} | {5} | {6} |" -f $sample.Cell, $sample.Arm, $sample.DataMib, (Format-Number $rust), (Format-Number $hostDelta), (Format-Number $webDelta), (Format-Number $heap)))
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# Scenario M: $($configuration.phase) summary")
$lines.Add('')
$lines.Add("**$($configuration.phase): descriptive, no conclusion.** Platform: $($configuration.os) on $($configuration.machine); every statement is for this platform only.")
if ($checked) {
    $lines.Add('')
    $lines.Add("Frozen manifest SHA-256: $($checked.ManifestSha256)")
    $lines.Add("Frozen thresholds SHA-256: $($checked.ThresholdsSha256)")
    $lines.Add('Frozen sign-test evidence is in sign-evidence.json. Claim decisions are pending.')
}
$lines.Add('')
$lines.Add('Individual guardrail measures and limits are in guardrail-evidence.csv when B or C was scheduled.')
$lines.Add('')
$lines.Add("Git $($configuration.gitHead)$(if ($configuration.gitDirty) { ' (dirty)' }); arms $(@($configuration.arms) -join ', '); cells $(@($configuration.cells) -join ', '); $($configuration.triplets) triplets; schedule seed $($configuration.scheduleSeed).")
$lines.Add('')
$lines.Add('Co-primary measures: LoadPrivateMBAvg (RAM) = time average over the load phase of the sum of Private Bytes over the host and every WebView2 process; RunCpuSeconds (CPU) = CPU time of the whole tree from process start to the end of the idle-after phase, from the run''s Job Object where the runner recorded one (runs.csv CpuSource), else from the monitor. Working Set is a diagnostic upper bound only.')
$lines.Add('')
$lines.Add("Runs: $($runs.Count), valid: $(@($runs | Where-Object { $_.Valid }).Count).")
$lines.Add('')
$lines.Add('## Per cell and arm (valid runs; median [min, max])')
$lines.Add('')
$lines.Add('| Cell | Arm | Valid | Σ Private MB | Run CPU s | Startup CPU s | Host MB | WebView2 MB | Steady MB | Load CPU s | p95 ms | First page ms | JS heap MB |')
$lines.Add('|---|---|---|---|---|---|---|---|---|---|---|---|---|')
function Format-Range {
    param([string]$Cell, [string]$Group, [string]$Measure, [int]$Digits = 1)
    $item = @($summary | Where-Object { $_.Cell -eq $Cell -and $_.Group -eq $Group -and $_.Measure -eq $Measure })
    if ($item.Count -eq 0 -or $item[0].N -eq 0) { return '' }
    return "{0} [{1}, {2}]" -f (Format-Number $item[0].Median $Digits), (Format-Number $item[0].Min $Digits), (Format-Number $item[0].Max $Digits)
}
foreach ($group in ($runs | Group-Object Cell, Arm)) {
    $cell = $group.Group[0].Cell; $armGroup = "arm $($group.Group[0].Arm)"
    $validCount = @($group.Group | Where-Object { $_.Valid }).Count
    $lines.Add(("| {0} | {1} | {2}/{3} | {4} | {5} | {6} | {7} | {8} | {9} | {10} | {11} | {12} | {13} |" -f $cell, $group.Group[0].Arm, $validCount, $group.Count,
            (Format-Range $cell $armGroup 'LoadPrivateMBAvg'), (Format-Range $cell $armGroup 'RunCpuSeconds' 2), (Format-Range $cell $armGroup 'StartupCpuSeconds' 2), (Format-Range $cell $armGroup 'ExePrivateMBLoadAvg'), (Format-Range $cell $armGroup 'WebViewPrivateMBLoadAvg'),
            (Format-Range $cell $armGroup 'SteadyPrivateMBAvg'), (Format-Range $cell $armGroup 'LoadCpuSeconds' 2), (Format-Range $cell $armGroup 'P95LatencyMsMax'),
            (Format-Range $cell $armGroup 'TimeToFirstPageMsMax' 0), (Format-Range $cell $armGroup 'JsHeapLoadAvgMB')))
}
$lines.Add('')
$lines.Add('## Differences inside triplets (valid pairs; median [min, max])')
$lines.Add('')
$lines.Add('C vs A is the product comparison; C vs B is the framework cost. One is never read as the other.')
$lines.Add('')
$lines.Add('| Cell | Comparison | Pairs | Σ Private MB | Run CPU s | Host MB | WebView2 MB | Load CPU s |')
$lines.Add('|---|---|---|---|---|---|---|---|')
foreach ($group in ($triplets | Group-Object Cell, Comparison)) {
    $cell = $group.Group[0].Cell; $comparison = $group.Group[0].Comparison
    $lines.Add(("| {0} | {1} | {2}/{3} | {4} | {5} | {6} | {7} | {8} |" -f $cell, $comparison, @($group.Group | Where-Object { $_.Valid }).Count, $group.Count,
            (Format-Range $cell $comparison 'LoadPrivateMBDiff'), (Format-Range $cell $comparison 'RunCpuSecondsDiff' 2), (Format-Range $cell $comparison 'ExePrivateMBDiff'), (Format-Range $cell $comparison 'WebViewPrivateMBDiff'),
            (Format-Range $cell $comparison 'LoadCpuSecondsDiff' 2)))
}
$lines.Add('')
$lines.Add('## RAM and CPU correlation within triplets')
$lines.Add('')
$lines.Add('Pearson correlation of the paired RAM and CPU differences, by cell and comparison. Undefined with fewer than two valid pairs or a constant outcome.')
$lines.Add('')
$lines.Add('| Cell | Comparison | Valid pairs | Pearson r |')
$lines.Add('|---|---|---|---|')
foreach ($group in ($triplets | Group-Object Cell, Comparison)) {
    $valid = @($group.Group | Where-Object Valid)
    $correlation = Get-CatalogPairCorrelation -ValidPairs $valid
    $display = if ($null -eq $correlation) { 'n/a' } else { Format-Number $correlation 3 }
    $lines.Add(("| {0} | {1} | {2} | {3} |" -f $group.Group[0].Cell, $group.Group[0].Comparison, $valid.Count, $display))
}
$lines.Add('')
$lines.Add('## Position effect (differences by the arm that ran first)')
$lines.Add('')
$lines.Add('| Cell | Comparison | First arm | Pairs | Σ Private MB median | Run CPU s median |')
$lines.Add('|---|---|---|---|---|---|')
foreach ($group in ($triplets | Where-Object { $_.Valid } | Group-Object Cell, Comparison, FirstArm)) {
    $values = [double[]]@($group.Group | ForEach-Object { $_.LoadPrivateMBDiff })
    $cpuValues = [double[]]@($group.Group | ForEach-Object { $_.RunCpuSecondsDiff })
    $lines.Add(("| {0} | {1} | {2} | {3} | {4} | {5} |" -f $group.Group[0].Cell, $group.Group[0].Comparison, $group.Group[0].FirstArm, $group.Count, (Format-Number (Get-Median $values)), (Format-Number (Get-Median $cpuValues) 2)))
}
$lines.Add('')
$lines.Add('## Retained size (protocol §4)')
$lines.Add('')
$lines.Add('Host and WebView2 Private above the D0 cell with the same windows and arm (medians), against the generator size of the Rust representation and the JS heap of all windows.')
$lines.Add('')
$lines.Add('| Cell | Arm | Nominal MiB | Generator MB | Host above D0 MB | WebView2 above D0 MB | JS heap MB |')
$lines.Add('|---|---|---|---|---|---|---|')
foreach ($line in $retained) { $lines.Add($line) }
$lines.Add('')
$lines.Add('## Invalid runs')
$lines.Add('')
$invalid = @($runs | Where-Object { -not $_.Valid })
if ($invalid.Count -eq 0) { $lines.Add('None.') }
foreach ($run in $invalid) { $lines.Add("- $($run.Name): $($run.InvalidReason)") }
$lines | Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.md') -Encoding UTF8

Write-Host "Summary: $(Join-Path $OutputDirectory 'summary.md')"
