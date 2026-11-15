[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Executable,
    [Parameter(Mandatory)][string]$BuildRecord,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateRange(1, 600)][int]$LoadSeconds = 120,
    [ValidateRange(1, 120)][int]$IdleBeforeSeconds = 20,
    [ValidateRange(1, 120)][int]$WarmupSeconds = 30,
    [ValidateRange(1, 120)][int]$IdleAfterSeconds = 30
)
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows is required' }
if (@(Get-Process cs2,cargo,rustc,link -ErrorAction SilentlyContinue).Count) { throw 'Competing game/build is running' }
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Output directory must be new; failed attempts are retained' }
$repository = (Resolve-Path "$PSScriptRoot/../../..").Path
if (& git -C $repository status --porcelain) { throw 'Collector source must be committed and clean' }
$exe = (Resolve-Path -LiteralPath $Executable).Path
$recordPath = (Resolve-Path -LiteralPath $BuildRecord).Path
$record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
$hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
if ($record.executableSha256 -ne $hash -or
    $record.scenarioRevision -notmatch '\A[0-9a-fA-F]{40}\z' -or
    $record.frameworkRevision -notmatch '\A[0-9a-fA-F]{40}\z' -or
    $record.cargoLockSha256 -notmatch '\A[0-9a-fA-F]{64}\z') { throw 'Build record does not identify the executable and source' }
. "$PSScriptRoot/CatalogJobCpu.ps1"
. "$PSScriptRoot/Read-OwnedMemory.ps1"
$null = New-Item -ItemType Directory -Path $OutputDirectory
$output = (Resolve-Path -LiteralPath $OutputDirectory).Path
$report = Join-Path $output 'report.json'
Copy-Item -LiteralPath $recordPath -Destination (Join-Path $output 'build-record.json')
$script:diagnosticRows = [Collections.Generic.List[object]]::new()
$script:diagnosticReads = [Collections.Generic.List[object]]::new()
$script:diagnosticIdentities = [Collections.Generic.HashSet[string]]::new()
$script:diagnosticOriginalRow = ${function:Read-CatalogJobRow}
function Read-CatalogJobRow {
    param($Job, $Stopwatch)
    $started = [DateTimeOffset]::UtcNow.ToString('o')
    $total = 0L; $read = 0; $unavailable = 0; $exited = 0
    $frame = $script:diagnosticRows.Count
    foreach ($processId in $Job.ProcessIds()) {
        $r = Read-OwnedMemory -Job $Job -ProcessId $processId
        if ($r.Status -eq 'Read') {
            $total += $r.PrivateBytes; $read++
            $null = $script:diagnosticIdentities.Add("$processId@$($r.CreatedTicks)")
        } elseif ($r.Status -eq 'Unavailable') { $unavailable++ } else { $exited++ }
        $script:diagnosticReads.Add([pscustomobject]@{
            Frame = $frame; Utc = [DateTimeOffset]::UtcNow.ToString('o'); ProcessId = $processId
            CreatedTicks = $r.CreatedTicks; Status = $r.Status; PrivateBytes = $r.PrivateBytes; Error = $r.Error
        })
    }
    $script:diagnosticRows.Add([pscustomobject]@{
        Frame = $frame; StartedUtc = $started; Utc = [DateTimeOffset]::UtcNow.ToString('o')
        PrivateBytes = $total; ReadProcesses = $read; UnavailableProcesses = $unavailable; ExitedProcesses = $exited
    })
    & $script:diagnosticOriginalRow -Job $Job -Stopwatch $Stopwatch
}
$inputs = [ordered]@{
    schemaVersion = 2; purpose = 'Diagnostic N2D16/C only; no pilot, confirmatory or product claim'
    collectorRevision = (& git -C $repository rev-parse HEAD); buildRecord = $record
    executable = $exe; executableSha256 = $hash; startedAt = [DateTimeOffset]::UtcNow.ToString('o')
    phasesSeconds = @($IdleBeforeSeconds, $WarmupSeconds, $LoadSeconds, $IdleAfterSeconds)
    windows = 2; dataMib = 16; seed = 1; stepIntervalMs = 500; textCache = $false
    os = [Environment]::OSVersion.Version.ToString(); readerSha256 = (Get-FileHash "$PSScriptRoot/Read-OwnedMemory.ps1").Hash
}
$inputs | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$output/inputs.json"
$command = '"{0}" --report "{1}" --data-mib 16 --windows 2 --seed 1 --step-interval-ms 500 --idle-before {2} --warmup {3} --duration {4} --idle-after {5} --text-cache off' -f $exe,$report,$IdleBeforeSeconds,$WarmupSeconds,$LoadSeconds,$IdleAfterSeconds
$run = Invoke-CatalogJobRun -Label 'owned-memory-diagnostic' -CommandLine $command -WorkingDirectory $output -Environment @{WEBVIEW2_USER_DATA_FOLDER=(Join-Path $output 'profile')} -TimeoutSeconds ($IdleBeforeSeconds+$WarmupSeconds+$LoadSeconds+$IdleAfterSeconds+90) -JobCsv "$output/job.csv" -JobMessagesCsv "$output/messages.csv"
$run | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$output/runner.json"
$script:diagnosticRows | Export-Csv -LiteralPath "$output/memory.csv" -NoTypeInformation
$script:diagnosticReads | Export-Csv -LiteralPath "$output/process-reads.csv" -NoTypeInformation
$problems = [Collections.Generic.List[string]]::new()
if ($run.ExitCode -ne 0 -or $run.TimedOut -or $run.Terminated -or $run.LeftoverProcesses -ne 0 -or $run.Error) { $problems.Add('Application/owned-job completion failed') }
if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $hash) { $problems.Add('Executable changed during collection') }
if (@(Get-Process cs2,cargo,rustc,link -ErrorAction SilentlyContinue).Count) { $problems.Add('Competing game/build at completion') }
$loadRows = @(); $cpu = $null; $app = $null
if (Test-Path -LiteralPath $report) {
    $app = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    $expected = 4 * $LoadSeconds
    if (-not $app.passed -or $app.config.arm -ne 'C' -or $app.config.textCache -ne $false -or
        $app.config.dataMib -ne 16 -or $app.config.windows -ne 2 -or $app.config.seed -ne 1 -or $app.config.stepIntervalMs -ne 500 -or
        $app.config.idleBeforeSeconds -ne $IdleBeforeSeconds -or $app.config.warmupSeconds -ne $WarmupSeconds -or
        $app.config.loadSeconds -ne $LoadSeconds -or $app.config.idleAfterSeconds -ne $IdleAfterSeconds -or
        $app.totals.completedSteps -ne $expected -or $app.totals.scheduledSteps -ne $expected -or
        $app.totals.failures -ne 0 -or $app.totals.mismatches -ne 0 -or $app.totals.overruns -ne 0) { $problems.Add('Application configuration or workload assertions failed') }
    $loadRows = @($script:diagnosticRows | Where-Object {
        $time = [DateTimeOffset]::Parse($_.Utc).ToUnixTimeMilliseconds()
        $time -ge $app.plan.loadAtMs -and $time -lt $app.plan.loadEndMs
    })
    if ($loadRows.Count -lt $LoadSeconds -or @($loadRows | Where-Object { $_.UnavailableProcesses -ne 0 -or $_.ReadProcesses -eq 0 }).Count) { $problems.Add('Load memory coverage/read failures') }
    $cpu = Get-CatalogJobCpu -Rows @(Import-Csv "$output/job.csv") -Messages @(Import-Csv "$output/messages.csv") -Phases $app.phases -MonitorKeys @($script:diagnosticIdentities)
    foreach ($problem in $cpu.Problems) { $problems.Add("Job accounting: $problem") }
} else { $problems.Add('Application report missing') }
$result = [ordered]@{
    valid = ($problems.Count -eq 0); problems = @($problems); samples = $loadRows.Count
    loadPrivateMiB = if ($loadRows.Count) { ($loadRows | Measure-Object PrivateBytes -Average).Average / 1MB } else { $null }
    cpu = $cpu; directory = $output; executableSha256 = $hash
    statusCounts = @($script:diagnosticReads | Group-Object Status | Select-Object Name,Count)
}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$output/result.json"
$result | ConvertTo-Json -Depth 8
if (-not $result.valid) { exit 1 }
