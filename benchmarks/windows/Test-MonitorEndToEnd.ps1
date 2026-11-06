[CmdletBinding()]
param(
    # Where the CSVs of each case are written; a new folder per run.
    [string]$OutputDirectory = (Join-Path ([System.IO.Path]::GetTempPath()) ("monitor-e2e-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))),
    [string]$PowerShellExe = (Get-Process -Id $PID).Path
)

# End-to-end cases for Measure-ProcessTree.ps1 on a real Windows process
# tree (cmd.exe running ping). Each case runs the monitor in a fresh
# PowerShell process. The controlled cases wrap the real Get-CimInstance and
# change its output in one way (a wrong unit, growing memory, an injected
# older process claiming the root as parent, a process with no creation
# time, a PID that no longer exists or names another process), so the
# monitor's decisions are checked against real snapshots, handles and timing. Nothing outside
# OutputDirectory is written; nothing is deleted.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$monitor = Join-Path $PSScriptRoot 'Measure-ProcessTree.ps1'
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$failures = New-Object System.Collections.Generic.List[string]
$passed = 0

function Check {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { $script:passed++; Write-Host "ok   $Name" }
    else { $script:failures.Add("$Name $Detail"); Write-Host "FAIL $Name $Detail" }
}

# The wrapper is defined in the child process before the monitor runs. A
# function shadows the cmdlet of the same name; the real cmdlet is called
# with its module-qualified name.
# Snapshot rows are copied to plain objects before a value is changed, so
# the real CIM instances are never modified.
$prelude = 'function global:Copy-ProcessRow { param($p, $private) [pscustomobject]@{ ProcessId = $p.ProcessId; ParentProcessId = $p.ParentProcessId; Name = $p.Name; CreationDate = $p.CreationDate; WorkingSetSize = $p.WorkingSetSize; PrivatePageCount = $private; PageFileUsage = $p.PageFileUsage; CommandLine = $p.CommandLine } }'
$wrappers = @{
    none       = ''
    pages      = $prelude + '; function global:Get-CimInstance { CimCmdlets\Get-CimInstance @args | ForEach-Object { $v = $_.PrivatePageCount; if ($null -ne $v) { $v = [uint64][Math]::Floor([double]$v / 4096) }; Copy-ProcessRow $_ $v } }'
    growing    = $prelude + '; $global:calls = 0; function global:Get-CimInstance { $global:calls++; $f = 1.0 + 0.05 * $global:calls; CimCmdlets\Get-CimInstance @args | ForEach-Object { $v = $_.PrivatePageCount; if ($null -ne $v) { $v = [uint64]([double]$v * $f) }; Copy-ProcessRow $_ $v } }'
    reuse      = 'function global:Get-CimInstance { $rows = @(CimCmdlets\Get-CimInstance @args); $root = @($rows | Where-Object { [int]$_.ProcessId -eq [int]$env:E2E_ROOT })[0]; $rows; [pscustomobject]@{ ProcessId = 4000001; ParentProcessId = [int]$env:E2E_ROOT; Name = ''msedge.exe''; CreationDate = ([datetime]$root.CreationDate).AddHours(-3); WorkingSetSize = 300MB; PrivatePageCount = 200MB; PageFileUsage = 0; CommandLine = '''' } }'
    # A tree process that is gone before its CPU can be read, and a PID that
    # already names another process (this harness) with a different creation time.
    gone       = 'function global:Get-CimInstance { $rows = @(CimCmdlets\Get-CimInstance @args); $root = @($rows | Where-Object { [int]$_.ProcessId -eq [int]$env:E2E_ROOT })[0]; $rows; [pscustomobject]@{ ProcessId = 4000003; ParentProcessId = [int]$env:E2E_ROOT; Name = ''msedgewebview2.exe''; CreationDate = ([datetime]$root.CreationDate).AddSeconds(1); WorkingSetSize = 1MB; PrivatePageCount = 1MB; PageFileUsage = 0; CommandLine = '''' } }'
    reused     = 'function global:Get-CimInstance { $rows = @(CimCmdlets\Get-CimInstance @args); $root = @($rows | Where-Object { [int]$_.ProcessId -eq [int]$env:E2E_ROOT })[0]; $rows; [pscustomobject]@{ ProcessId = [int]$env:E2E_OTHER; ParentProcessId = [int]$env:E2E_ROOT; Name = ''msedgewebview2.exe''; CreationDate = ([datetime]$root.CreationDate).AddSeconds(1); WorkingSetSize = 1MB; PrivatePageCount = 1MB; PageFileUsage = 0; CommandLine = '''' } }'
    unverified = 'function global:Get-CimInstance { $rows = @(CimCmdlets\Get-CimInstance @args); $rows; [pscustomobject]@{ ProcessId = 4000002; ParentProcessId = [int]$env:E2E_ROOT; Name = ''msedgewebview2.exe''; CreationDate = $null; WorkingSetSize = 50MB; PrivatePageCount = 40MB; PageFileUsage = 0; CommandLine = '''' } }'
}

function Invoke-MonitorCase {
    param([string]$Name, [string]$Wrapper, [int]$Duration = 5, [int]$UnitTimeout = 30, [string]$TargetCommand = 'ping -n 30 127.0.0.1 > NUL', [string]$ExtraArguments = '')
    $target = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList '/c', $TargetCommand -PassThru -WindowStyle Hidden
    try {
        Start-Sleep -Milliseconds 500
        $out = Join-Path $OutputDirectory "$Name.csv"
        $log = Join-Path $OutputDirectory "$Name.log"
        $command = "`$ErrorActionPreference = 'Stop'; $Wrapper; try { & '$monitor' -RootPid $($target.Id) -DurationSeconds $Duration -SampleIntervalSeconds 0.5 -OutputPath '$out' -Diagnostics -UnitCheckTimeoutSeconds $UnitTimeout $ExtraArguments; exit 0 } catch { Write-Host ('MONITOR ERROR: ' + `$_.Exception.Message); exit 1 }"
        $env:E2E_ROOT = [string]$target.Id
        $env:E2E_OTHER = [string]$PID
        & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -Command $command *> $log
        $exit = $LASTEXITCODE
        [pscustomobject]@{
            Exit      = $exit
            RootPid   = $target.Id
            Csv       = $out
            UnitCheck = [System.IO.Path]::ChangeExtension($out, '.unitcheck.csv')
            Log       = (Get-Content -LiteralPath $log -Raw)
        }
    }
    finally {
        Remove-Item Env:\E2E_ROOT, Env:\E2E_OTHER -ErrorAction SilentlyContinue
        if (Get-Process -Id $target.Id -ErrorAction SilentlyContinue) { Stop-Process -Id $target.Id -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host ("OS: {0}; PowerShell: {1} ({2})" -f [Environment]::OSVersion.VersionString, $PSVersionTable.PSVersion, $PowerShellExe)
Write-Host "Output: $OutputDirectory"

# 1. Real tree, no change: passes the unit check, records identities.
$r = Invoke-MonitorCase -Name 'plain' -Wrapper $wrappers.none
Check 'plain: exit 0' ($r.Exit -eq 0) $r.Log
Check 'plain: measurement CSV written' (Test-Path -LiteralPath $r.Csv)
Check 'plain: unit-check CSV written' (Test-Path -LiteralPath $r.UnitCheck)
Check 'plain: unit check passed on stable processes' ($r.Log -match 'unit check: median ratio to PrivateMemorySize64 = 1\.0\d* over \d+ stable processes')
if (Test-Path -LiteralPath $r.Csv) {
    $rows = @(Import-Csv -LiteralPath $r.Csv)
    Check 'plain: rows' ($rows.Count -ge 3) "$($rows.Count)"
    Check 'plain: root identity first in every row' (@($rows | Where-Object { -not ([string]$_.ProcessKeys).StartsWith("$($r.RootPid)@") }).Count -eq 0)
    Check 'plain: root identity constant' (@($rows | ForEach-Object { ([string]$_.ProcessKeys).Split(';')[0] } | Sort-Object -Unique).Count -eq 1)
    Check 'plain: no rejected or unverified process' (@($rows | Where-Object { [int]$_.RejectedPidReuseCount -ne 0 -or [int]$_.UnverifiedProcessCount -ne 0 }).Count -eq 0)
    Check 'plain: no msedge in the tree' (@($rows | Where-Object { [string]$_.ProcessTree -match 'msedge' }).Count -eq 0)
    $diagnostics = [System.IO.Path]::ChangeExtension($r.Csv, '.diagnostics.csv')
    Check 'plain: diagnostics carry ProcessKey' ((Test-Path -LiteralPath $diagnostics) -and $null -ne (@(Import-Csv -LiteralPath $diagnostics)[0].PSObject.Properties['ProcessKey']))
    Check 'plain: every CPU read' (@($rows | Where-Object { [int]$_.CpuUnreadableCount -ne 0 }).Count -eq 0)
    Check 'plain: CPU reason columns' ($null -ne $rows[0].PSObject.Properties['CpuExitedUnreadCount'] -and $null -ne $rows[0].PSObject.Properties['CpuIdentityChangedCount'] -and $null -ne $rows[0].PSObject.Properties['CpuAccessDeniedCount'] -and $null -ne $rows[0].PSObject.Properties['CpuExitedReadCount'])
    Check 'plain: diagnostics CpuState Running' ((Test-Path -LiteralPath $diagnostics) -and @(Import-Csv -LiteralPath $diagnostics | Where-Object { $_.CpuState -ne 'Running' }).Count -eq 0)
}

# 2. Controlled unit mismatch on real, stable processes: fail closed.
$r = Invoke-MonitorCase -Name 'pages' -Wrapper $wrappers.pages
Check 'pages: exit 1' ($r.Exit -eq 1) $r.Log
Check 'pages: no measurement CSV' (-not (Test-Path -LiteralPath $r.Csv))
Check 'pages: unit-check CSV kept' (Test-Path -LiteralPath $r.UnitCheck)
Check 'pages: reports the wrong unit' ($r.Log -match 'does not look like bytes')

# 3. Memory that never stabilizes: no decision within the timeout, fail closed.
$r = Invoke-MonitorCase -Name 'growing' -Wrapper $wrappers.growing -Duration 10 -UnitTimeout 3
Check 'growing: exit 1' ($r.Exit -eq 1) $r.Log
Check 'growing: no measurement CSV' (-not (Test-Path -LiteralPath $r.Csv))
Check 'growing: unit-check CSV kept' (Test-Path -LiteralPath $r.UnitCheck)
Check 'growing: reports no stable process' ($r.Log -match 'No process of the tree had stable private memory')
if (Test-Path -LiteralPath $r.UnitCheck) {
    Check 'growing: no row was stable' (@(Import-Csv -LiteralPath $r.UnitCheck | Where-Object { $_.Stable -eq 'True' }).Count -eq 0)
}

# 4. A process that names the root as parent but is 3 h older (PID reuse).
$r = Invoke-MonitorCase -Name 'reuse' -Wrapper $wrappers.reuse
Check 'reuse: exit 0' ($r.Exit -eq 0) $r.Log
if (Test-Path -LiteralPath $r.Csv) {
    $rows = @(Import-Csv -LiteralPath $r.Csv)
    Check 'reuse: the older process is rejected in every row' (@($rows | Where-Object { [string]$_.RejectedPidReuseIds -ne '4000001' }).Count -eq 0)
    Check 'reuse: it is not in the tree or the sums' (@($rows | Where-Object { [string]$_.ProcessIds -match '(^|;)4000001(;|$)' }).Count -eq 0)
    Check 'reuse: its 200 MB are not summed' (@($rows | Where-Object { [double]::Parse($_.PrivateBytesMB, [System.Globalization.CultureInfo]::InvariantCulture) -ge 200 }).Count -eq 0)
}

# 5. A child whose creation time cannot be read: left out and reported.
$r = Invoke-MonitorCase -Name 'unverified' -Wrapper $wrappers.unverified
Check 'unverified: exit 0' ($r.Exit -eq 0) $r.Log
if (Test-Path -LiteralPath $r.Csv) {
    $rows = @(Import-Csv -LiteralPath $r.Csv)
    Check 'unverified: reported in every row' (@($rows | Where-Object { [int]$_.UnverifiedProcessCount -ne 1 -or [string]$_.UnverifiedProcessIds -ne '4000002' }).Count -eq 0)
    Check 'unverified: not summed' (@($rows | Where-Object { [string]$_.ProcessIds -match '(^|;)4000002(;|$)' }).Count -eq 0)
}

# 6. A child exits during the run: its final CPU is read through the held
# handle and counted; the next child, created later, is counted whole.
$r = Invoke-MonitorCase -Name 'exits' -Wrapper $wrappers.none -Duration 6 -TargetCommand 'ping -n 3 127.0.0.1 > NUL & ping -n 30 127.0.0.1 > NUL'
Check 'exits: exit 0' ($r.Exit -eq 0) $r.Log
if (Test-Path -LiteralPath $r.Csv) {
    $rows = @(Import-Csv -LiteralPath $r.Csv)
    Check 'exits: no unreadable CPU' (@($rows | Where-Object { [int]$_.CpuUnreadableCount -ne 0 }).Count -eq 0)
    Check 'exits: the first ping is read after it exits' (@($rows | Where-Object { [int]$_.CpuExitedReadCount -gt 0 }).Count -ge 1)
    Check 'exits: the second ping is counted from its start' (@($rows | Where-Object { [int]$_.CpuNewCountedCount -gt 0 }).Count -ge 1)
    $diagnostics = [System.IO.Path]::ChangeExtension($r.Csv, '.diagnostics.csv')
    Check 'exits: diagnostics row with the final CPU' (@(Import-Csv -LiteralPath $diagnostics | Where-Object { $_.CpuState -eq 'Exited' -and $_.ProcTotalProcessorSeconds -ne '' }).Count -ge 1)
}

# 7. A tree process gone before its CPU could be read: missing, not zero.
$r = Invoke-MonitorCase -Name 'gone' -Wrapper $wrappers.gone
Check 'gone: exit 0' ($r.Exit -eq 0) $r.Log
if (Test-Path -LiteralPath $r.Csv) {
    $rows = @(Import-Csv -LiteralPath $r.Csv)
    Check 'gone: ExitedUnread in every row' (@($rows | Where-Object { [string]$_.CpuExitedUnreadIds -ne '4000003' -or [int]$_.CpuUnreadableCount -ne 1 }).Count -eq 0)
    Check 'gone: not reported as another reason' (@($rows | Where-Object { [int]$_.CpuIdentityChangedCount -ne 0 -or [int]$_.CpuAccessDeniedCount -ne 0 }).Count -eq 0)
}

# 8. A PID that names a process with another creation time: IdentityChanged.
$r = Invoke-MonitorCase -Name 'reused' -Wrapper $wrappers.reused
Check 'reused: exit 0' ($r.Exit -eq 0) $r.Log
if (Test-Path -LiteralPath $r.Csv) {
    $rows = @(Import-Csv -LiteralPath $r.Csv)
    Check 'reused: IdentityChanged in every row' (@($rows | Where-Object { [int]$_.CpuIdentityChangedCount -ne 1 -or [int]$_.CpuUnreadableCount -ne 1 -or [int]$_.CpuExitedUnreadCount -ne 0 }).Count -eq 0)
}

# 9-11. Unit check that requires a stable child (Scenario M mode).
$r = Invoke-MonitorCase -Name 'child' -Wrapper $wrappers.none -ExtraArguments '-UnitCheckRequireChildName PING.EXE'
Check 'child: exit 0' ($r.Exit -eq 0) $r.Log
Check 'child: decided with a stable child' ($r.Log -match '\(([1-9]\d*) stable child processes\)')
$r = Invoke-MonitorCase -Name 'child-missing' -Wrapper $wrappers.none -Duration 10 -UnitTimeout 3 -ExtraArguments '-UnitCheckRequireChildName msedgewebview2.exe'
Check 'child-missing: exit 1' ($r.Exit -eq 1) $r.Log
Check 'child-missing: no measurement CSV' (-not (Test-Path -LiteralPath $r.Csv))
Check 'child-missing: unit-check CSV kept' (Test-Path -LiteralPath $r.UnitCheck)
Check 'child-missing: names the missing child' ($r.Log -match 'No child process named msedgewebview2.exe')
$r = Invoke-MonitorCase -Name 'child-pages' -Wrapper $wrappers.pages -ExtraArguments '-UnitCheckRequireChildName PING.EXE'
Check 'child-pages: exit 1' ($r.Exit -eq 1) $r.Log
Check 'child-pages: no measurement CSV' (-not (Test-Path -LiteralPath $r.Csv))
Check 'child-pages: reports the wrong unit' ($r.Log -match 'does not look like bytes')

if ($failures.Count -gt 0) {
    Write-Host ("{0} passed, {1} failed:" -f $passed, $failures.Count)
    $failures | ForEach-Object { Write-Host "  $_" }
    exit 1
}
Write-Host ("PASS: {0} end-to-end monitor checks. Output kept in {1}" -f $passed, $OutputDirectory)
# The last case's monitor exits with 1 on purpose; without this the runner
# would take that $LASTEXITCODE as the result of this script.
exit 0
