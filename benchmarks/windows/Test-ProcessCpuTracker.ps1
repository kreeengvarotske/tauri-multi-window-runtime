[CmdletBinding()]
param()

# Regression fixtures for the CPU tracker (ProcessCpuTracker.psm1) and the
# startup unit-check selection (Select-PrivateUnitRatios). The tracker cases
# use fake handles, so the decision logic is tested on any OS; on Windows
# the native handle functions are also checked on real processes.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'PrivateUnitValidation.psm1') -Force
Import-Module -Name (Join-Path $PSScriptRoot 'ProcessTreeIdentity.psm1') -Force
Import-Module -Name (Join-Path $PSScriptRoot 'ProcessCpuTracker.psm1') -Force

$script:Passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
    $script:Passed++
}

function Assert-Near {
    param([double]$Actual, [double]$Expected, [string]$Message)
    Assert-True ([Math]::Abs($Actual - $Expected) -lt 1e-9) "$Message (expected $Expected, got $Actual)"
}

$t0 = [datetime]::new(2026, 11, 6, 9, 0, 0, [System.DateTimeKind]::Utc)

function New-Proc {
    param([int]$Id, [double]$CreatedOffsetSeconds)
    [pscustomobject]@{ ProcessId = $Id; ParentProcessId = 1; Name = 'msedgewebview2.exe'; CreationDate = $t0.AddSeconds($CreatedOffsetSeconds) }
}

# The fake world: what opening each PID returns, and each handle's state.
# A handle is the PID; Closed records every handle closed.
$script:OpenResult = @{}
$script:World = @{}
$script:Closed = New-Object System.Collections.Generic.List[int]

function Reset-World {
    $script:OpenResult = @{}
    $script:World = @{}
    $script:Closed.Clear()
}

function Set-Process {
    param([int]$Id, [string]$State, [double]$Cpu, [string]$OpenStatus = 'Open')
    $script:OpenResult[$Id] = $OpenStatus
    $script:World[$Id] = [pscustomobject]@{ State = $State; Cpu = $Cpu }
}

function New-FakeTracker {
    New-ProcessCpuTracker -Open {
        param($ProcessInfo)
        $id = [int]$ProcessInfo.ProcessId
        $status = if ($script:OpenResult.ContainsKey($id)) { $script:OpenResult[$id] } else { 'ExitedUnread' }
        [pscustomobject]@{ Status = $status; Handle = $(if ($status -eq 'Open') { $id } else { $null }); Detail = $null }
    } -Read {
        param($Handle)
        $p = $script:World[[int]$Handle]
        if ($p.State -eq 'ReadError') { return [pscustomobject]@{ Status = 'ReadError'; CpuSeconds = $null } }
        [pscustomobject]@{ Status = $p.State; CpuSeconds = $p.Cpu }
    } -Close {
        param($Handle)
        $script:Closed.Add([int]$Handle)
    }
}

function Step {
    param($Tracker, [object[]]$Tree, [double]$AtSeconds)
    Update-ProcessCpuTracker -Tracker $Tracker -Tree $Tree -SnapshotStartedUtc $t0.AddSeconds($AtSeconds)
}

$root = New-Proc -Id 100 -CreatedOffsetSeconds 0

# 1. Sample 0 is the baseline; later samples add each process's increase.
Reset-World
Set-Process -Id 100 -State Running -Cpu 2.0
$tracker = New-FakeTracker
$r = Step $tracker @($root) 10
Assert-True (-not $r.DeltaKnown) 'sample 0 has no CPU delta'
Assert-True ($r.UnreadableCount -eq 0) 'sample 0 reads the root'
Assert-Near $r.CpuByKey[(Get-ProcessKey $root)] 2.0 'cumulative CPU of the root'
Set-Process -Id 100 -State Running -Cpu 2.5
$r = Step $tracker @($root) 11
Assert-True $r.DeltaKnown 'sample 1 has a CPU delta'
Assert-Near $r.DeltaSeconds 0.5 'root increase'

# 2. A process created after the previous snapshot: all its CPU is in this interval.
$child = New-Proc -Id 200 -CreatedOffsetSeconds 11.4
Set-Process -Id 100 -State Running -Cpu 2.6
Set-Process -Id 200 -State Running -Cpu 0.3
$r = Step $tracker @($root, $child) 12
Assert-Near $r.DeltaSeconds 0.4 'root 0.1 plus the new child 0.3'
Assert-True (($r.NewCounted -join ',') -eq '200') 'the new child is reported as counted'

# 3. The child exits while its handle is held: the final CPU is counted, the handle closed.
Set-Process -Id 100 -State Running -Cpu 2.6
Set-Process -Id 200 -State Exited -Cpu 0.45
$r = Step $tracker @($root) 13
Assert-Near $r.DeltaSeconds 0.15 'final CPU of the exited child since its last read'
Assert-True ($r.ExitedRead.Count -eq 1 -and $r.ExitedRead[0].Pid -eq 200) 'reported as exited and read'
Assert-Near $r.ExitedRead[0].CpuSeconds 0.45 'final cumulative CPU of the exited child'
Assert-True ($r.UnreadableCount -eq 0) 'an exit read through a held handle is not unreadable'
Assert-True ($script:Closed -contains 200 -and -not $tracker.Entries.ContainsKey((Get-ProcessKey $child))) 'its handle is closed and forgotten'

# 4. The re-smoke race (#36): a child seen in one snapshot that exits before
# its first read. Its object is kept by another handle (the WebView2 browser
# process), so the handle opens and the final CPU is counted.
$transient = New-Proc -Id 300 -CreatedOffsetSeconds 13.2
Set-Process -Id 300 -State Exited -Cpu 0.07
$r = Step $tracker @($root, $transient) 14
Assert-Near $r.DeltaSeconds 0.07 'whole CPU of the transient child'
Assert-True ($r.UnreadableCount -eq 0 -and $r.StateByKey[(Get-ProcessKey $transient)] -eq 'Exited') 'read as exited, not unreadable'
$r = Step $tracker @($root) 15
Assert-Near $r.DeltaSeconds 0.0 'nothing is counted twice when it leaves the tree'
Assert-True ($r.ExitedRead.Count -eq 1 -and $r.UnreadableCount -eq 0) 'then reported as exited and read'

# 5. The same race when no handle keeps the object: confirmed exit, CPU missing.
$gone = New-Proc -Id 301 -CreatedOffsetSeconds 15.5
$r = Step $tracker @($root, $gone) 16
Assert-True ($r.UnreadableCount -eq 1 -and ($r.ExitedUnread -join ',') -eq '301') 'exited before its first read'
Assert-Near $r.DeltaSeconds 0.0 'its CPU is not counted as zero: the row reports it missing'
Assert-True ($r.StateByKey[(Get-ProcessKey $gone)] -eq 'ExitedUnread') 'state for diagnostics'

# 6. Access denied and a reused PID are reported separately.
$denied = New-Proc -Id 400 -CreatedOffsetSeconds 16.5
$reused = New-Proc -Id 401 -CreatedOffsetSeconds 16.6
Set-Process -Id 400 -State Running -Cpu 1.0 -OpenStatus AccessDenied
Set-Process -Id 401 -State Running -Cpu 1.0 -OpenStatus IdentityChanged
$r = Step $tracker @($root, $denied, $reused) 17
Assert-True (($r.AccessDenied -join ',') -eq '400') 'access denied'
Assert-True (($r.IdentityChanged -join ',') -eq '401') 'identity changed'
Assert-True ($r.UnreadableCount -eq 2 -and $r.ExitedUnread.Count -eq 0) 'two unreadable, no exit'
Assert-True (-not $tracker.Entries.ContainsKey((Get-ProcessKey $denied)) -and -not $tracker.Entries.ContainsKey((Get-ProcessKey $reused))) 'no handle kept for either'

# 7. A process created before the previous snapshot but first seen now (it
# was not in the tree then): its first read is a baseline, not a delta.
$late = New-Proc -Id 500 -CreatedOffsetSeconds 5
Set-Process -Id 500 -State Running -Cpu 9.0
$r = Step $tracker @($root, $late) 18
Assert-Near $r.DeltaSeconds 0.0 'an older process first seen now adds nothing'
Assert-True ($r.NewCounted.Count -eq 0) 'not reported as counted'

# 8. Alive but no longer reached by the tree walk: unreadable, handle closed.
$r = Step $tracker @($root) 19
Assert-True (($r.LeftTree -join ',') -eq '500' -and $r.UnreadableCount -eq 1) 'left the tree while running'
Assert-True ($script:Closed -contains 500) 'its handle is closed'

# 9. A read that fails, and a CPU time that goes down, are read errors.
Set-Process -Id 100 -State ReadError -Cpu 0
$r = Step $tracker @($root) 20
Assert-True (($r.ReadError -join ',') -eq '100' -and -not $r.DeltaKnown) 'failed read'
Set-Process -Id 100 -State Running -Cpu 1.0
$r = Step $tracker @($root) 21
Assert-True (($r.ReadError -join ',') -eq '100') 'CPU time below the last read'

# 10. Closing the tracker closes every held handle.
$script:Closed.Clear()
Close-ProcessCpuTracker -Tracker $tracker
Assert-True (($script:Closed -join ',') -eq '100' -and $tracker.Entries.Count -eq 0) 'all handles closed'

# Unit-check selection.
function Candidate { param([int]$Id, [string]$Name, [bool]$Stable, [AllowNull()][object]$Ratio) [pscustomobject]@{ Pid = $Id; Name = $Name; Stable = $Stable; Ratio = $Ratio } }
$rootOnly = @((Candidate 100 'app.exe' $true 1.0), (Candidate 200 'msedgewebview2.exe' $false 1.3))
$s = Select-PrivateUnitRatios -Candidates $rootOnly -RootPid 100
Assert-True ($s.Ready -and $s.Ratios.Count -eq 1 -and $s.StableChildCount -eq 0) 'general mode decides on the stable root'
$s = Select-PrivateUnitRatios -Candidates $rootOnly -RootPid 100 -RequiredChildName 'msedgewebview2.exe'
Assert-True (-not $s.Ready) 'Scenario M mode does not decide on the root alone'
$s = Select-PrivateUnitRatios -Candidates @((Candidate 100 'app.exe' $true 1.0), (Candidate 300 'conhost.exe' $true 1.0)) -RootPid 100 -RequiredChildName 'msedgewebview2.exe'
Assert-True (-not $s.Ready) 'a stable child of another name does not count'
$s = Select-PrivateUnitRatios -Candidates @((Candidate 100 'app.exe' $true 1.0), (Candidate 200 'msedgewebview2.exe' $true 1.002), (Candidate 201 'msedgewebview2.exe' $false 0.7)) -RootPid 100 -RequiredChildName 'MSEDGEWEBVIEW2.EXE'
Assert-True ($s.Ready -and $s.StableChildCount -eq 1 -and $s.Ratios.Count -eq 2) 'ready with a stable WebView2 child; root and child ratios both used'
$s = Select-PrivateUnitRatios -Candidates @((Candidate 100 'msedgewebview2.exe' $true 1.0)) -RootPid 100 -RequiredChildName 'msedgewebview2.exe'
Assert-True (-not $s.Ready) 'the root never counts as the child, whatever its name'
$s = Select-PrivateUnitRatios -Candidates @((Candidate 100 'app.exe' $true (1 / 4096.0)), (Candidate 200 'msedgewebview2.exe' $true (1 / 4096.0))) -RootPid 100 -RequiredChildName 'msedgewebview2.exe'
$threw = $false
try { Get-VerifiedPrivateUnitRatio -Ratios $s.Ratios | Out-Null } catch { $threw = $_.Exception.Message -match 'does not look like bytes' }
Assert-True ($s.Ready -and $threw) 'wrong units on a stable child still fail closed'
$s = Select-PrivateUnitRatios -Candidates @() -RootPid 100 -RequiredChildName 'msedgewebview2.exe'
Assert-True (-not $s.Ready -and $s.Ratios.Count -eq 0) 'no candidates'

# Native handle functions on real processes (Windows only).
$onWindows = $PSVersionTable.PSVersion.Major -le 5 -or (Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)
if ($onWindows) {
    $self = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $PID"
    $opened = Open-ProcessCpuHandle -ProcessInfo $self
    Assert-True ($opened.Status -eq 'Open') "own process opens with a matching creation time ($($opened.Detail))"
    $read = Read-ProcessCpuHandle -Handle $opened.Handle
    Assert-True ($read.Status -eq 'Running' -and $read.CpuSeconds -gt 0) 'own process is running with CPU time'
    $expected = (Get-Process -Id $PID).TotalProcessorTime.TotalSeconds
    Assert-True ([Math]::Abs($read.CpuSeconds - $expected) -lt 1.0) "handle CPU matches Get-Process ($($read.CpuSeconds) vs $expected)"
    Close-ProcessCpuHandle -Handle $opened.Handle

    $other = [pscustomobject]@{ ProcessId = $PID; CreationDate = ([datetime]$self.CreationDate).AddSeconds(-2) }
    Assert-True ((Open-ProcessCpuHandle -ProcessInfo $other).Status -eq 'IdentityChanged') 'a PID with another creation time is IdentityChanged'

    # A child that exits while the handle is held: final CPU stays readable.
    $start = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = 'cmd.exe /c ping -n 2 127.0.0.1 > NUL' }
    $info = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($start.ProcessId)"
    $held = Open-ProcessCpuHandle -ProcessInfo $info
    Assert-True ($held.Status -eq 'Open') 'child opens'
    $deadline = (Get-Date).AddSeconds(20)
    do { Start-Sleep -Milliseconds 200; $read = Read-ProcessCpuHandle -Handle $held.Handle } while ($read.Status -eq 'Running' -and (Get-Date) -lt $deadline)
    Assert-True ($read.Status -eq 'Exited' -and $null -ne $read.CpuSeconds) 'exited child read through the held handle'
    $none = $null
    try { $none = Get-Process -Id $start.ProcessId -ErrorAction Stop } catch { }
    Assert-True ($null -eq $none) 'Get-Process no longer finds it (the re-smoke failure mode)'
    Close-ProcessCpuHandle -Handle $held.Handle

    # The same child with no handle held: no process object is left.
    $start = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = 'cmd.exe /c exit 0' }
    $info = [pscustomobject]@{ ProcessId = $start.ProcessId; CreationDate = [datetime]::UtcNow }
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($start.ProcessId)") -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    $late = Open-ProcessCpuHandle -ProcessInfo $info
    if ($late.Status -eq 'Open') { Close-ProcessCpuHandle -Handle $late.Handle }
    Assert-True (@('ExitedUnread', 'IdentityChanged') -contains $late.Status) "exited child without a handle is ExitedUnread, or IdentityChanged if its PID was reused ($($late.Status))"
}
else {
    Write-Host 'Native handle checks skipped: not Windows.'
}

Write-Host "PASS: $script:Passed CPU tracker and unit-check selection assertions."
