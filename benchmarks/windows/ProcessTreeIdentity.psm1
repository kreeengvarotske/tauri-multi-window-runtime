Set-StrictMode -Version 2.0

# A process is identified by its PID and its creation time. Windows reuses
# PIDs, so a PID alone can name an unrelated process after the original exits.

function Get-ProcessCreationTicks {
    param([Parameter(Mandatory = $true)][object]$ProcessInfo)
    $created = $ProcessInfo.CreationDate
    if ($null -eq $created) {
        return $null
    }
    return ([datetime]$created).ToUniversalTime().Ticks
}

function Get-ProcessKey {
    # "<pid>@<creation time in UTC ticks>", or $null when the creation time
    # cannot be read and the identity is therefore unknown.
    param([Parameter(Mandatory = $true)][object]$ProcessInfo)
    $ticks = Get-ProcessCreationTicks -ProcessInfo $ProcessInfo
    if ($null -eq $ticks) {
        return $null
    }
    return ('{0}@{1}' -f [int]$ProcessInfo.ProcessId, $ticks)
}

function Get-IdentifiedProcessTree {
    <#
    Walks ParentProcessId from the root and keeps a child only if it was
    created no earlier than the process it claims as parent. A process
    created before its "parent" got that ParentProcessId from an earlier
    process that had the same PID, so it is not a descendant (PID reuse).
    This rule is exact: a live process created before the child held the
    PID when the child was created, so it is the child's real parent.

    RootKey, when given, is the root's identity from the first snapshot; if
    the PID now belongs to another process, RootFound is false.

    Returns:
      RootFound   - the root is in the snapshot with the expected identity
      Processes   - the root and every verified descendant (snapshot records)
      Rejected    - PIDs that point at a tree process as parent but were
                    created before it (PID reuse), with their subtrees cut
      Unverified  - PIDs that point at a tree process as parent but whose
                    creation time is unknown; they are left out of the sums,
                    so a non-zero count means the tree is not fully covered
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Snapshot,
        [Parameter(Mandatory = $true)][int]$RootPid,
        [AllowNull()][string]$RootKey
    )

    $result = [pscustomobject]@{
        RootFound  = $false
        Processes  = @()
        Rejected   = @()
        Unverified = @()
    }

    $root = @($Snapshot | Where-Object { [int]$_.ProcessId -eq $RootPid } | Select-Object -First 1)
    if ($root.Count -eq 0) {
        return $result
    }
    $root = $root[0]
    $rootTicks = Get-ProcessCreationTicks -ProcessInfo $root
    if ($null -eq $rootTicks) {
        # Without the root's creation time no child can be verified.
        return $result
    }
    if (-not [string]::IsNullOrEmpty($RootKey) -and (Get-ProcessKey -ProcessInfo $root) -ne $RootKey) {
        return $result
    }
    $result.RootFound = $true

    $children = @{}
    foreach ($item in $Snapshot) {
        $parent = [int]$item.ParentProcessId
        if ([int]$item.ProcessId -eq $parent) { continue }
        if (-not $children.ContainsKey($parent)) {
            $children[$parent] = New-Object System.Collections.ArrayList
        }
        [void]$children[$parent].Add($item)
    }

    $included = New-Object System.Collections.ArrayList
    $rejected = New-Object System.Collections.ArrayList
    $unverified = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[int]'
    $queue = New-Object System.Collections.Queue
    [void]$seen.Add($RootPid)
    [void]$included.Add($root)
    $queue.Enqueue([pscustomobject]@{ Pid = $RootPid; Ticks = $rootTicks })

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not $children.ContainsKey($current.Pid)) { continue }
        foreach ($child in $children[$current.Pid]) {
            $childPid = [int]$child.ProcessId
            if ($seen.Contains($childPid)) { continue }
            $childTicks = Get-ProcessCreationTicks -ProcessInfo $child
            if ($null -eq $childTicks) {
                [void]$seen.Add($childPid)
                [void]$unverified.Add($childPid)
                continue
            }
            if ($childTicks -lt $current.Ticks) {
                [void]$seen.Add($childPid)
                [void]$rejected.Add($childPid)
                continue
            }
            [void]$seen.Add($childPid)
            [void]$included.Add($child)
            $queue.Enqueue([pscustomobject]@{ Pid = $childPid; Ticks = $childTicks })
        }
    }

    $result.Processes = @($included)
    $result.Rejected = @($rejected)
    $result.Unverified = @($unverified)
    return $result
}

function Test-SameProcess {
    # True when a Get-Process object is the process of the snapshot record:
    # same PID and a start time within ToleranceSeconds of its creation time.
    # False when the start time cannot be read, so an unconfirmed handle is
    # never used for memory or CPU.
    param(
        [Parameter(Mandatory = $true)][object]$ProcessInfo,
        [AllowNull()][object]$Process,
        [double]$ToleranceSeconds = 1.0
    )
    if ($null -eq $Process -or $null -eq $ProcessInfo.CreationDate) {
        return $false
    }
    try {
        $started = [datetime]$Process.StartTime
    }
    catch {
        return $false
    }
    $difference = ($started.ToUniversalTime() - ([datetime]$ProcessInfo.CreationDate).ToUniversalTime()).TotalSeconds
    return [Math]::Abs($difference) -le $ToleranceSeconds
}

Export-ModuleMember -Function Get-ProcessCreationTicks, Get-ProcessKey, Get-IdentifiedProcessTree, Test-SameProcess
