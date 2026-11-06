[CmdletBinding()]
param(
    # Processes per accuracy case.
    [ValidateRange(1, 64)]
    [int]$Children = 12,
    [string]$OutputPath
)

# Spike checks for JobCpuAccounting.psm1 on real Windows processes (no
# elevation). Each case compares the job's CPU accounting with an
# independent reference: CPU time read through a handle held from the
# moment each process was created.
#   1. accuracy: short processes that exit before any sampler could read
#      them; job CPU vs the sum of the references, per process count;
#   2. tree: a root that starts its own short children (no handle held by
#      the harness); job membership vs the ParentProcessId tree sampled
#      every 0.5 s, and how many processes such sampling never sees;
#   3. overhead: the cost of one accounting query.
# Writes a JSON summary to OutputPath when given. Exits 1 on a failed check.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'JobCpuAccounting.psm1') -Force
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'ProcessTreeIdentity.psm1') -Force

$failures = New-Object System.Collections.Generic.List[string]
$passed = 0
function Check {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { $script:passed++; Write-Host "ok   $Name $Detail" }
    else { $script:failures.Add("$Name $Detail"); Write-Host "FAIL $Name $Detail" }
}
$culture = [System.Globalization.CultureInfo]::InvariantCulture
$cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
Write-Host ("OS: {0}; PowerShell: {1}" -f [Environment]::OSVersion.VersionString, $PSVersionTable.PSVersion)
$summary = [ordered]@{ os = [Environment]::OSVersion.VersionString; powershell = $PSVersionTable.PSVersion.ToString() }

# 1. Accuracy against handles held from creation.
$job = New-CpuJob
$handles = New-Object System.Collections.Generic.List[object]
for ($i = 1; $i -le $Children; $i++) {
    # A busy loop of a few to a few hundred milliseconds; no console, so no conhost.
    $loops = 2000 * $i
    $handles.Add((Start-ProcessInCpuJob -Job $job -CommandLine "`"$cmd`" /d /c for /L %i in (1,1,$loops) do @rem" -DetachedConsole))
}
foreach ($h in $handles) { [void](Wait-HeldProcess -Handle $h.Handle -TimeoutMilliseconds 120000) }
$reference = 0.0
$perProcess = New-Object System.Collections.Generic.List[double]
foreach ($h in $handles) {
    $cpu = Get-HeldProcessCpu -Handle $h.Handle
    $reference += $cpu.CpuSeconds
    $perProcess.Add($cpu.CpuSeconds)
    Close-JobCpuHandle -Handle $h.Handle
}
$accounting = Get-CpuJobAccounting -Job $job
$difference = $accounting.CpuSeconds - $reference
Check 'accuracy: every process was counted by the job' ($accounting.TotalProcesses -eq $Children -and $accounting.TerminatedProcesses -eq $Children -and $accounting.ActiveProcesses -eq 0) ("total {0}, terminated {1}, active {2}" -f $accounting.TotalProcesses, $accounting.TerminatedProcesses, $accounting.ActiveProcesses)
Check 'accuracy: job CPU equals the held-handle reference' ([Math]::Abs($difference) -le 0.0000001 * $Children) ("job {0} s, reference {1} s, difference {2} s" -f $accounting.CpuSeconds.ToString('F7', $culture), $reference.ToString('F7', $culture), $difference.ToString('F7', $culture))
Check 'accuracy: the children used CPU' ($reference -gt 0) ("min {0} s, max {1} s per process" -f ($perProcess | Measure-Object -Minimum).Minimum.ToString('F4', $culture), ($perProcess | Measure-Object -Maximum).Maximum.ToString('F4', $culture))
Close-JobCpuHandle -Handle $job
$summary.accuracy = [ordered]@{ processes = $Children; jobCpuSeconds = $accounting.CpuSeconds; referenceCpuSeconds = $reference; differenceSeconds = $difference; jobTotalProcesses = $accounting.TotalProcesses }

# 2. Tree: the root starts short children itself; the harness holds only the root's handle.
$job = New-CpuJob
$inner = 8
# Each round: a cmd that busy-loops for a few milliseconds (usually never
# sampled), then a ping that lives about 1 s (usually sampled). The quotes
# keep the inner parentheses out of the outer block. The root shares this
# console, so no conhost.exe is started for it.
$root = Start-ProcessInCpuJob -Job $job -CommandLine "`"$cmd`" /d /c for /L %n in (1,1,$inner) do @(`"$cmd`" /d /c `"for /L %i in (1,1,3000) do @rem`" & ping -n 2 127.0.0.1 > NUL)"
$rootInfo = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($root.Pid)"
$rootKey = Get-ProcessKey -ProcessInfo $rootInfo
$seen = New-Object 'System.Collections.Generic.HashSet[string]'
$treeNotInJob = New-Object System.Collections.Generic.List[string]
$jobNotInTree = New-Object System.Collections.Generic.List[string]
$samples = 0
while (-not (Wait-HeldProcess -Handle $root.Handle -TimeoutMilliseconds 0)) {
    $snapshot = @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, Name, CreationDate)
    $jobIds = @(Get-CpuJobProcessIds -Job $job)
    $tree = Get-IdentifiedProcessTree -Snapshot $snapshot -RootPid $root.Pid -RootKey $rootKey
    if ($tree.RootFound) {
        $treeIds = @($tree.Processes | ForEach-Object { [int]$_.ProcessId })
        foreach ($p in $tree.Processes) { [void]$seen.Add((Get-ProcessKey -ProcessInfo $p)) }
        foreach ($id in $treeIds) { if ($jobIds -notcontains $id) { $treeNotInJob.Add("S$samples`:$id") } }
        foreach ($id in $jobIds) { if ($treeIds -notcontains $id) { $jobNotInTree.Add("S$samples`:$id") } }
    }
    $samples++
    Start-Sleep -Milliseconds 500
}
Start-Sleep -Milliseconds 200
$accounting = Get-CpuJobAccounting -Job $job
$rootCpu = Get-HeldProcessCpu -Handle $root.Handle
$expected = 1 + 2 * $inner
# A console host is added only if this harness has no console; it is in the job too.
Check 'tree: the job counted the root and every descendant' ($accounting.TotalProcesses -ge $expected -and $accounting.TotalProcesses -le $expected + 1 -and $accounting.ActiveProcesses -eq 0) ("total {0} (expected {1}, or {2} with a console host), active {3}" -f $accounting.TotalProcesses, $expected, ($expected + 1), $accounting.ActiveProcesses)
Check 'tree: every process the tree walk saw was in the job' ($treeNotInJob.Count -eq 0) ($treeNotInJob -join ' ')
Check 'tree: the job CPU covers more than the root alone' ($accounting.CpuSeconds -ge $rootCpu.CpuSeconds) ("job {0} s, root {1} s" -f $accounting.CpuSeconds.ToString('F4', $culture), $rootCpu.CpuSeconds.ToString('F4', $culture))
$neverSeen = $accounting.TotalProcesses - $seen.Count
Write-Host ("info tree: {0} samples at 0.5 s saw {1} of {2} processes; {3} were never seen by sampling but are in the job CPU. Job PIDs not yet in the tree walk (created between the two reads): {4}" -f $samples, $seen.Count, $accounting.TotalProcesses, $neverSeen, ($jobNotInTree -join ' '))
Close-JobCpuHandle -Handle $root.Handle
Close-JobCpuHandle -Handle $job
$summary.tree = [ordered]@{ samples = $samples; seenBySampling = $seen.Count; jobTotalProcesses = $accounting.TotalProcesses; neverSeen = $neverSeen; jobCpuSeconds = $accounting.CpuSeconds; rootCpuSeconds = $rootCpu.CpuSeconds; treeNotInJob = @($treeNotInJob); jobNotInTree = @($jobNotInTree) }

# 3. Overhead of one accounting query.
$job = New-CpuJob
$watch = [System.Diagnostics.Stopwatch]::StartNew()
$calls = 2000
for ($i = 0; $i -lt $calls; $i++) { [void](Get-CpuJobAccounting -Job $job) }
$watch.Stop()
$perCallMs = $watch.Elapsed.TotalMilliseconds / $calls
Close-JobCpuHandle -Handle $job
Check 'overhead: one query well under the 1 s sample interval' ($perCallMs -lt 5) ("{0} ms per call including PowerShell" -f $perCallMs.ToString('F4', $culture))
$summary.overhead = [ordered]@{ calls = $calls; millisecondsPerCall = $perCallMs }

if ($OutputPath) { $summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding UTF8 }
if ($failures.Count -gt 0) {
    Write-Host ("{0} passed, {1} failed:" -f $passed, $failures.Count)
    $failures | ForEach-Object { Write-Host "  $_" }
    exit 1
}
Write-Host "PASS: $passed job CPU accounting checks."
exit 0
