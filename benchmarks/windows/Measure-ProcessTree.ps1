[CmdletBinding(DefaultParameterSetName = 'ByName')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'ByPid')]
    [int]$RootPid,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByName')]
    [string]$ProcessName,

    [ValidateRange(1, 3600)]
    [int]$DurationSeconds = 300,

    [ValidateRange(1, 60)]
    [int]$SampleIntervalSeconds = 1,

    [string]$OutputPath = (Join-Path (Get-Location) ("process-tree-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))),

    # Also writes one row per process per sample, comparing memory sources and
    # listing WebView2 processes of this app that the tree walk did not reach.
    [switch]$Diagnostics,

    [string]$DiagnosticsPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-ProcessSnapshot {
    param([bool]$IncludeDiagnostics = $false)
    # CIM exposes parent PIDs and memory totals and is available in Windows PowerShell 5.1.
    # PrivatePageCount is in bytes despite its name: on Windows 10 22H2 (19045)
    # it equalled Get-Process PrivateMemorySize64 and PageFileUsage * 1024 for
    # every sampled process (issue #13, stage 8). The script re-checks this at
    # startup instead of relying on it.
    $properties = @('ProcessId', 'ParentProcessId', 'Name', 'WorkingSetSize', 'PrivatePageCount')
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

function Get-TreeProcesses {
    param(
        [object[]]$Snapshot,
        [int]$StartingPid
    )

    $children = @{}
    foreach ($item in $Snapshot) {
        $parent = [int]$item.ParentProcessId
        if (-not $children.ContainsKey($parent)) {
            $children[$parent] = New-Object System.Collections.ArrayList
        }
        [void]$children[$parent].Add([int]$item.ProcessId)
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[int]'
    $queue = New-Object 'System.Collections.Generic.Queue[int]'
    [void]$seen.Add($StartingPid)
    $queue.Enqueue($StartingPid)

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if ($children.ContainsKey($current)) {
            foreach ($childPid in $children[$current]) {
                if ($seen.Add([int]$childPid)) {
                    $queue.Enqueue([int]$childPid)
                }
            }
        }
    }

    $pidSet = $seen
    @($Snapshot | Where-Object { $pidSet.Contains([int]$_.ProcessId) })
}

function Get-ProcessOrNull {
    param([int]$Id)
    try {
        return Get-Process -Id $Id -ErrorAction Stop
    }
    catch {
        return $null
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
        [AllowNull()][object]$Ratio
    )
    [pscustomobject]@{
        Timestamp                  = $Timestamp
        Sample                     = $Sample
        Pid                        = [int]$ProcessInfo.ProcessId
        ParentPid                  = [int]$ProcessInfo.ParentProcessId
        Name                       = [string]$ProcessInfo.Name
        InTree                     = $InTree
        CimWorkingSetSize          = $ProcessInfo.WorkingSetSize
        CimPrivatePageCount        = $ProcessInfo.PrivatePageCount
        CimPageFileUsageKB         = $ProcessInfo.PageFileUsage
        ProcPrivateMemorySize64    = if ($null -ne $Process) { $Process.PrivateMemorySize64 } else { $null }
        ProcWorkingSet64           = if ($null -ne $Process) { $Process.WorkingSet64 } else { $null }
        ProcTotalProcessorSeconds  = Format-InvariantDecimal -Value (Get-CpuSeconds -Process $Process) -DecimalPlaces 4
        RatioPrivatePageCountToPrivateMemorySize64 = Format-InvariantDecimal -Value $Ratio -DecimalPlaces 6
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
$logicalCpuCount = [Environment]::ProcessorCount

# PrivateBytesMB sums PrivatePageCount as bytes. Verify that unit on this
# system against Get-Process before measuring; a wrong unit would make every
# PrivateBytesMB value wrong by a factor of 4096.
$unitRatios = New-Object System.Collections.Generic.List[double]
foreach ($procInfo in @(Get-TreeProcesses -Snapshot $firstSnapshot -StartingPid $resolvedRootPid)) {
    $ratio = Get-PrivateUnitRatio -ProcessInfo $procInfo -Process (Get-ProcessOrNull -Id ([int]$procInfo.ProcessId))
    if ($null -ne $ratio) {
        [void]$unitRatios.Add($ratio)
    }
}
$unitRatio = Get-Median -Values $unitRatios.ToArray()
if ($null -eq $unitRatio) {
    Write-Warning "Could not compare PrivatePageCount with Get-Process PrivateMemorySize64; the PrivateBytesMB unit is unverified for this run."
}
elseif ($unitRatio -lt 0.9 -or $unitRatio -gt 1.1) {
    throw ("PrivatePageCount does not look like bytes on this system: its median ratio to Get-Process PrivateMemorySize64 is {0} over {1} processes (1 = bytes). PrivateBytesMB would be wrong. Run with -Diagnostics and report the output." -f (Format-InvariantDecimal -Value $unitRatio -DecimalPlaces 6), $unitRatios.Count)
}
else {
    Write-Host ("PrivatePageCount unit check: median ratio to PrivateMemorySize64 = {0} over {1} processes (bytes)." -f (Format-InvariantDecimal -Value $unitRatio -DecimalPlaces 6), $unitRatios.Count)
}

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

Write-Host "Measuring process: $($rootRecord.Name), PID=$resolvedRootPid"
Write-Host "Duration: $DurationSeconds seconds; interval: $SampleIntervalSeconds seconds"
Write-Host "CSV: $resolvedOutput"
if ($null -ne $diagnosticsOutput) {
    Write-Host "Diagnostics CSV: $diagnosticsOutput"
}
Write-Host "CpuPercentAllCores is normalized to total capacity of all logical CPUs (0 to 100%). On an 8-logical-CPU system, one fully utilized core is about 12.5%."
Write-Host "Stop: Ctrl+C"

$watch = [System.Diagnostics.Stopwatch]::StartNew()
$previousSampleTime = $watch.Elapsed.TotalSeconds
$previousCpuByPid = @{}
$firstRow = $true
$sampleNumber = 0

while ($watch.Elapsed.TotalSeconds -lt $DurationSeconds) {
    $sampleStartedAt = $watch.Elapsed.TotalSeconds
    $snapshot = @(Get-ProcessSnapshot -IncludeDiagnostics $Diagnostics.IsPresent)
    $rootStillExists = @($snapshot | Where-Object { [int]$_.ProcessId -eq $resolvedRootPid }).Count -gt 0
    if (-not $rootStillExists) {
        Write-Warning "Root process PID=$resolvedRootPid has exited. Measurement stopped."
        break
    }

    $tree = @(Get-TreeProcesses -Snapshot $snapshot -StartingPid $resolvedRootPid)
    $currentCpuByPid = @{}
    $cpuDeltaSeconds = 0.0
    $cpuDeltaKnown = $false

    [long]$workingSetBytes = 0
    [long]$privateBytes = 0
    $treeDescriptions = New-Object System.Collections.Generic.List[string]
    $diagnosticRows = New-Object System.Collections.Generic.List[object]
    $sampleTimestamp = (Get-Date).ToString('o')

    foreach ($procInfo in $tree) {
        $procId = [int]$procInfo.ProcessId
        $workingSetBytes += [long]$procInfo.WorkingSetSize
        if ($null -ne $procInfo.PrivatePageCount) {
            $privateBytes += [long]$procInfo.PrivatePageCount
        }
        [void]$treeDescriptions.Add("$procId`:$($procInfo.Name)")

        $process = Get-ProcessOrNull -Id $procId
        $cpuNow = Get-CpuSeconds -Process $process
        if ($Diagnostics) {
            $ratio = Get-PrivateUnitRatio -ProcessInfo $procInfo -Process $process
            if ($null -ne $ratio) {
                [void]$diagnosticRatios.Add($ratio)
            }
            [void]$diagnosticRows.Add((New-DiagnosticRow -Timestamp $sampleTimestamp -Sample $sampleNumber -ProcessInfo $procInfo -Process $process -InTree $true -Ratio $ratio))
        }
        if ($null -ne $cpuNow) {
            $currentCpuByPid[$procId] = [double]$cpuNow
            if ($previousCpuByPid.ContainsKey($procId)) {
                $delta = [double]$cpuNow - [double]$previousCpuByPid[$procId]
                if ($delta -ge 0) {
                    $cpuDeltaSeconds += $delta
                    $cpuDeltaKnown = $true
                }
            }
        }
    }

    if ($Diagnostics) {
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
            $process = Get-ProcessOrNull -Id ([int]$procInfo.ProcessId)
            $ratio = Get-PrivateUnitRatio -ProcessInfo $procInfo -Process $process
            [void]$diagnosticRows.Add((New-DiagnosticRow -Timestamp $sampleTimestamp -Sample $sampleNumber -ProcessInfo $procInfo -Process $process -InTree $false -Ratio $ratio))
        }
        if ($diagnosticRows.Count -gt 0) {
            if ($firstRow) {
                $diagnosticRows | Export-Csv -LiteralPath $diagnosticsOutput -NoTypeInformation -Encoding UTF8
            }
            else {
                $diagnosticRows | Export-Csv -LiteralPath $diagnosticsOutput -NoTypeInformation -Encoding UTF8 -Append
            }
        }
    }

    $now = $watch.Elapsed.TotalSeconds
    $elapsed = $now - $previousSampleTime
    $cpuPercent = $null
    if ($sampleNumber -gt 0 -and $elapsed -gt 0 -and $cpuDeltaKnown) {
        $cpuPercent = [Math]::Round((($cpuDeltaSeconds / $elapsed) / $logicalCpuCount) * 100.0, 2)
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
        ProcessTree        = ($treeDescriptions -join ';')
        WorkingSetMB       = Format-InvariantDecimal -Value ([Math]::Round(($workingSetBytes / 1MB), 2)) -DecimalPlaces 2
        PrivateBytesMB     = Format-InvariantDecimal -Value ([Math]::Round(($privateBytes / 1MB), 2)) -DecimalPlaces 2
        CpuPercentAllCores = if ($null -ne $cpuPercent) { Format-InvariantDecimal -Value $cpuPercent -DecimalPlaces 2 } else { $null }
        CpuDeltaSeconds    = if ($sampleNumber -gt 0) { Format-InvariantDecimal -Value ([Math]::Round($cpuDeltaSeconds, 4)) -DecimalPlaces 4 } else { $null }
        LogicalCpuCount    = $logicalCpuCount
    }

    if ($firstRow) {
        $row | Export-Csv -LiteralPath $resolvedOutput -NoTypeInformation -Encoding UTF8
        $firstRow = $false
    }
    else {
        $row | Export-Csv -LiteralPath $resolvedOutput -NoTypeInformation -Encoding UTF8 -Append
    }

    Write-Progress -Activity 'Measuring process resources' -Status ("Time {0}/{1} s; processes: {2}; working set: {3} MB; CPU: {4}%" -f [Math]::Round($now,0), $DurationSeconds, $tree.Count, $row.WorkingSetMB, $(if ($null -eq $cpuPercent) { 'n/a' } else { $cpuPercent })) -PercentComplete ([Math]::Min(100, ($now / $DurationSeconds) * 100))

    $previousCpuByPid = $currentCpuByPid
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

$watch.Stop()
Write-Progress -Activity 'Measuring process resources' -Completed
Write-Host "Done. Rows written: $sampleNumber"
Write-Host "Output file: $resolvedOutput"
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
