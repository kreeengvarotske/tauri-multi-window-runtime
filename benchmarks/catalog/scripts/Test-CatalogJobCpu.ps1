<#
.SYNOPSIS
Native checks of CatalogJobCpu.ps1 on real Windows processes (no elevation).

.DESCRIPTION
Each case uses its own job, as the runner does for each run:
  1. correct completion: a root that starts short children and exits; the
     job counts every process, all have exited, the messages are complete and
     match the counters, the root is a member by its identity, the job has
     kill-on-close and no breakaway;
  2. a short process between two samples: started and exited between two job
     rows; the CPU difference between the rows equals the process's CPU read
     through a handle held from creation (within one 15.625 ms tick), and its
     new and exit messages fall between the rows;
  3. a failed assignment: a job handle without assign access; the start
     reports the error and the process is ended before it ran; the job counts
     nothing;
  4. a foreign process: started outside the job; not a member by identity, its
     CPU is not in the job, and terminating the job leaves it running;
  5. leftovers: a process that outlives the root is ended by terminating the
     job (or by closing it, kill on close); the job then has no active process.
Windows PowerShell 5.1 and PowerShell 7. Exits 1 on a failed check.
#>
[CmdletBinding()]
param([string]$OutputPath)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CatalogJobCpu.ps1')
$culture = [System.Globalization.CultureInfo]::InvariantCulture
$failures = New-Object System.Collections.Generic.List[string]
$passed = 0
function Check {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { $script:passed++; Write-Host "ok   $Name $Detail" }
    else { $script:failures.Add("$Name $Detail"); Write-Host "FAIL $Name $Detail" }
}
$cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
$ping = Join-Path $env:SystemRoot 'System32\PING.EXE'
$cwd = (Get-Location).Path
$tick = 0.015625
$summary = [ordered]@{ os = [Environment]::OSVersion.VersionString; powershell = $PSVersionTable.PSVersion.ToString() }
Write-Host ("OS: {0}; PowerShell: {1}" -f $summary.os, $summary.powershell)
Initialize-CatalogJobNative

function Wait-JobIdle {
    param([object]$Job, [int]$Seconds = 30)
    $end = (Get-Date).AddSeconds($Seconds)
    while ($Job.Accounting()[3] -gt 0 -and (Get-Date) -lt $end) { Start-Sleep -Milliseconds 100 }
    Start-Sleep -Milliseconds 300
}

function Get-Key {
    param([IntPtr]$Process)
    $t = [TmwrCatalogJob]::ProcessTimes($Process)
    "{0}@{1}" -f [TmwrCatalogJob]::ProcessIdOf($Process), $t[1]
}

# 1. Correct completion.
$job = New-CatalogJob
try {
    Check 'completion: kill on close, no breakaway' ((($job.LimitFlags -band [TmwrCatalogJob]::KillOnJobClose) -ne 0) -and (($job.LimitFlags -band ([TmwrCatalogJob]::BreakawayOk -bor [TmwrCatalogJob]::SilentBreakawayOk)) -eq 0)) ('0x{0:X}' -f $job.LimitFlags)
    $children = 3
    $root = Start-CatalogJobProcess -Job $job -CommandLine "`"$cmd`" /d /c for /L %n in (1,1,$children) do @`"$cmd`" /d /c `"for /L %i in (1,1,3000) do @rem`"" -WorkingDirectory $cwd
    $rootKey = Get-Key $root.Process
    [void][TmwrCatalogJob]::WaitExit($root.Process, 60000)
    Wait-JobIdle $job
    $a = $job.Accounting()
    $messages = @(ConvertTo-CatalogJobMessageRows $job.Messages())
    $new = @($messages | Where-Object { $_.Message -eq 6 }).Count
    $exits = @($messages | Where-Object { $_.Message -eq 7 -or $_.Message -eq 8 }).Count
    $zero = @($messages | Where-Object { $_.Message -eq 4 }).Count
    # A console host is added only if this harness has no console; it is in the job too.
    Check 'completion: the job counted the root and every child' ($a[2] -ge 1 + $children -and $a[2] -le 2 + $children -and $a[3] -eq 0) ("total {0}, active {1}" -f $a[2], $a[3])
    Check 'completion: one new and one exit message per process, and active-zero' ($new -eq $a[2] -and $exits -eq $a[2] -and $zero -ge 1) ("new {0}, exits {1}, active-zero {2}" -f $new, $exits, $zero)
    $membership = Get-CatalogJobMembership -Messages $messages -MonitorKeys @($rootKey)
    Check 'completion: the root is a member by its identity' ($membership.InJob -eq 1) $rootKey
    Check 'completion: the root exited with code 0' ([TmwrCatalogJob]::ExitCode($root.Process) -eq 0)
    [TmwrCatalogJob]::Close($root.Process)
    $summary.completion = [ordered]@{ total = $a[2]; newMessages = $new; exitMessages = $exits; activeZero = $zero; cpuSeconds = ($a[0] + $a[1]) / 1e7 }
}
finally { $job.Dispose() }

# 2. A short process between two samples, against a handle held from creation.
$job = New-CatalogJob
try {
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $differences = New-Object System.Collections.Generic.List[double]
    $between = $true
    for ($i = 1; $i -le 5; $i++) {
        $before = Read-CatalogJobRow -Job $job -Stopwatch $stopwatch
        $short = Start-CatalogJobProcess -Job $job -CommandLine "`"$cmd`" /d /c for /L %i in (1,1,$(20000 * $i)) do @rem" -WorkingDirectory $cwd
        [void][TmwrCatalogJob]::WaitExit($short.Process, 60000)
        Start-Sleep -Milliseconds 100
        $after = Read-CatalogJobRow -Job $job -Stopwatch $stopwatch
        $t = [TmwrCatalogJob]::ProcessTimes($short.Process)
        $reference = ([double]$t[2] + [double]$t[3]) / 1e7
        $delta = [double]::Parse($after.CpuSeconds, $culture) - [double]::Parse($before.CpuSeconds, $culture)
        $differences.Add($delta - $reference)
        $from = [DateTimeOffset]::Parse($before.Utc, $culture).UtcTicks; $to = [DateTimeOffset]::Parse($after.Utc, $culture).UtcTicks
        $own = @($job.Messages() | Where-Object { $_.ProcessId -eq $short.ProcessId })
        if (@($own | Where-Object { $_.Message -eq 6 -and $_.UtcTicks -ge $from -and $_.UtcTicks -le $to }).Count -ne 1 -or @($own | Where-Object { $_.Message -eq 7 -and $_.UtcTicks -ge $from -and $_.UtcTicks -le $to }).Count -ne 1) { $between = $false }
        if ([long]$after.TotalProcesses -ne [long]$before.TotalProcesses + 1) { $between = $false }
        [TmwrCatalogJob]::Close($short.Process)
    }
    $worst = ($differences | ForEach-Object { [Math]::Abs($_) } | Measure-Object -Maximum).Maximum
    Check 'between samples: the job CPU difference equals the held-handle CPU within one tick' ($worst -le $tick + 1e-7) ("differences {0} s" -f (($differences | ForEach-Object { $_.ToString('F7', $culture) }) -join ', '))
    Check 'between samples: one process and its new and exit messages between the two rows' $between
    $summary.betweenSamples = [ordered]@{ differencesSeconds = @($differences) }
}
finally { $job.Dispose() }

# 3. A failed assignment ends the process before it runs.
$job = New-CatalogJob
$restricted = [IntPtr]::Zero
try {
    $restricted = $job.DuplicateQueryOnly()
    $result = [TmwrCatalogJob]::StartIn($restricted, "`"$ping`" -n 30 127.0.0.1", $cwd, [uint32]0)
    Check 'assignment error: reported' ($result.Error -eq 5 -and $result.Process -eq [IntPtr]::Zero) ("error {0}" -f $result.Error)
    Check 'assignment error: the process was ended before it ran' ($result.TerminatedAfterFailure -and $null -eq (Get-Process -Id $result.ProcessId -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -eq 'PING' })) ("PID {0}" -f $result.ProcessId)
    Start-Sleep -Milliseconds 200
    Check 'assignment error: the job counted nothing' ($job.Accounting()[2] -eq 0 -and @($job.Messages()).Count -eq 0)
    # The runner's wrapper refuses a failed start (the same restricted handle behind its Start method).
    $restrictedJob = [pscustomobject]@{ Handle = $restricted }
    $restrictedJob | Add-Member -MemberType ScriptMethod -Name Start -Value { param($line, $directory, $flags) [TmwrCatalogJob]::StartIn($this.Handle, $line, $directory, $flags) }
    $message = ''
    try { [void](Start-CatalogJobProcess -Job $restrictedJob -CommandLine "`"$ping`" -n 30 127.0.0.1" -WorkingDirectory $cwd) } catch { $message = $_.Exception.Message }
    Check 'assignment error: the runner stops with the error and the process ended' ($message -like '*Win32 error 5*ended before it ran*') $message
}
finally {
    [TmwrCatalogJob]::Close($restricted)
    $job.Dispose()
}

# 4. A foreign process: not a member, not in the job CPU, not ended with the job.
$job = New-CatalogJob
$foreign = $null
try {
    $foreign = Start-Process -FilePath $ping -ArgumentList '-n', '30', '127.0.0.1' -PassThru -WindowStyle Hidden
    $null = $foreign.Handle
    $inside = Start-CatalogJobProcess -Job $job -CommandLine "`"$ping`" -n 30 127.0.0.1" -WorkingDirectory $cwd
    Start-Sleep -Milliseconds 500
    $foreignKey = Get-Key $foreign.Handle
    $insideKey = Get-Key $inside.Process
    $membership = Get-CatalogJobMembership -Messages @(ConvertTo-CatalogJobMessageRows $job.Messages()) -MonitorKeys @($insideKey, $foreignKey)
    Check 'foreign: the job holds its own process, not the foreign one' ($job.Contains($inside.Process) -and -not $job.Contains($foreign.Handle))
    Check 'foreign: membership by identity names only the foreign process' ($membership.InJob -eq 1 -and (@($membership.NotInJob) -join ',') -eq $foreignKey) (@($membership.NotInJob) -join ',')
    $job.TerminateAll([uint32]1)
    Check 'foreign: terminating the job ends its own process' ([TmwrCatalogJob]::WaitExit($inside.Process, 10000))
    Check 'foreign: terminating the job leaves the foreign process running' (-not $foreign.HasExited)
    Wait-JobIdle $job 10
    Check 'foreign: the job counted one process' ($job.Accounting()[2] -eq 1 -and $job.Accounting()[3] -eq 0)
    [TmwrCatalogJob]::Close($inside.Process)
}
finally {
    $job.Dispose()
    # The test's own foreign process, by its own handle.
    if ($null -ne $foreign -and -not $foreign.HasExited) { $foreign.Kill(); $foreign.WaitForExit() }
}

# 5. Leftovers: a process that outlives the root; closing the job ends it (kill on close).
$job = New-CatalogJob
$leftover = $null
try {
    $leftover = Start-CatalogJobProcess -Job $job -CommandLine "`"$ping`" -n 60 127.0.0.1" -WorkingDirectory $cwd
    Start-Sleep -Milliseconds 300
    Check 'leftover: running in the job' ($job.Accounting()[3] -eq 1)
}
finally { $job.Dispose() }
Check 'leftover: closing the job ended it (kill on close)' ([TmwrCatalogJob]::WaitExit($leftover.Process, 10000))
[TmwrCatalogJob]::Close($leftover.Process)

if ($OutputPath) { $summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding UTF8 }
if ($failures.Count -gt 0) {
    Write-Host ("{0} passed, {1} failed:" -f $passed, $failures.Count)
    $failures | ForEach-Object { Write-Host "  $_" }
    exit 1
}
Write-Host "PASS: $passed job CPU checks."
exit 0
