[CmdletBinding()]
param(
    # A scenario M arm executable (bin\arm-<A|B|C>.exe of a smoke results directory).
    [Parameter(Mandatory = $true)][string[]]$Executable,
    [Parameter(Mandatory = $true)][string]$MonitorScript,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [int]$Windows = 4,
    [int]$DataMib = 64,
    [int]$Seed = 1,
    [int]$IdleBeforeSeconds = 20,
    [int]$WarmupSeconds = 30,
    [int]$LoadSeconds = 120,
    [int]$IdleAfterSeconds = 30,
    [int]$StepIntervalMs = 500,
    [int]$PauseSeconds = 30
)

# Spike, not a benchmark run: checks job CPU accounting against the process
# monitor on the real WebView2 tree of scenario M (default N4D64 phases).
# For each executable, one run: the app is started suspended in a new job,
# the monitor (#43) samples it as in the smoke, and this script reads the
# job's accounting every second. Output per run in OutputDirectory:
# <name>.job.csv (job CPU, process counts, job PIDs per second), the
# monitor CSVs and log, the app report, and <name>.compare.json:
#   - job CPU vs the monitor's sum of last cumulative CPU per identity, at
#     the monitor's last sample and over time;
#   - processes the job counted vs identities the monitor saw (never seen);
#   - job PIDs not in the monitor's tree, and the reverse;
#   - the monitor's CPU reasons (ExitedUnread etc.).
# The output directory must be new; nothing outside it is written.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'JobCpuAccounting.psm1') -Force
$culture = [System.Globalization.CultureInfo]::InvariantCulture
if (Test-Path -LiteralPath $OutputDirectory) { throw "$OutputDirectory exists; use a new directory." }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$MonitorScript = (Resolve-Path -LiteralPath $MonitorScript).Path
$timeoutSeconds = $IdleBeforeSeconds + $WarmupSeconds + $LoadSeconds + $IdleAfterSeconds + 180 + 2 * $DataMib

function ConvertTo-Number {
    param([AllowNull()][object]$Value)
    $number = 0.0
    if ([double]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Float, $culture, [ref]$number)) { return $number }
    return $null
}

$index = 0
foreach ($exe in $Executable) {
    $index++
    $exe = (Resolve-Path -LiteralPath $exe).Path
    $name = '{0:D2}-{1}-N{2}D{3}' -f $index, [System.IO.Path]::GetFileNameWithoutExtension($exe), $Windows, $DataMib
    if ($index -gt 1 -and $PauseSeconds -gt 0) { Start-Sleep -Seconds $PauseSeconds }
    $report = Join-Path $OutputDirectory "$name.report.json"
    $monitorCsv = Join-Path $OutputDirectory "$name.monitor.csv"
    $monitorLog = Join-Path $OutputDirectory "$name.monitor.log"
    $jobCsv = Join-Path $OutputDirectory "$name.job.csv"
    $profileDirectory = Join-Path $OutputDirectory "$name.profile"

    $previousProfile = $env:WEBVIEW2_USER_DATA_FOLDER
    $env:WEBVIEW2_USER_DATA_FOLDER = $profileDirectory
    $job = New-CpuJob
    try {
        $commandLine = ('"{0}" --report "{1}" --data-mib {2} --windows {3} --seed {4} --idle-before {5} --warmup {6} --duration {7} --idle-after {8} --step-interval-ms {9}' -f $exe, $report, $DataMib, $Windows, $Seed, $IdleBeforeSeconds, $WarmupSeconds, $LoadSeconds, $IdleAfterSeconds, $StepIntervalMs)
        $app = Start-ProcessInCpuJob -Job $job -CommandLine $commandLine -WorkingDirectory (Split-Path -Parent $exe)
    }
    finally { $env:WEBVIEW2_USER_DATA_FOLDER = $previousProfile }
    $monitorArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$MonitorScript`"", '-RootPid', $app.Pid,
        '-DurationSeconds', ($timeoutSeconds + 30), '-SampleIntervalSeconds', 1, '-OutputPath', "`"$monitorCsv`"", '-Diagnostics',
        '-UnitCheckRequireChildName', 'msedgewebview2.exe')
    $monitor = Start-Process -FilePath 'powershell.exe' -ArgumentList $monitorArguments -PassThru -NoNewWindow -RedirectStandardOutput $monitorLog -RedirectStandardError "$monitorLog.err"
    $null = $monitor.Handle

    $rows = New-Object System.Collections.Generic.List[object]
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    $appExitedAt = $null
    while ($true) {
        $a = Get-CpuJobAccounting -Job $job
        $ids = @(Get-CpuJobProcessIds -Job $job)
        $rows.Add([pscustomobject]@{
                Timestamp = (Get-Date).ToString('o'); CpuSeconds = $a.CpuSeconds.ToString('F7', $culture)
                TotalProcesses = $a.TotalProcesses; ActiveProcesses = $a.ActiveProcesses; TerminatedProcesses = $a.TerminatedProcesses
                ProcessIds = ($ids -join ';')
            })
        $appDone = Wait-HeldProcess -Handle $app.Handle -TimeoutMilliseconds 0
        if ($appDone -and $null -eq $appExitedAt) { $appExitedAt = Get-Date }
        # After the app exits, wait until every process of the job has exited (at most 60 s).
        if ($appDone -and ($a.ActiveProcesses -eq 0 -or ((Get-Date) - $appExitedAt).TotalSeconds -gt 60)) { break }
        if ((Get-Date) -gt $deadline) { break }
        Start-Sleep -Milliseconds 1000
    }
    $rows | Export-Csv -LiteralPath $jobCsv -NoTypeInformation -Encoding UTF8
    $monitor.WaitForExit()
    $final = Get-CpuJobAccounting -Job $job
    $appCpu = Get-HeldProcessCpu -Handle $app.Handle
    Close-JobCpuHandle -Handle $app.Handle
    Close-JobCpuHandle -Handle $job

    # Monitor side: cumulative CPU per identity, as the summarizer sums it.
    $compare = [ordered]@{ name = $name; executable = $exe; monitorExit = $monitor.ExitCode; appCpuSeconds = $appCpu.CpuSeconds
        jobFinal = $final; jobRows = $rows.Count }
    $diagnosticsFile = [System.IO.Path]::ChangeExtension($monitorCsv, '.diagnostics.csv')
    if ((Test-Path -LiteralPath $monitorCsv) -and (Test-Path -LiteralPath $diagnosticsFile)) {
        $monitorRows = @(Import-Csv -LiteralPath $monitorCsv)
        $diag = @(Import-Csv -LiteralPath $diagnosticsFile | Where-Object { $_.InTree -eq 'True' })
        $identities = @($diag | ForEach-Object { $_.ProcessKey } | Sort-Object -Unique)
        $lastByKey = @{}
        foreach ($d in $diag) { $cpu = ConvertTo-Number $d.ProcTotalProcessorSeconds; if ($null -ne $cpu) { $lastByKey[$d.ProcessKey] = $cpu } }
        $monitorCpu = ($lastByKey.Values | Measure-Object -Sum).Sum
        $lastMonitorTime = [DateTimeOffset]::Parse($monitorRows[$monitorRows.Count - 1].Timestamp, $culture)
        $jobAtLast = @($rows | Where-Object { [DateTimeOffset]::Parse($_.Timestamp, $culture) -le $lastMonitorTime.AddSeconds(1) } | Select-Object -Last 1)
        # Job PIDs vs the monitor's tree, second by second (nearest earlier job row).
        $jobNotInTree = New-Object System.Collections.Generic.List[string]
        $treeNotInJob = New-Object System.Collections.Generic.List[string]
        foreach ($m in $monitorRows) {
            $t = [DateTimeOffset]::Parse($m.Timestamp, $culture)
            $j = @($rows | Where-Object { [DateTimeOffset]::Parse($_.Timestamp, $culture) -le $t } | Select-Object -Last 1)
            if ($j.Count -eq 0) { continue }
            $jobIds = @(([string]$j[0].ProcessIds).Split(';') | Where-Object { $_ -ne '' })
            $treeIds = @(([string]$m.ProcessIds).Split(';') | Where-Object { $_ -ne '' })
            foreach ($id in $treeIds) { if ($jobIds -notcontains $id) { $treeNotInJob.Add("S$($m.Sample):$id") } }
            foreach ($id in $jobIds) { if ($treeIds -notcontains $id) { $jobNotInTree.Add("S$($m.Sample):$id") } }
        }
        $reasons = [ordered]@{}
        foreach ($reason in 'ExitedRead', 'ExitedUnread', 'AccessDenied', 'IdentityChanged', 'LeftTree', 'ReadError', 'NewCounted') {
            $column = "Cpu${reason}Count"
            $reasons[$reason] = (@($monitorRows | ForEach-Object { [int]$_.$column }) | Measure-Object -Sum).Sum
            $reasons["${reason}Ids"] = @($monitorRows | Where-Object { [string]$_."Cpu${reason}Ids" -ne '' } | ForEach-Object { "S$($_.Sample):$($_."Cpu${reason}Ids")" })
        }
        $compare.monitorIdentities = $identities.Count
        $compare.monitorCpuSecondsLastPerIdentity = $monitorCpu
        $compare.monitorLastSample = $lastMonitorTime.ToString('o')
        $compare.jobCpuSecondsAtMonitorLastSample = if ($jobAtLast.Count -gt 0) { ConvertTo-Number $jobAtLast[0].CpuSeconds } else { $null }
        $compare.jobMinusMonitorAtLastSample = if ($jobAtLast.Count -gt 0) { (ConvertTo-Number $jobAtLast[0].CpuSeconds) - $monitorCpu } else { $null }
        $compare.jobMinusMonitorFinal = $final.CpuSeconds - $monitorCpu
        $compare.processesNeverSeenByMonitor = $final.TotalProcesses - $identities.Count
        $compare.treeNotInJob = @($treeNotInJob)
        $compare.jobNotInTree = @($jobNotInTree)
        $compare.monitorCpuReasons = $reasons
    }
    else { $compare.problem = 'monitor CSV or diagnostics missing' }
    $compare | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory "$name.compare.json") -Encoding UTF8
    Write-Host ("{0}: job {1} s ({2} processes), monitor {3} s ({4} identities), never seen {5}, ExitedUnread {6}" -f $name,
        $final.CpuSeconds.ToString('F3', $culture), $final.TotalProcesses, $(if ($compare.Contains('monitorCpuSecondsLastPerIdentity')) { ([double]$compare.monitorCpuSecondsLastPerIdentity).ToString('F3', $culture) } else { 'n/a' }),
        $(if ($compare.Contains('monitorIdentities')) { $compare.monitorIdentities } else { 'n/a' }), $(if ($compare.Contains('processesNeverSeenByMonitor')) { $compare.processesNeverSeenByMonitor } else { 'n/a' }),
        $(if ($compare.Contains('monitorCpuReasons')) { $compare.monitorCpuReasons.ExitedUnread } else { 'n/a' }))
}
