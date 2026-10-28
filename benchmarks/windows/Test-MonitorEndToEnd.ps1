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
# reused-PID or unverified process), so the monitor's decisions are checked
# against real snapshots, Get-Process handles and timing. Nothing outside
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
    unverified = 'function global:Get-CimInstance { $rows = @(CimCmdlets\Get-CimInstance @args); $rows; [pscustomobject]@{ ProcessId = 4000002; ParentProcessId = [int]$env:E2E_ROOT; Name = ''msedgewebview2.exe''; CreationDate = $null; WorkingSetSize = 50MB; PrivatePageCount = 40MB; PageFileUsage = 0; CommandLine = '''' } }'
}

function Invoke-MonitorCase {
    param([string]$Name, [string]$Wrapper, [int]$Duration = 5, [int]$UnitTimeout = 30)
    $target = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList '/c', 'ping -n 30 127.0.0.1 > NUL' -PassThru -WindowStyle Hidden
    try {
        Start-Sleep -Milliseconds 500
        $out = Join-Path $OutputDirectory "$Name.csv"
        $log = Join-Path $OutputDirectory "$Name.log"
        $command = "`$ErrorActionPreference = 'Stop'; $Wrapper; try { & '$monitor' -RootPid $($target.Id) -DurationSeconds $Duration -SampleIntervalSeconds 0.5 -OutputPath '$out' -Diagnostics -UnitCheckTimeoutSeconds $UnitTimeout; exit 0 } catch { Write-Host ('MONITOR ERROR: ' + `$_.Exception.Message); exit 1 }"
        $env:E2E_ROOT = [string]$target.Id
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
        Remove-Item Env:\E2E_ROOT -ErrorAction SilentlyContinue
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

if ($failures.Count -gt 0) {
    Write-Host ("{0} passed, {1} failed:" -f $passed, $failures.Count)
    $failures | ForEach-Object { Write-Host "  $_" }
    exit 1
}
Write-Host ("PASS: {0} end-to-end monitor checks. Output kept in {1}" -f $passed, $OutputDirectory)
