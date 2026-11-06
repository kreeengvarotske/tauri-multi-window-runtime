[CmdletBinding(DefaultParameterSetName = 'ByName')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'ByPid')]
    [int]$RootPid,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByName')]
    [string]$ProcessName,

    [ValidateRange(1, 3600)]
    [int]$DurationSeconds = 300,

    # The default remains 1 second. For peak-RAM profiling, 0.1–0.25 s
    # can improve visibility, but increases sampler overhead; inspect IntervalSeconds.
    [ValidateRange(0.1, 60.0)]
    [double]$SampleIntervalSeconds = 1,

    [string]$OutputPath = (Join-Path (Get-Location) ("process-tree-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))),

    # Also writes one row per process per sample, comparing memory sources and
    # listing WebView2 processes of this app that the tree walk did not reach.
    [switch]$Diagnostics,

    [string]$DiagnosticsPath,

    # How long the startup unit check may wait for processes whose private
    # memory is stable between two samples (see "Unit check" in README.md).
    # Nothing is written to OutputPath before the check passes.
    [ValidateRange(1, 600)]
    [int]$UnitCheckTimeoutSeconds = 30,

    [string]$UnitCheckPath,

    # When set (the catalog Scenario M passes msedgewebview2.exe), the unit
    # check also waits for a stable child process of this name, so it cannot
    # pass on the root process alone. Without it, any stable process counts.
    [string]$UnitCheckRequireChildName
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'PrivateUnitValidation.psm1') -Force
Import-Module -Name (Join-Path $PSScriptRoot 'ProcessTreeIdentity.psm1') -Force
Import-Module -Name (Join-Path $PSScriptRoot 'ProcessCpuTracker.psm1') -Force

function Get-ProcessSnapshot {
    param([bool]$IncludeDiagnostics = $false)
    # CIM exposes parent PIDs and memory totals and is available in Windows PowerShell 5.1.
    # PrivatePageCount is in bytes despite its name: on Windows 10 22H2 (19045)
    # it equalled Get-Process PrivateMemorySize64 and PageFileUsage * 1024 for
    # every sampled process (issue #13, stage 8). The script re-checks this at
    # startup instead of relying on it.
    # CreationDate makes PID + creation time the identity of a process, so a
    # reused PID is not taken for the process that had it before.
    $properties = @('ProcessId', 'ParentProcessId', 'Name', 'CreationDate', 'WorkingSetSize', 'PrivatePageCount')
    if ($IncludeDiagnostics) {
        $properties += @('PageFileUsage', 'CommandLine')
    }
    Get-CimInstance -ClassName Win32_Process -Property $properties
}

function Resolve-RootPid {
    param(
        [object[]]$Snapshot,
        [bool]$UsePid,
        [int]$RequestedPid,
        [string]$RequestedProcessName
    )

    if ($UsePid) {
        $requested = $Snapshot | Where-Object { [int]$_.ProcessId -eq $RequestedPid } | Select-Object -First 1
        if ($null -eq $requested) {
            throw "Process PID $RequestedPid was not found. Start the application and try again."
        }
        return $RequestedPid
    }

    $needle = [System.IO.Path]::GetFileNameWithoutExtension($RequestedProcessName)
    $matches = @($Snapshot | Where-Object {
        [System.IO.Path]::GetFileNameWithoutExtension([string]$_.Name) -ieq $needle
    })

    if ($matches.Count -eq 0) {
        throw "Process '$RequestedProcessName' was not found. Start the application and check the executable name."
    }
    if ($matches.Count -gt 1) {
        $lines = $matches | ForEach-Object { "  PID=$($_.ProcessId)  Name=$($_.Name)" }
        throw "Multiple processes named '$RequestedProcessName' were found. Specify a PID with -RootPid:`n$($lines -join "`n")"
    }
    return [int]$matches[0].ProcessId
}

function Get-ProcessOrNull {
    # The Get-Process object of a snapshot record, or $null when the process
    # has exited, cannot be read, or its PID now belongs to another process.
    # Used for PrivateMemorySize64 and for processes outside the tree; CPU
    # time of the tree comes from ProcessCpuTracker.psm1.
    param([object]$ProcessInfo)
    try {
        $process = Get-Process -Id ([int]$ProcessInfo.ProcessId) -ErrorAction Stop
    }
    catch {
        return $null
    }
    if (-not (Test-SameProcess -ProcessInfo $ProcessInfo -Process $process)) {
        return $null
    }
    return $process
}

function Write-CsvRows {
    param([string]$Path, [object[]]$Rows, [bool]$Append)
    if ($Rows.Count -eq 0) { return }
    if ($Append) {
        $Rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8 -Append
    }
    else {
        $Rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
    }
}

function Get-CpuSeconds {
    param([AllowNull()][object]$Process)
    if ($null -eq $Process) {
        return $null
    }
    try {
        # User plus kernel time since the process started.
        return [double]$Process.TotalProcessorTime.TotalSeconds
    }
    catch {
        return $null
    }
}

function Get-Median {
    param([double[]]$Values)
    if ($Values.Count -eq 0) {
        return $null
    }
    $sorted = @($Values | Sort-Object)
    $middle = [int][Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) {
        return [double]$sorted[$middle]
    }
    return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2.0
}

function Get-PrivateUnitRatio {
    # Ratio of CIM PrivatePageCount to Get-Process PrivateMemorySize64 for one
    # process; 1 when PrivatePageCount is in bytes, 1/4096 if it were pages.
    param(
        [object]$ProcessInfo,
        [AllowNull()][object]$Process
    )
    if ($null -eq $Process -or $null -eq $ProcessInfo.PrivatePageCount) {
        return $null
    }
    $privateMemory = [double]$Process.PrivateMemorySize64
    if ($privateMemory -le 0) {
        return $null
    }
    return [double]$ProcessInfo.PrivatePageCount / $privateMemory
}

function New-DiagnosticRow {
    param(
        [string]$Timestamp,
        [int]$Sample,
        [object]$ProcessInfo,
        [AllowNull()][object]$Process,
        [bool]$InTree,
        [AllowNull()][object]$Ratio,
        [AllowNull()][object]$CpuSeconds,
        [string]$CpuState
    )
    [pscustomobject]@{
        Timestamp                  = $Timestamp
        Sample                     = $Sample
        Pid                        = [int]$ProcessInfo.ProcessId
        ProcessKey                 = Get-ProcessKey -ProcessInfo $ProcessInfo
        ParentPid                  = [int]$ProcessInfo.ParentProcessId
        Name                       = [string]$ProcessInfo.Name
        InTree                     = $InTree
        CimWorkingSetSize          = $ProcessInfo.WorkingSetSize
        CimPrivatePageCount        = $ProcessInfo.PrivatePageCount
        CimPageFileUsageKB         = $ProcessInfo.PageFileUsage
        ProcPrivateMemorySize64    = if ($null -ne $Process) { $Process.PrivateMemorySize64 } else { $null }
        ProcWorkingSet64           = if ($null -ne $Process) { $Process.WorkingSet64 } else { $null }
        ProcTotalProcessorSeconds  = Format-InvariantDecimal -Value $CpuSeconds -DecimalPlaces 4
        RatioPrivatePageCountToPrivateMemorySize64 = Format-InvariantDecimal -Value $Ratio -DecimalPlaces 6
        # Running or Exited (final CPU through a held handle), or why the CPU
        # time is missing: ExitedUnread, AccessDenied, IdentityChanged,
        # LeftTree, ReadError. Get-Process for processes outside the tree.
        CpuState                   = $CpuState
    }
}

function Format-InvariantDecimal {
    param(
        [AllowNull()]
        [object]$Value,
        [int]$DecimalPlaces = 2
    )

    if ($null -eq $Value) {
        return $null
    }

    return ([double]$Value).ToString(("F{0}" -f $DecimalPlaces), [System.Globalization.CultureInfo]::InvariantCulture)
}

# Ensure the output directory exists.
$resolvedOutput = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = [System.IO.Path]::GetDirectoryName($resolvedOutput)
if (-not [System.IO.Directory]::Exists($outputDirectory)) {
    [void][System.IO.Directory]::CreateDirectory($outputDirectory)
}

$firstSnapshot = @(Get-ProcessSnapshot)
$isPidMode = $PSCmdlet.ParameterSetName -eq 'ByPid'
$resolvedRootPid = Resolve-RootPid -Snapshot $firstSnapshot -UsePid $isPidMode -RequestedPid $RootPid -RequestedProcessName $ProcessName
$rootRecord = $firstSnapshot | Where-Object { [int]$_.ProcessId -eq $resolvedRootPid } | Select-Object -First 1
$rootKey = Get-ProcessKey -ProcessInfo $rootRecord
if ($null -eq $rootKey) {
    throw "The creation time of PID $resolvedRootPid cannot be read, so its child processes cannot be told apart from processes that reuse a PID. Refusing to measure."
}
$logicalCpuCount = [Environment]::ProcessorCount

if ([string]::IsNullOrWhiteSpace($UnitCheckPath)) {
    $UnitCheckPath = [System.IO.Path]::ChangeExtension($resolvedOutput, '.unitcheck.csv')
}
$unitCheckOutput = [System.IO.Path]::GetFullPath($UnitCheckPath)

$diagnosticsOutput = $null
$rootExecutable = [string]$rootRecord.Name
$diagnosticRatios = New-Object System.Collections.Generic.List[double]
$missedWebViewPids = New-Object 'System.Collections.Generic.HashSet[int]'
if ($Diagnostics) {
    if ([string]::IsNullOrWhiteSpace($DiagnosticsPath)) {
        $DiagnosticsPath = [System.IO.Path]::ChangeExtension($resolvedOutput, '.diagnostics.csv')
    }
    $diagnosticsOutput = [System.IO.Path]::GetFullPath($DiagnosticsPath)
}

Write-Host "Measuring process: $($rootRecord.Name), PID=$resolvedRootPid, identity $rootKey"
Write-Host "Duration: $DurationSeconds seconds; interval: $SampleIntervalSeconds seconds"
Write-Host "CSV: $resolvedOutput"
if ($null -ne $diagnosticsOutput) {
    Write-Host "Diagnostics CSV: $diagnosticsOutput"
}
Write-Host "Unit check CSV: $unitCheckOutput (rows are held in memory until the unit check passes, at most $UnitCheckTimeoutSeconds s)"
if (-not [string]::IsNullOrEmpty($UnitCheckRequireChildName)) {
    Write-Host "Unit check waits for a stable child process named $UnitCheckRequireChildName."
}
Write-Host ("CpuPercentAllCores is normalized to total capacity of all logical CPUs (0 to 100%). This system has {0} logical CPUs, so one fully utilized core is about {1}%." -f $logicalCpuCount, (Format-InvariantDecimal -Value (100.0 / $logicalCpuCount) -DecimalPlaces 2))
Write-Host "Stop: Ctrl+C"

$watch = [System.Diagnostics.Stopwatch]::StartNew()
$previousSampleTime = $watch.Elapsed.TotalSeconds
$sampleNumber = 0
# PrivateBytesMB sums PrivatePageCount as bytes. The unit is verified against
# Get-Process on processes whose memory is stable between two samples; until
# then rows are held back, so no unverified value reaches OutputPath.
$unitVerified = $false
$unitRatio = $null
$previousUnitByKey = @{}
$unitCheckWritten = $false
$heldRows = New-Object System.Collections.Generic.List[object]
$heldDiagnosticRows = New-Object System.Collections.Generic.List[object]
$outputWritten = $false
$diagnosticsWritten = $false
$rowsWithMissingPrivate = 0
$rowsWithUnreadableCpu = 0
$cpuTracker = New-ProcessCpuTracker

try {
    while ($watch.Elapsed.TotalSeconds -lt $DurationSeconds) {
        $sampleStartedAt = $watch.Elapsed.TotalSeconds
        $snapshotStartedUtc = [datetime]::UtcNow
        $snapshot = @(Get-ProcessSnapshot -IncludeDiagnostics $Diagnostics.IsPresent)
        $treeResult = Get-IdentifiedProcessTree -Snapshot $snapshot -RootPid $resolvedRootPid -RootKey $rootKey
        if (-not $treeResult.RootFound) {
            Write-Warning "Root process PID=$resolvedRootPid ($rootKey) has exited. Measurement stopped."
            break
        }

        $tree = @($treeResult.Processes)
        $cpu = Update-ProcessCpuTracker -Tracker $cpuTracker -Tree $tree -SnapshotStartedUtc $snapshotStartedUtc
        $unitInputs = New-Object System.Collections.Generic.List[object]
        $treeKeys = New-Object System.Collections.Generic.List[string]

        [long]$workingSetBytes = 0
        [long]$privateBytes = 0
        $privateMissingCount = 0
        $treeDescriptions = New-Object System.Collections.Generic.List[string]
        $diagnosticRows = New-Object System.Collections.Generic.List[object]
        $sampleTimestamp = (Get-Date).ToString('o')

        foreach ($procInfo in $tree) {
            $procId = [int]$procInfo.ProcessId
            $procKey = Get-ProcessKey -ProcessInfo $procInfo
            [void]$treeKeys.Add($procKey)
            $workingSetBytes += [long]$procInfo.WorkingSetSize
            if ($null -ne $procInfo.PrivatePageCount) {
                $privateBytes += [long]$procInfo.PrivatePageCount
            }
            else {
                $privateMissingCount++
            }
            [void]$treeDescriptions.Add("$procId`:$($procInfo.Name)")

            $process = Get-ProcessOrNull -ProcessInfo $procInfo
            if (-not $unitVerified) {
                [void]$unitInputs.Add([pscustomobject]@{
                        Pid  = $procId
                        Key  = $procKey
                        Name = [string]$procInfo.Name
                        Cim  = $procInfo.PrivatePageCount
                        Proc = if ($null -ne $process) { $process.PrivateMemorySize64 } else { $null }
                    })
            }
            if ($Diagnostics) {
                $ratio = Get-PrivateUnitRatio -ProcessInfo $procInfo -Process $process
                if ($null -ne $ratio) {
                    [void]$diagnosticRatios.Add($ratio)
                }
                $cpuSeconds = if ($cpu.CpuByKey.ContainsKey($procKey)) { $cpu.CpuByKey[$procKey] } else { $null }
                [void]$diagnosticRows.Add((New-DiagnosticRow -Timestamp $sampleTimestamp -Sample $sampleNumber -ProcessInfo $procInfo -Process $process -InTree $true -Ratio $ratio -CpuSeconds $cpuSeconds -CpuState ([string]$cpu.StateByKey[$procKey])))
            }
        }

        if ($Diagnostics) {
            # A process that left the tree by exiting: its final CPU time, read
            # through the held handle, so cumulative CPU per identity is complete.
            foreach ($exited in $cpu.ExitedRead) {
                [void]$diagnosticRows.Add([pscustomobject]@{
                        Timestamp                  = $sampleTimestamp
                        Sample                     = $sampleNumber
                        Pid                        = $exited.Pid
                        ProcessKey                 = $exited.Key
                        ParentPid                  = $null
                        Name                       = $null
                        InTree                     = $true
                        CimWorkingSetSize          = $null
                        CimPrivatePageCount        = $null
                        CimPageFileUsageKB         = $null
                        ProcPrivateMemorySize64    = $null
                        ProcWorkingSet64           = $null
                        ProcTotalProcessorSeconds  = Format-InvariantDecimal -Value $exited.CpuSeconds -DecimalPlaces 4
                        RatioPrivatePageCountToPrivateMemorySize64 = $null
                        CpuState                   = 'Exited'
                    })
            }
            # WebView2 processes started for this executable carry its name in
            # --webview-exe-name. Any that the ParentProcessId walk missed are
            # not in the sums above.
            $inTree = New-Object 'System.Collections.Generic.HashSet[int]'
            foreach ($procInfo in $tree) { [void]$inTree.Add([int]$procInfo.ProcessId) }
            $marker = "--webview-exe-name=$rootExecutable"
            foreach ($procInfo in $snapshot) {
                $commandLine = [string]$procInfo.CommandLine
                if ($inTree.Contains([int]$procInfo.ProcessId) -or $commandLine.IndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                    continue
                }
                [void]$missedWebViewPids.Add([int]$procInfo.ProcessId)
                $process = Get-ProcessOrNull -ProcessInfo $procInfo
                $ratio = Get-PrivateUnitRatio -ProcessInfo $procInfo -Process $process
                [void]$diagnosticRows.Add((New-DiagnosticRow -Timestamp $sampleTimestamp -Sample $sampleNumber -ProcessInfo $procInfo -Process $process -InTree $false -Ratio $ratio -CpuSeconds (Get-CpuSeconds -Process $process) -CpuState 'Get-Process'))
            }
            if ($unitVerified) {
                Write-CsvRows -Path $diagnosticsOutput -Rows $diagnosticRows.ToArray() -Append $diagnosticsWritten
                if ($diagnosticRows.Count -gt 0) { $diagnosticsWritten = $true }
            }
            else {
                $heldDiagnosticRows.AddRange($diagnosticRows)
            }
        }

        $now = $watch.Elapsed.TotalSeconds
        $elapsed = $now - $previousSampleTime
        $cpuPercent = $null
        if ($sampleNumber -gt 0 -and $elapsed -gt 0 -and $cpu.DeltaKnown) {
            $cpuPercent = [Math]::Round((($cpu.DeltaSeconds / $elapsed) / $logicalCpuCount) * 100.0, 2)
            if ($cpuPercent -gt 100) { $cpuPercent = 100.0 }
            if ($cpuPercent -lt 0) { $cpuPercent = 0.0 }
        }

        $row = [pscustomobject]@{
            Timestamp          = $sampleTimestamp
            ElapsedSeconds     = Format-InvariantDecimal -Value ([Math]::Round($now, 2)) -DecimalPlaces 2
            IntervalSeconds    = Format-InvariantDecimal -Value ([Math]::Round($elapsed, 3)) -DecimalPlaces 3
            Sample             = $sampleNumber
            RootPid            = $resolvedRootPid
            ProcessCount       = $tree.Count
            ProcessIds         = (($tree | ForEach-Object { [string]$_.ProcessId }) -join ';')
            # PID@creation-ticks of each process; tells a reused PID apart.
            ProcessKeys        = ($treeKeys -join ';')
            ProcessTree        = ($treeDescriptions -join ';')
            WorkingSetMB       = Format-InvariantDecimal -Value ([Math]::Round(($workingSetBytes / 1MB), 2)) -DecimalPlaces 2
            PrivateBytesMB     = Format-InvariantDecimal -Value ([Math]::Round(($privateBytes / 1MB), 2)) -DecimalPlaces 2
            CpuPercentAllCores = if ($null -ne $cpuPercent) { Format-InvariantDecimal -Value $cpuPercent -DecimalPlaces 2 } else { $null }
            CpuDeltaSeconds    = if ($sampleNumber -gt 0 -and $cpu.DeltaKnown) { Format-InvariantDecimal -Value ([Math]::Round($cpu.DeltaSeconds, 4)) -DecimalPlaces 4 } else { $null }
            LogicalCpuCount    = $logicalCpuCount
            # Processes left out of PrivateBytesMB / CpuDeltaSeconds in this row
            # because the value could not be read. Non-zero means the sum is low.
            PrivateMissingCount = $privateMissingCount
            # The sum of the five Cpu*Count reasons below.
            CpuUnreadableCount  = $cpu.UnreadableCount
            # Processes whose ParentProcessId points into the tree but which are
            # not in it: created before that parent (PID reuse), or with an
            # unreadable creation time. Unverified > 0 means the tree may be
            # incomplete for this row.
            RejectedPidReuseCount  = @($treeResult.Rejected).Count
            RejectedPidReuseIds    = (@($treeResult.Rejected) -join ';')
            UnverifiedProcessCount = @($treeResult.Unverified).Count
            UnverifiedProcessIds   = (@($treeResult.Unverified) -join ';')
            # Why a CPU time is missing from CpuDeltaSeconds (see
            # ProcessCpuTracker.psm1): exited before its first read, access
            # denied, PID already reused, alive but no longer in the tree, other.
            CpuExitedUnreadCount    = $cpu.ExitedUnread.Count
            CpuExitedUnreadIds      = ($cpu.ExitedUnread -join ';')
            CpuAccessDeniedCount    = $cpu.AccessDenied.Count
            CpuAccessDeniedIds      = ($cpu.AccessDenied -join ';')
            CpuIdentityChangedCount = $cpu.IdentityChanged.Count
            CpuIdentityChangedIds   = ($cpu.IdentityChanged -join ';')
            CpuLeftTreeCount        = $cpu.LeftTree.Count
            CpuLeftTreeIds          = ($cpu.LeftTree -join ';')
            CpuReadErrorCount       = $cpu.ReadError.Count
            CpuReadErrorIds         = ($cpu.ReadError -join ';')
            # Counted in CpuDeltaSeconds: processes that exited since the
            # previous sample (final CPU through the held handle), and new
            # processes created after the previous snapshot (whole CPU time).
            CpuExitedReadCount      = $cpu.ExitedRead.Count
            CpuExitedReadIds        = (@($cpu.ExitedRead | ForEach-Object { $_.Pid }) -join ';')
            CpuNewCountedCount      = $cpu.NewCounted.Count
            CpuNewCountedIds        = ($cpu.NewCounted -join ';')
        }
        if ($privateMissingCount -gt 0) { $rowsWithMissingPrivate++ }
        if ($cpu.UnreadableCount -gt 0) { $rowsWithUnreadableCpu++ }

        if (-not $unitVerified) {
            [void]$heldRows.Add($row)
            $evaluated = @(Get-StablePrivateUnitRatios -Current $unitInputs.ToArray() -Previous $previousUnitByKey)
            $unitCheckRows = New-Object System.Collections.Generic.List[object]
            for ($i = 0; $i -lt $evaluated.Count; $i++) {
                [void]$unitCheckRows.Add([pscustomobject]@{
                        Timestamp                = $sampleTimestamp
                        Sample                   = $sampleNumber
                        Pid                      = $unitInputs[$i].Pid
                        ProcessKey               = $unitInputs[$i].Key
                        Name                     = $unitInputs[$i].Name
                        IsRoot                   = ($unitInputs[$i].Pid -eq $resolvedRootPid)
                        CimPrivatePageCount      = $evaluated[$i].Cim
                        ProcPrivateMemorySize64  = $evaluated[$i].Proc
                        PreviousCimPrivatePageCount     = $evaluated[$i].PrevCim
                        PreviousProcPrivateMemorySize64 = $evaluated[$i].PrevProc
                        Stable                   = $evaluated[$i].Stable
                        Ratio                    = Format-InvariantDecimal -Value $evaluated[$i].Ratio -DecimalPlaces 6
                    })
            }
            Write-CsvRows -Path $unitCheckOutput -Rows $unitCheckRows.ToArray() -Append $unitCheckWritten
            if ($unitCheckRows.Count -gt 0) { $unitCheckWritten = $true }

            $candidates = @(for ($i = 0; $i -lt $evaluated.Count; $i++) {
                    [pscustomobject]@{ Pid = $unitInputs[$i].Pid; Name = $unitInputs[$i].Name; Stable = $evaluated[$i].Stable; Ratio = $evaluated[$i].Ratio }
                })
            $selection = Select-PrivateUnitRatios -Candidates $candidates -RootPid $resolvedRootPid -RequiredChildName $UnitCheckRequireChildName
            if ($selection.Ready) {
                # Throws (fail closed) when stable processes disagree on the unit.
                $unitRatio = Get-VerifiedPrivateUnitRatio -Ratios $selection.Ratios
                $unitVerified = $true
                Write-Host ("PrivatePageCount unit check: median ratio to PrivateMemorySize64 = {0} over {1} stable processes ({2} stable child processes) at sample {3} (bytes)." -f (Format-InvariantDecimal -Value $unitRatio -DecimalPlaces 6), $selection.Ratios.Count, $selection.StableChildCount, $sampleNumber)
                Write-CsvRows -Path $resolvedOutput -Rows $heldRows.ToArray() -Append $false
                $outputWritten = $true
                $heldRows.Clear()
                if ($Diagnostics) {
                    Write-CsvRows -Path $diagnosticsOutput -Rows $heldDiagnosticRows.ToArray() -Append $false
                    if ($heldDiagnosticRows.Count -gt 0) { $diagnosticsWritten = $true }
                    $heldDiagnosticRows.Clear()
                }
            }
            elseif ($now -ge $UnitCheckTimeoutSeconds -and -not [string]::IsNullOrEmpty($UnitCheckRequireChildName)) {
                throw ("No child process named {0} had stable private memory (both PrivatePageCount and PrivateMemorySize64 within 1 % of the previous sample) within {1} s, so the PrivateBytesMB unit is unverified. Nothing was written to {2}. Per-process values: {3}" -f $UnitCheckRequireChildName, $UnitCheckTimeoutSeconds, $resolvedOutput, $unitCheckOutput)
            }
            elseif ($now -ge $UnitCheckTimeoutSeconds) {
                throw ("No process of the tree had stable private memory (both PrivatePageCount and PrivateMemorySize64 within 1 % of the previous sample) within {0} s, so the PrivateBytesMB unit is unverified. Nothing was written to {1}. Per-process values: {2}" -f $UnitCheckTimeoutSeconds, $resolvedOutput, $unitCheckOutput)
            }
            $previousUnitByKey = @{}
            foreach ($item in $unitInputs) {
                if (-not [string]::IsNullOrEmpty([string]$item.Key)) { $previousUnitByKey[[string]$item.Key] = $item }
            }
        }
        else {
            Write-CsvRows -Path $resolvedOutput -Rows @($row) -Append $outputWritten
            $outputWritten = $true
        }

        Write-Progress -Activity 'Measuring process resources' -Status ("Time {0}/{1} s; processes: {2}; working set: {3} MB; CPU: {4}%" -f [Math]::Round($now,0), $DurationSeconds, $tree.Count, $row.WorkingSetMB, $(if ($null -eq $cpuPercent) { 'n/a' } else { $cpuPercent })) -PercentComplete ([Math]::Min(100, ($now / $DurationSeconds) * 100))

        $previousSampleTime = $now
        $sampleNumber++

        # Keep the requested cadence inclusive of sampling and CSV overhead.
        # Use this sample's processing time to estimate the next sample's processing
        # cost; actual intervals may still vary with OS scheduling and process churn.
        $sampleProcessingSeconds = $now - $sampleStartedAt
        $postSampleSeconds = $watch.Elapsed.TotalSeconds - $now
        $remainingSleepSeconds = $SampleIntervalSeconds - $sampleProcessingSeconds - $postSampleSeconds
        if ($remainingSleepSeconds -gt 0) {
            $sleepMilliseconds = [int][Math]::Max(1, [Math]::Round($remainingSleepSeconds * 1000))
            Start-Sleep -Milliseconds $sleepMilliseconds
        }
    }
}
finally {
    Close-ProcessCpuTracker -Tracker $cpuTracker
}

$watch.Stop()
Write-Progress -Activity 'Measuring process resources' -Completed
if (-not $unitVerified) {
    throw ("The run ended after {0} sample(s) before the PrivateBytesMB unit could be verified on a stable process. Nothing was written to {1}. Per-process values: {2}" -f $sampleNumber, $resolvedOutput, $unitCheckOutput)
}
Write-Host "Done. Rows written: $sampleNumber"
Write-Host "Output file: $resolvedOutput"
if ($rowsWithMissingPrivate -gt 0 -or $rowsWithUnreadableCpu -gt 0) {
    Write-Warning ("{0} row(s) left out a process from PrivateBytesMB and {1} row(s) from CpuDeltaSeconds because its value could not be read; those sums are low. See PrivateMissingCount, CpuUnreadableCount and the Cpu*Count reasons." -f $rowsWithMissingPrivate, $rowsWithUnreadableCpu)
}
else {
    Write-Host "Every process in every row had readable PrivatePageCount and CPU time."
}
if ($Diagnostics) {
    $medianRatio = Get-Median -Values $diagnosticRatios.ToArray()
    Write-Host ("Diagnostics: median PrivatePageCount/PrivateMemorySize64 = {0} over {1} process samples." -f $(if ($null -eq $medianRatio) { 'n/a' } else { Format-InvariantDecimal -Value $medianRatio -DecimalPlaces 6 }), $diagnosticRatios.Count)
    if ($missedWebViewPids.Count -gt 0) {
        Write-Warning ("{0} WebView2 process(es) of {1} were outside the ParentProcessId tree and are NOT in the sums: {2}. See InTree=False rows in {3}." -f $missedWebViewPids.Count, $rootExecutable, (@($missedWebViewPids) -join ', '), $diagnosticsOutput)
    }
    else {
        Write-Host "Diagnostics: no WebView2 process of $rootExecutable was outside the ParentProcessId tree."
    }
    Write-Host "Diagnostics file: $diagnosticsOutput"
}
