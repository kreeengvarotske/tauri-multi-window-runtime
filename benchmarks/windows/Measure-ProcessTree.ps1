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

    [string]$OutputPath = (Join-Path (Get-Location) ("process-tree-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss')))
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-ProcessSnapshot {
    # CIM exposes parent PIDs and memory totals and is available in Windows PowerShell 5.1.
    Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, Name, WorkingSetSize, PrivatePageCount
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

function Get-CpuSeconds {
    param([int]$Id)
    try {
        $proc = Get-Process -Id $Id -ErrorAction Stop
        return [double]$proc.TotalProcessorTime.TotalSeconds
    }
    catch {
        return $null
    }
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

Write-Host "Measuring process: $($rootRecord.Name), PID=$resolvedRootPid"
Write-Host "Duration: $DurationSeconds seconds; interval: $SampleIntervalSeconds seconds"
Write-Host "CSV: $resolvedOutput"
Write-Host "CpuPercentAllCores is normalized to total capacity of all logical CPUs (0–100%). For example, one fully utilized core on an 8-logical-CPU system is about 12.5%."
Write-Host "Stop: Ctrl+C"

$watch = [System.Diagnostics.Stopwatch]::StartNew()
$previousSampleTime = $watch.Elapsed.TotalSeconds
$previousCpuByPid = @{}
$firstRow = $true
$sampleNumber = 0

while ($watch.Elapsed.TotalSeconds -lt $DurationSeconds) {
    $snapshot = @(Get-ProcessSnapshot)
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

    foreach ($procInfo in $tree) {
        $procId = [int]$procInfo.ProcessId
        $workingSetBytes += [long]$procInfo.WorkingSetSize
        if ($null -ne $procInfo.PrivatePageCount) {
            $privateBytes += [long]$procInfo.PrivatePageCount
        }
        [void]$treeDescriptions.Add("$procId`:$($procInfo.Name)")

        $cpuNow = Get-CpuSeconds -Id $procId
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

    $now = $watch.Elapsed.TotalSeconds
    $elapsed = $now - $previousSampleTime
    $cpuPercent = $null
    if ($sampleNumber -gt 0 -and $elapsed -gt 0 -and $cpuDeltaKnown) {
        $cpuPercent = [Math]::Round((($cpuDeltaSeconds / $elapsed) / $logicalCpuCount) * 100.0, 2)
        if ($cpuPercent -gt 100) { $cpuPercent = 100.0 }
        if ($cpuPercent -lt 0) { $cpuPercent = 0.0 }
    }

    $row = [pscustomobject]@{
        Timestamp          = (Get-Date).ToString('o')
        ElapsedSeconds     = [Math]::Round($now, 2)
        IntervalSeconds    = [Math]::Round($elapsed, 3)
        Sample             = $sampleNumber
        RootPid            = $resolvedRootPid
        ProcessCount       = $tree.Count
        ProcessIds         = (($tree | ForEach-Object { [string]$_.ProcessId }) -join ';')
        ProcessTree        = ($treeDescriptions -join ';')
        WorkingSetMB       = [Math]::Round(($workingSetBytes / 1MB), 2)
        PrivateBytesMB     = [Math]::Round(($privateBytes / 1MB), 2)
        CpuPercentAllCores = $cpuPercent
        CpuDeltaSeconds    = if ($sampleNumber -gt 0) { [Math]::Round($cpuDeltaSeconds, 4) } else { $null }
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
    Start-Sleep -Seconds $SampleIntervalSeconds
}

$watch.Stop()
Write-Progress -Activity 'Measuring process resources' -Completed
Write-Host "Done. Rows written: $sampleNumber"
Write-Host "Output file: $resolvedOutput"
