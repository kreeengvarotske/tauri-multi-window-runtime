[CmdletBinding()]
param()

# Synthetic regression fixtures for the process identity, tree walk and
# startup unit check. They test the decision logic only; a native monitor
# run is still needed as evidence on a real Windows process tree.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'PrivateUnitValidation.psm1') -Force
Import-Module -Name (Join-Path $PSScriptRoot 'ProcessTreeIdentity.psm1') -Force

$script:Passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
    $script:Passed++
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$MessagePattern, [string]$Description)
    $threw = $false
    try {
        & $Action | Out-Null
    }
    catch {
        $threw = $true
        if ($_.Exception.Message -notmatch $MessagePattern) {
            throw "$Description threw the wrong error: $($_.Exception.Message)"
        }
    }
    if (-not $threw) { throw "$Description did not fail closed." }
    $script:Passed++
}

$t0 = [datetime]::new(2026, 10, 28, 9, 0, 0, [System.DateTimeKind]::Utc)

function New-Proc {
    param([int]$Id, [int]$Parent, [AllowNull()][object]$CreatedOffsetSeconds, [string]$Name = 'msedgewebview2.exe', [long]$Private = 100MB)
    $created = $null
    if ($null -ne $CreatedOffsetSeconds) { $created = $t0.AddSeconds([double]$CreatedOffsetSeconds) }
    [pscustomobject]@{ ProcessId = $Id; ParentProcessId = $Parent; Name = $Name; CreationDate = $created; PrivatePageCount = $Private; WorkingSetSize = $Private }
}

function Get-Pids { param($Tree) @($Tree.Processes | ForEach-Object { [int]$_.ProcessId } | Sort-Object) -join ',' }

# --- Identity --------------------------------------------------------------
$host1 = New-Proc -Id 100 -Parent 4 -CreatedOffsetSeconds 0 -Name 'arm-A.exe'
$key = Get-ProcessKey -ProcessInfo $host1
Assert-True ($key -eq ('100@{0}' -f $t0.Ticks)) "identity is PID@creation ticks (got $key)"
Assert-True ($null -eq (Get-ProcessKey -ProcessInfo (New-Proc -Id 5 -Parent 4 -CreatedOffsetSeconds $null))) 'unknown creation time gives no identity'

# --- Late WebView2 child: absent at first, then part of the tree -----------
$early = @($host1)
$late = @($host1, (New-Proc -Id 200 -Parent 100 -CreatedOffsetSeconds 1.5), (New-Proc -Id 201 -Parent 200 -CreatedOffsetSeconds 2.0))
$treeEarly = Get-IdentifiedProcessTree -Snapshot $early -RootPid 100 -RootKey $key
$treeLate = Get-IdentifiedProcessTree -Snapshot $late -RootPid 100 -RootKey $key
Assert-True ((Get-Pids $treeEarly) -eq '100') 'before WebView2 starts, the tree is the host only'
Assert-True ((Get-Pids $treeLate) -eq '100,200,201') 'a late WebView2 browser and its child join the tree'
Assert-True (@($treeLate.Rejected).Count -eq 0 -and @($treeLate.Unverified).Count -eq 0) 'nothing rejected or unverified in a clean tree'

# --- PID reuse: a process created before its claimed parent ----------------
# Step 1 of the #36 smoke: Edge (16488 and its children) was attached because
# Edge's parent PID equalled a PID of the tree. Here 300 is a tree process
# created at +3 s; Edge 400 claims 300 as parent but was created at -600 s,
# so it is the child of an earlier process that had PID 300.
$reuse = @(
    $host1,
    (New-Proc -Id 300 -Parent 100 -CreatedOffsetSeconds 3),
    (New-Proc -Id 400 -Parent 300 -CreatedOffsetSeconds -600 -Name 'msedge.exe'),
    (New-Proc -Id 401 -Parent 400 -CreatedOffsetSeconds -590 -Name 'msedge.exe'),
    (New-Proc -Id 301 -Parent 300 -CreatedOffsetSeconds 4)
)
$treeReuse = Get-IdentifiedProcessTree -Snapshot $reuse -RootPid 100 -RootKey $key
Assert-True ((Get-Pids $treeReuse) -eq '100,300,301') "a process created before its claimed parent is not in the tree (got $(Get-Pids $treeReuse))"
Assert-True ((@($treeReuse.Rejected) -join ',') -eq '400') 'the reused-PID child is reported as rejected'
Assert-True (-not (@($treeReuse.Processes | ForEach-Object { [int]$_.ProcessId }) -contains 401)) 'the subtree of a rejected process is cut'

# Same creation time as the parent is allowed (clock resolution).
$sameTick = @($host1, (New-Proc -Id 210 -Parent 100 -CreatedOffsetSeconds 0))
Assert-True ((Get-Pids (Get-IdentifiedProcessTree -Snapshot $sameTick -RootPid 100 -RootKey $key)) -eq '100,210') 'a child created in the same tick as its parent is kept'

# --- Root identity --------------------------------------------------------
$rootReused = @((New-Proc -Id 100 -Parent 4 -CreatedOffsetSeconds 50 -Name 'other.exe'), (New-Proc -Id 200 -Parent 100 -CreatedOffsetSeconds 51))
$treeRootReused = Get-IdentifiedProcessTree -Snapshot $rootReused -RootPid 100 -RootKey $key
Assert-True (-not $treeRootReused.RootFound) 'a new process with the root PID is not the root'
Assert-True (@($treeRootReused.Processes).Count -eq 0) 'nothing is measured under a reused root PID'
Assert-True (-not (Get-IdentifiedProcessTree -Snapshot @() -RootPid 100 -RootKey $key).RootFound) 'an exited root is not found'
Assert-True (-not (Get-IdentifiedProcessTree -Snapshot @((New-Proc -Id 100 -Parent 4 -CreatedOffsetSeconds $null)) -RootPid 100 -RootKey $null).RootFound) 'a root without creation time is not usable'

# --- Unknown or incomplete tree -------------------------------------------
$unknown = @($host1, (New-Proc -Id 220 -Parent 100 -CreatedOffsetSeconds $null), (New-Proc -Id 221 -Parent 220 -CreatedOffsetSeconds 5))
$treeUnknown = Get-IdentifiedProcessTree -Snapshot $unknown -RootPid 100 -RootKey $key
Assert-True ((Get-Pids $treeUnknown) -eq '100') 'a child with unknown creation time is not summed'
Assert-True ((@($treeUnknown.Unverified) -join ',') -eq '220') 'it is reported as unverified, so the row is marked incomplete'
Assert-True (-not (@($treeUnknown.Processes | ForEach-Object { [int]$_.ProcessId }) -contains 221)) 'nothing below an unverified process is summed'

# --- Short-lived child that is really in the tree --------------------------
$before = @($host1, (New-Proc -Id 200 -Parent 100 -CreatedOffsetSeconds 1))
$during = @($host1, (New-Proc -Id 200 -Parent 100 -CreatedOffsetSeconds 1), (New-Proc -Id 230 -Parent 200 -CreatedOffsetSeconds 40 -Private 20MB))
$after = $before
$keysDuring = @((Get-IdentifiedProcessTree -Snapshot $during -RootPid 100 -RootKey $key).Processes | ForEach-Object { Get-ProcessKey -ProcessInfo $_ })
Assert-True ($keysDuring -contains ('230@{0}' -f $t0.AddSeconds(40).Ticks)) 'a short-lived child is in the sample where it is seen, with its own identity'
Assert-True ((Get-Pids (Get-IdentifiedProcessTree -Snapshot $after -RootPid 100 -RootKey $key)) -eq '100,200') 'it leaves the tree when it exits'
# A later, different process with PID 230 has another identity, so its CPU
# time is never subtracted from the earlier process's.
$reused230 = New-Proc -Id 230 -Parent 200 -CreatedOffsetSeconds 90
Assert-True ((Get-ProcessKey -ProcessInfo $reused230) -ne ('230@{0}' -f $t0.AddSeconds(40).Ticks)) 'a reused PID gets a new identity'

# --- Test-SameProcess ------------------------------------------------------
$fakeProcess = [pscustomobject]@{ StartTime = $t0.AddSeconds(0.2).ToLocalTime() }
Assert-True (Test-SameProcess -ProcessInfo $host1 -Process $fakeProcess) 'same process when start time matches creation time'
$otherProcess = [pscustomobject]@{ StartTime = $t0.AddSeconds(30).ToLocalTime() }
Assert-True (-not (Test-SameProcess -ProcessInfo $host1 -Process $otherProcess)) 'a handle to a newer process with the same PID is rejected'
$unreadable = New-Object psobject
$unreadable | Add-Member -MemberType ScriptProperty -Name StartTime -Value { throw 'Access is denied' }
Assert-True (-not (Test-SameProcess -ProcessInfo $host1 -Process $unreadable)) 'an unreadable start time is not taken as the same process'
Assert-True (-not (Test-SameProcess -ProcessInfo $host1 -Process $null)) 'no handle is not the same process'

# --- Startup unit check ----------------------------------------------------
function New-UnitInput { param([string]$Key, [AllowNull()][object]$Cim, [AllowNull()][object]$Proc) [pscustomobject]@{ Key = $Key; Cim = $Cim; Proc = $Proc } }
function ConvertTo-Previous { param([object[]]$Items) $map = @{}; foreach ($i in $Items) { $map[$i.Key] = $i }; $map }

# WebView2 startup: memory grows between samples and the reads are skewed, so
# the instantaneous ratio is far from 1 (smoke: 0.8733, 0.7959, 0.5140).
$growing1 = @((New-UnitInput 'a' 100MB 100MB), (New-UnitInput 'b' 40MB 50MB))
$growing2 = @((New-UnitInput 'a' 101MB 100.5MB), (New-UnitInput 'b' 80MB 155.6MB))
$first = @(Get-StablePrivateUnitRatios -Current $growing1 -Previous @{})
Assert-True (@($first | Where-Object { $_.Stable }).Count -eq 0) 'the first sample has no previous value, so nothing is stable'
$second = @(Get-StablePrivateUnitRatios -Current $growing2 -Previous (ConvertTo-Previous $growing1))
Assert-True (-not $second[1].Stable) 'a growing WebView2 process (ratio 0.514) is not used for the unit check'
Assert-True ($second[0].Stable) 'a process within 1 % of its previous values is used'
$stableRatios = [double[]]@($second | Where-Object { $_.Stable } | ForEach-Object { $_.Ratio })
Assert-True ([Math]::Abs((Get-VerifiedPrivateUnitRatio -Ratios $stableRatios) - 1.0) -lt 0.01) 'stable processes confirm bytes'

# Nothing stable yet: no decision, the caller keeps waiting until its timeout.
$stillGrowing = @((New-UnitInput 'a' 130MB 140MB))
$none = @(Get-StablePrivateUnitRatios -Current $stillGrowing -Previous (ConvertTo-Previous @((New-UnitInput 'a' 100MB 100MB))))
Assert-True (@($none | Where-Object { $_.Stable }).Count -eq 0) 'no stable process means no ratio, not a pass'
Assert-Throws { Get-VerifiedPrivateUnitRatio -Ratios ([double[]]@($none | Where-Object { $_.Stable } | ForEach-Object { $_.Ratio })) } 'unit is unverified|Could not compare' 'an empty stable set at the timeout'

# A real unit mismatch on stable processes still fails closed.
$pages1 = @((New-UnitInput 'a' 25600 100MB), (New-UnitInput 'b' 12800 50MB))
$pages2 = @((New-UnitInput 'a' 25610 100.1MB), (New-UnitInput 'b' 12800 50MB))
$pageRatios = [double[]]@(Get-StablePrivateUnitRatios -Current $pages2 -Previous (ConvertTo-Previous $pages1) | Where-Object { $_.Stable } | ForEach-Object { $_.Ratio })
Assert-True ($pageRatios.Count -eq 2) 'stable processes with page-sized values are evaluated'
Assert-Throws { Get-VerifiedPrivateUnitRatio -Ratios $pageRatios } 'does not look like bytes' 'a stable page-count unit'

# Stable but off by 15 %: the 0.9-1.1 band is unchanged, so this fails.
$off1 = @((New-UnitInput 'a' 85MB 100MB))
$off2 = @((New-UnitInput 'a' 85MB 100MB))
$offRatios = [double[]]@(Get-StablePrivateUnitRatios -Current $off2 -Previous (ConvertTo-Previous $off1) | Where-Object { $_.Stable } | ForEach-Object { $_.Ratio })
Assert-Throws { Get-VerifiedPrivateUnitRatio -Ratios $offRatios } 'does not look like bytes' 'a stable ratio of 0.85'

# Missing values and a different identity are never stable.
$missing = @(Get-StablePrivateUnitRatios -Current @((New-UnitInput 'a' $null 100MB)) -Previous (ConvertTo-Previous @((New-UnitInput 'a' 100MB 100MB))))
Assert-True (-not $missing[0].Stable) 'a missing CIM value is not stable'
$newIdentity = @(Get-StablePrivateUnitRatios -Current @((New-UnitInput 'a2' 100MB 100MB)) -Previous (ConvertTo-Previous @((New-UnitInput 'a' 100MB 100MB))))
Assert-True (-not $newIdentity[0].Stable) 'a process is compared only with its own previous sample'
$noKey = @(Get-StablePrivateUnitRatios -Current @((New-UnitInput $null 100MB 100MB)) -Previous @{})
Assert-True (-not $noKey[0].Stable) 'a process without identity is not stable'

Write-Host ("PASS: {0} process identity, tree and unit-check assertions (PowerShell {1})." -f $script:Passed, $PSVersionTable.PSVersion)
