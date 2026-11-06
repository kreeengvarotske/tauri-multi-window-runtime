Set-StrictMode -Version 2.0
Import-Module -Name (Join-Path $PSScriptRoot 'ProcessTreeIdentity.psm1')

# CPU time of the processes of a tree, read through a process handle that is
# opened once per identity (PID + creation time) and held until the process
# leaves the tree. A held handle keeps the exited process object, so its
# final CPU time stays readable and its PID cannot be reused meanwhile. Each
# CPU value that cannot be read gets one of these reasons:
#   ExitedUnread    - the process exited before a handle could be opened
#                     (no process with that PID exists any more)
#   AccessDenied    - the handle could not be opened for lack of access
#   IdentityChanged - the PID already names a process with another creation
#                     time (the original exited and its PID was reused)
#   LeftTree        - the process is still running but no longer reached by
#                     the ParentProcessId walk (an intermediate parent exited)
#   ReadError       - any other failure to open or read
# A process that exits while its handle is held is counted with its final
# CPU time (ExitedRead) and is not unreadable.

$script:NativeSource = @'
using System;
using System.Runtime.InteropServices;

public static class TmwrProcessCpu
{
    const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    const uint SYNCHRONIZE = 0x00100000;

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr handle);

    public static IntPtr Open(int processId, out int error)
    {
        IntPtr handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, false, processId);
        error = handle == IntPtr.Zero ? Marshal.GetLastWin32Error() : 0;
        return handle;
    }

    // 1 = exited, 0 = running, -1 = unknown.
    public static int State(IntPtr handle)
    {
        uint result = WaitForSingleObject(handle, 0);
        if (result == 0) return 1;
        if (result == 0x102) return 0;
        return -1;
    }

    // Creation time as UTC DateTime ticks; CPU as user + kernel 100 ns units.
    public static bool Times(IntPtr handle, out long creationUtcTicks, out long cpuTicks, out int error)
    {
        long creation, exit, kernel, user;
        if (!GetProcessTimes(handle, out creation, out exit, out kernel, out user))
        {
            error = Marshal.GetLastWin32Error();
            creationUtcTicks = 0;
            cpuTicks = 0;
            return false;
        }
        error = 0;
        creationUtcTicks = DateTime.FromFileTimeUtc(creation).Ticks;
        cpuTicks = kernel + user;
        return true;
    }

    public static void Close(IntPtr handle)
    {
        if (handle != IntPtr.Zero) CloseHandle(handle);
    }
}
'@

function Initialize-ProcessCpuNative {
    if ($null -eq ('TmwrProcessCpu' -as [type])) {
        Add-Type -TypeDefinition $script:NativeSource -Language CSharp
    }
}

function Open-ProcessCpuHandle {
    # Opens a handle and checks that it names the process of the snapshot
    # record: the creation time read through the handle must match the
    # record's CreationDate within ToleranceSeconds.
    param(
        [Parameter(Mandatory = $true)][object]$ProcessInfo,
        [double]$ToleranceSeconds = 0.001
    )
    Initialize-ProcessCpuNative
    $openError = 0
    $handle = [TmwrProcessCpu]::Open([int]$ProcessInfo.ProcessId, [ref]$openError)
    if ($handle -eq [IntPtr]::Zero) {
        # 87 ERROR_INVALID_PARAMETER: no process object with this PID exists.
        $status = switch ($openError) { 87 { 'ExitedUnread' } 5 { 'AccessDenied' } default { 'ReadError' } }
        return [pscustomobject]@{ Status = $status; Handle = $null; Detail = "OpenProcess error $openError" }
    }
    $created = [long]0; $cpu = [long]0; $timesError = 0
    if (-not [TmwrProcessCpu]::Times($handle, [ref]$created, [ref]$cpu, [ref]$timesError)) {
        [TmwrProcessCpu]::Close($handle)
        $status = if ($timesError -eq 5) { 'AccessDenied' } else { 'ReadError' }
        return [pscustomobject]@{ Status = $status; Handle = $null; Detail = "GetProcessTimes error $timesError" }
    }
    $expected = ([datetime]$ProcessInfo.CreationDate).ToUniversalTime().Ticks
    if ([Math]::Abs($created - $expected) -gt $ToleranceSeconds * [TimeSpan]::TicksPerSecond) {
        [TmwrProcessCpu]::Close($handle)
        return [pscustomobject]@{ Status = 'IdentityChanged'; Handle = $null; Detail = "creation time $created, expected $expected" }
    }
    return [pscustomobject]@{ Status = 'Open'; Handle = $handle; Detail = $null }
}

function Read-ProcessCpuHandle {
    # Running or Exited with CpuSeconds, or ReadError. The state is read
    # before the times, so an Exited value is the final CPU time.
    param([Parameter(Mandatory = $true)][object]$Handle)
    $state = [TmwrProcessCpu]::State($Handle)
    $created = [long]0; $cpu = [long]0; $timesError = 0
    if ($state -lt 0 -or -not [TmwrProcessCpu]::Times($Handle, [ref]$created, [ref]$cpu, [ref]$timesError)) {
        return [pscustomobject]@{ Status = 'ReadError'; CpuSeconds = $null }
    }
    return [pscustomobject]@{
        Status     = if ($state -eq 1) { 'Exited' } else { 'Running' }
        CpuSeconds = [double]$cpu / [TimeSpan]::TicksPerSecond
    }
}

function Close-ProcessCpuHandle {
    param([Parameter(Mandatory = $true)][object]$Handle)
    [TmwrProcessCpu]::Close($Handle)
}

function New-ProcessCpuTracker {
    # Open, Read and Close default to the native functions above; tests pass
    # script blocks with the same contracts.
    param(
        [scriptblock]$Open = { param($ProcessInfo) Open-ProcessCpuHandle -ProcessInfo $ProcessInfo },
        [scriptblock]$Read = { param($Handle) Read-ProcessCpuHandle -Handle $Handle },
        [scriptblock]$Close = { param($Handle) Close-ProcessCpuHandle -Handle $Handle }
    )
    [pscustomobject]@{
        Open                = $Open
        Read                = $Read
        Close               = $Close
        Entries             = @{}
        PreviousSnapshotUtc = $null
    }
}

function Update-ProcessCpuTracker {
    <#
    Reads the CPU time of every process of this sample's tree and returns
    the CPU used since the previous sample:
      - a process seen before contributes its increase since its last read;
      - a process that left the tree and exited contributes its final CPU
        time minus its last read (ExitedRead);
      - a process seen for the first time contributes its whole CPU time only
        if it was created after the previous snapshot started, so all of it
        falls in this interval (NewCounted); otherwise its first read is the
        baseline, as at sample 0.
    Unreadable lists the processes whose CPU is missing from the sum, by reason.
    SnapshotStartedUtc is the time just before this sample's snapshot query.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Tracker,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Tree,
        [Parameter(Mandatory = $true)][datetime]$SnapshotStartedUtc
    )

    $result = [pscustomobject]@{
        DeltaSeconds    = 0.0
        DeltaKnown      = $false
        CpuByKey        = @{}
        StateByKey      = @{}
        ExitedRead      = New-Object System.Collections.Generic.List[object]
        NewCounted      = New-Object System.Collections.Generic.List[int]
        ExitedUnread    = New-Object System.Collections.Generic.List[int]
        AccessDenied    = New-Object System.Collections.Generic.List[int]
        IdentityChanged = New-Object System.Collections.Generic.List[int]
        LeftTree        = New-Object System.Collections.Generic.List[int]
        ReadError       = New-Object System.Collections.Generic.List[int]
        UnreadableCount = 0
    }
    $previousSnapshot = $Tracker.PreviousSnapshotUtc
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($procInfo in $Tree) {
        $procId = [int]$procInfo.ProcessId
        $key = Get-ProcessKey -ProcessInfo $procInfo
        [void]$seen.Add($key)
        $entry = $null
        if ($Tracker.Entries.ContainsKey($key)) { $entry = $Tracker.Entries[$key] }
        $isNew = $null -eq $entry
        if ($isNew) {
            $opened = & $Tracker.Open $procInfo
            if ($opened.Status -ne 'Open') {
                $reason = if (@('ExitedUnread', 'AccessDenied', 'IdentityChanged') -contains $opened.Status) { [string]$opened.Status } else { 'ReadError' }
                $result.$reason.Add($procId)
                $result.StateByKey[$key] = $reason
                continue
            }
            $entry = [pscustomobject]@{ Handle = $opened.Handle; Pid = $procId; LastCpu = $null; CreatedTicks = Get-ProcessCreationTicks -ProcessInfo $procInfo }
            $Tracker.Entries[$key] = $entry
        }
        $read = & $Tracker.Read $entry.Handle
        if ($read.Status -eq 'ReadError' -or $null -eq $read.CpuSeconds) {
            $result.ReadError.Add($procId)
            $result.StateByKey[$key] = 'ReadError'
            continue
        }
        $cpu = [double]$read.CpuSeconds
        $result.CpuByKey[$key] = $cpu
        $result.StateByKey[$key] = [string]$read.Status
        if ($null -ne $entry.LastCpu) {
            $delta = $cpu - [double]$entry.LastCpu
            if ($delta -ge 0) { $result.DeltaSeconds += $delta; $result.DeltaKnown = $true }
            else { $result.ReadError.Add($procId); $result.StateByKey[$key] = 'ReadError' }
        }
        elseif ($isNew -and $null -ne $previousSnapshot -and $entry.CreatedTicks -ge ([datetime]$previousSnapshot).ToUniversalTime().Ticks) {
            $result.DeltaSeconds += $cpu
            $result.DeltaKnown = $true
            $result.NewCounted.Add($procId)
        }
        $entry.LastCpu = $cpu
    }

    foreach ($key in @($Tracker.Entries.Keys)) {
        if ($seen.Contains($key)) { continue }
        $entry = $Tracker.Entries[$key]
        $read = & $Tracker.Read $entry.Handle
        if ($read.Status -eq 'Exited' -and $null -ne $read.CpuSeconds -and $null -ne $entry.LastCpu -and [double]$read.CpuSeconds -ge [double]$entry.LastCpu) {
            $result.DeltaSeconds += [double]$read.CpuSeconds - [double]$entry.LastCpu
            $result.DeltaKnown = $true
            $result.ExitedRead.Add([pscustomobject]@{ Pid = $entry.Pid; Key = $key; CpuSeconds = [double]$read.CpuSeconds })
        }
        elseif ($read.Status -eq 'Running') {
            $result.LeftTree.Add($entry.Pid)
        }
        else {
            $result.ReadError.Add($entry.Pid)
        }
        & $Tracker.Close $entry.Handle
        $Tracker.Entries.Remove($key)
    }

    $Tracker.PreviousSnapshotUtc = $SnapshotStartedUtc
    $result.UnreadableCount = $result.ExitedUnread.Count + $result.AccessDenied.Count + $result.IdentityChanged.Count + $result.LeftTree.Count + $result.ReadError.Count
    return $result
}

function Close-ProcessCpuTracker {
    param([Parameter(Mandatory = $true)][object]$Tracker)
    foreach ($key in @($Tracker.Entries.Keys)) {
        & $Tracker.Close $Tracker.Entries[$key].Handle
        $Tracker.Entries.Remove($key)
    }
}

Export-ModuleMember -Function Initialize-ProcessCpuNative, Open-ProcessCpuHandle, Read-ProcessCpuHandle, Close-ProcessCpuHandle, New-ProcessCpuTracker, Update-ProcessCpuTracker, Close-ProcessCpuTracker
