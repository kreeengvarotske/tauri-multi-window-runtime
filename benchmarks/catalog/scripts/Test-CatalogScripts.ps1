<#
.SYNOPSIS
Tests CatalogSchedule.ps1 (balance of the pilot order),
CatalogThresholds.ps1 (threshold forms, pilot reference, sign counts at the
threshold, cut-offs) and Summarize-CatalogRuns.ps1 (validity, triplet differences, retained size),
CatalogJobCpu.ps1 (job CPU rules), CatalogManifest.ps1 (manifest freeze,
results directories) and CatalogConfirmatory.ps1 (confirmatory inputs) on
synthetic data.

.DESCRIPTION
Runs in Windows PowerShell 5.1 and PowerShell 7. Writes synthetic data only to
a new temporary directory and removes it at the end. Exits 1 on any failure.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$culture = [System.Globalization.CultureInfo]::InvariantCulture
. (Join-Path $PSScriptRoot 'CatalogSchedule.ps1')
. (Join-Path $PSScriptRoot 'CatalogThresholds.ps1')
. (Join-Path $PSScriptRoot 'CatalogJobCpu.ps1')
. (Join-Path $PSScriptRoot 'CatalogManifest.ps1')
. (Join-Path $PSScriptRoot 'CatalogConfirmatory.ps1')
. (Join-Path $PSScriptRoot 'CatalogSignAnalysis.ps1')
$failures = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if (-not $Condition) { $failures.Add("${Name}: $Detail") } else { Write-Host "ok   $Name" }
}

function Assert-Near {
    param([string]$Name, [string]$Actual, [double]$Expected, [double]$Tolerance = 1e-9)
    $value = [double]::NaN
    if (-not [double]::TryParse($Actual, [System.Globalization.NumberStyles]::Float, $culture, [ref]$value) -or [Math]::Abs($value - $Expected) -gt $Tolerance) {
        $failures.Add("${Name}: expected $Expected, got '$Actual'")
    }
    else { Write-Host "ok   $Name" }
}

# --- Schedule: the pilot shape of protocol revision 3 (§6, §8a, Q8): 6 triplets per cell.
$cells = @('N2D0', 'N2D16', 'N2D64', 'N4D64')
$allPermutations = @('ABC', 'ACB', 'BAC', 'BCA', 'CAB', 'CBA')
foreach ($seed in 0..23) {
    $schedule = @(New-CatalogSchedule -Cells $cells -Arms A, B, C -Triplets 6 -Seed $seed)
    Assert-True "seed ${seed}: 72 runs" ($schedule.Count -eq 72) "got $($schedule.Count)"
    Assert-True "seed ${seed}: Seq is 1..72" ((@($schedule | ForEach-Object { $_.Seq }) -join ',') -eq ((1..72) -join ','))
    $problems = @(Test-CatalogSchedule -Schedule $schedule -Cells $cells -Arms A, B, C -Triplets 6)
    Assert-True "seed ${seed}: complete schedule" ($problems.Count -eq 0) ($problems -join '; ')
    $units = @($schedule | Where-Object { $_.Position -eq 1 })
    $cellsOk = $true
    $detail = ''
    foreach ($cell in $cells) {
        $cellPermutations = @($units | Where-Object { $_.Cell -eq $cell } | ForEach-Object { $_.Permutation } | Sort-Object)
        if (($cellPermutations -join ',') -ne ($allPermutations -join ',')) { $cellsOk = $false; $detail += "$cell=$($cellPermutations -join ',') " }
        $cellPositions = @($schedule | Where-Object { $_.Cell -eq $cell } | Group-Object Arm, Position | ForEach-Object { $_.Count })
        if ($cellPositions.Count -ne 9 -or @($cellPositions | Where-Object { $_ -ne 2 }).Count -gt 0) { $cellsOk = $false; $detail += "$cell positions=$($cellPositions -join ',') " }
    }
    Assert-True "seed ${seed}: every cell uses each permutation once and each arm in each position twice" $cellsOk $detail
    $positionCounts = @($schedule | Group-Object Arm, Position | ForEach-Object { $_.Count })
    Assert-True "seed ${seed}: every arm in every position 8 times overall" ($positionCounts.Count -eq 9 -and @($positionCounts | Where-Object { $_ -ne 8 }).Count -eq 0) ($positionCounts -join ',')
    $firstPermutations = @($cells | ForEach-Object { $cell = $_; @($units | Where-Object { $_.Cell -eq $cell -and $_.Triplet -eq 1 })[0].Permutation })
    Assert-True "seed ${seed}: each cell starts at a different permutation" (@($firstPermutations | Select-Object -Unique).Count -eq 4) ($firstPermutations -join ',')
    $blocksOk = $true
    for ($block = 1; $block -le 6; $block++) {
        $blockRows = @($schedule | Where-Object { $_.Block -eq $block })
        $blockCells = @($blockRows | Where-Object { $_.Position -eq 1 } | ForEach-Object { $_.Cell })
        if ($blockRows.Count -ne 12 -or @($blockCells | Select-Object -Unique).Count -ne 4) { $blocksOk = $false }
    }
    Assert-True "seed ${seed}: blocks hold one triplet of each cell" $blocksOk
    $firstCells = @(1..4 | ForEach-Object { $b = $_; @($schedule | Where-Object { $_.Block -eq $b })[0].Cell })
    Assert-True "seed ${seed}: cell order rotates per block" (@($firstCells | Select-Object -Unique).Count -eq 4) ($firstCells -join ',')
}

# Confirmatory sizes that are not a multiple of 6 (§8b): per cell, uses of the
# permutations differ by at most one.
foreach ($triplets in 5, 11, 14, 20, 28) {
    foreach ($seed in 0, 5, 13) {
        $schedule = @(New-CatalogSchedule -Cells $cells -Arms A, B, C -Triplets $triplets -Seed $seed)
        $problems = @(Test-CatalogSchedule -Schedule $schedule -Cells $cells -Arms A, B, C -Triplets $triplets)
        $balanced = $true
        foreach ($cell in $cells) {
            $counts = @($allPermutations | ForEach-Object { $permutation = $_; @($schedule | Where-Object { $_.Cell -eq $cell -and $_.Position -eq 1 -and $_.Permutation -eq $permutation }).Count })
            if ((($counts | Measure-Object -Maximum).Maximum - ($counts | Measure-Object -Minimum).Minimum) -gt 1) { $balanced = $false }
        }
        Assert-True "$triplets triplets, seed ${seed}: complete and balanced within one per cell" ($problems.Count -eq 0 -and $balanced) ($problems -join '; ')
    }
}

# The check catches an incomplete or edited schedule, also after a CSV round trip.
$root = Join-Path ([System.IO.Path]::GetTempPath()) ("catalog-schedule-test-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
try {
    $csv = Join-Path $root 'schedule.csv'
    New-CatalogSchedule -Cells $cells -Arms A, B, C -Triplets 6 -Seed 3 | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
    $read = @(Import-Csv -LiteralPath $csv)
    Assert-True 'schedule.csv round trip is complete' (@(Test-CatalogSchedule -Schedule $read -Cells $cells -Arms A, B, C -Triplets 6).Count -eq 0)
    $missing = @($read | Select-Object -Skip 1)
    Assert-True 'a missing run is reported' (@(Test-CatalogSchedule -Schedule $missing -Cells $cells -Arms A, B, C -Triplets 6).Count -gt 0)
    $edited = @(Import-Csv -LiteralPath $csv)
    $edited[1].Arm = $edited[0].Arm
    Assert-True 'a repeated arm in a triplet is reported' (@(Test-CatalogSchedule -Schedule $edited -Cells $cells -Arms A, B, C -Triplets 6).Count -gt 0)
    $moved = @(Import-Csv -LiteralPath $csv)
    $swap = $moved[2]; $moved[2] = $moved[3]; $moved[3] = $swap
    Assert-True 'runs out of order are reported' (@(Test-CatalogSchedule -Schedule $moved -Cells $cells -Arms A, B, C -Triplets 6).Count -gt 0)
    Assert-True 'a schedule for other arms is reported' (@(Test-CatalogSchedule -Schedule $read -Cells $cells -Arms A, B -Triplets 6).Count -gt 0)
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
$again = (@(New-CatalogSchedule -Cells $cells -Arms A, B, C -Triplets 6 -Seed 7) | ConvertTo-Csv -NoTypeInformation) -join "`n"
$once = (@(New-CatalogSchedule -Cells $cells -Arms A, B, C -Triplets 6 -Seed 7) | ConvertTo-Csv -NoTypeInformation) -join "`n"
Assert-True 'schedule is reproducible from its seed' ($again -eq $once)
$pairs = @(New-CatalogSchedule -Cells N2D0, N4D16 -Arms A, B -Triplets 3 -Seed 0)
Assert-True 'two arms: 12 runs' ($pairs.Count -eq 12)
$pairOrders = @($pairs | Where-Object { $_.Position -eq 1 } | ForEach-Object { $_.Permutation }) -join ','
Assert-True 'two arms: orders alternate' ($pairOrders -eq 'AB,BA,AB,BA,AB,BA') $pairOrders
$pairCellsOk = $true
foreach ($cell in 'N2D0', 'N4D16') {
    $cellOrders = @($pairs | Where-Object { $_.Cell -eq $cell -and $_.Position -eq 1 } | ForEach-Object { $_.Permutation })
    for ($i = 1; $i -lt $cellOrders.Count; $i++) { if ($cellOrders[$i] -eq $cellOrders[$i - 1]) { $pairCellsOk = $false } }
}
Assert-True 'two arms: each cell alternates' $pairCellsOk
foreach ($bad in 'N0D16', 'N9D16', 'N2D300', 'D16', 'n2d16') {
    $threw = $false
    try { $null = New-CatalogSchedule -Cells $bad -Arms A, B -Triplets 1 -Seed 0 } catch { $threw = $true }
    Assert-True "rejects cell '$bad'" $threw
}
$threw = $false
try { $null = New-CatalogSchedule -Cells N2D0, N2D0 -Arms A, B -Triplets 1 -Seed 0 } catch { $threw = $true }
Assert-True 'rejects duplicate cells' $threw

# --- Summarizer on synthetic results.
$root = Join-Path ([System.IO.Path]::GetTempPath()) ("catalog-test-{0}" -f [guid]::NewGuid().ToString('N'))
try {
    $results = Join-Path $root 'results'
    $runsDir = Join-Path $results 'runs'
    New-Item -ItemType Directory -Force -Path $runsDir | Out-Null
    $schedule = @(New-CatalogSchedule -Cells N2D0, N2D16 -Arms A, B -Triplets 2 -Seed 0)
    $schedule | Export-Csv -LiteralPath (Join-Path $results 'schedule.csv') -NoTypeInformation -Encoding UTF8
    [ordered]@{
        scenario = 'M'; phase = 'Smoke'; os = 'Synthetic OS'; machine = 'TEST'; gitHead = 'abc'; gitDirty = $false
        arms = @('A', 'B'); cells = @('N2D0', 'N2D16'); triplets = 2; scheduleSeed = 0; sampleIntervalSeconds = 1
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $results 'configuration.json') -Encoding UTF8

    # Private MB per run: base 300; +40 host for B at D16; +50 per window in WebView2 for A at D16.
    $start = [DateTimeOffset]::Parse('2026-10-26T10:00:00Z', $culture)
    $log = New-Object System.Collections.Generic.List[string]
    $offset = 0
    foreach ($run in $schedule) {
        $t0 = $start.AddMinutes($offset); $offset += 10
        $hostMb = 100.0 + $(if ($run.Arm -eq 'B' -and $run.DataMib -gt 0) { 40 } else { 0 }) + $run.Triplet
        $webMb = 200.0 + $(if ($run.Arm -eq 'A' -and $run.DataMib -gt 0) { 100 } else { 0 })
        $passed = -not ($run.Cell -eq 'N2D16' -and $run.Triplet -eq 2 -and $run.Arm -eq 'B')
        $phases = [ordered]@{
            idleBeforeStartedAt = $t0.ToString('o'); warmupStartedAt = $t0.AddSeconds(5).ToString('o'); loadStartedAt = $t0.AddSeconds(10).ToString('o')
            loadEndedAt = $t0.AddSeconds(30).ToString('o'); endedAt = $t0.AddSeconds(35).ToString('o')
        }
        [ordered]@{
            schemaVersion = 1; scenario = 'M'; passed = $passed; problems = @($(if (-not $passed) { 'w1: completed 39/40' }))
            config = [ordered]@{ arm = $run.Arm; windows = [int]$run.Windows; dataMib = [int]$run.DataMib; records = 1000; rustDataBytes = [int]$run.DataMib * 1MB }
            phases = $phases
            totals = [ordered]@{ scheduledSteps = 80; completedSteps = 80; failures = 0; mismatches = 0; overruns = 0; maxP95LatencyMs = 3.5; maxTimeToFirstPageMs = 120; loadJsHeapAvgBytes = $(if ($run.Arm -eq 'A') { 80MB } else { 8MB }) }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runsDir "$($run.Name).json") -Encoding UTF8
        $monitor = New-Object System.Collections.Generic.List[string]
        $diagnostics = New-Object System.Collections.Generic.List[string]
        $monitor.Add('Timestamp,Sample,RootPid,ProcessCount,WorkingSetMB,PrivateBytesMB,CpuDeltaSeconds,IntervalSeconds,PrivateMissingCount,CpuUnreadableCount')
        $diagnostics.Add('Timestamp,Pid,Name,InTree,CimPrivatePageCount,ProcTotalProcessorSeconds')
        # Cumulative CPU: host 2 s + 0.3 s/s, WebView2 1 s + 0.2 s/s, and a helper process that leaves the tree after 10 s (0.5 s + 0.1 s/s).
        # The second A run in N2D0 has an unreadable CPU value after the load phase.
        $cpuGap = $run.Cell -eq 'N2D0' -and $run.Triplet -eq 2 -and $run.Arm -eq 'A'
        # The first A run in N2D0 has a 7 s monitor gap during load.
        $gap = $run.Cell -eq 'N2D0' -and $run.Triplet -eq 1 -and $run.Arm -eq 'A'
        for ($s = 0; $s -le 36; $s++) {
            if ($gap -and $s -ge 15 -and $s -lt 22) { continue }
            $time = $t0.AddSeconds($s).ToString('o')
            $interval = if ($s -eq 0) { '' } elseif ($gap -and $s -eq 22) { '7' } else { '1' }
            $unreadable = if ($cpuGap -and $s -eq 33) { 1 } else { 0 }
            $monitor.Add(('{0},{1},4242,5,{2},{3},0.5,{4},0,{5}' -f $time, $s, ($hostMb + $webMb + 50).ToString($culture), ($hostMb + $webMb).ToString($culture), $interval, $unreadable))
            $diagnostics.Add(('{0},4242,catalog-bench,True,{1},{2}' -f $time, ($hostMb * 1MB).ToString($culture), (2.0 + 0.3 * $s).ToString($culture)))
            $diagnostics.Add(('{0},5000,msedgewebview2,True,{1},{2}' -f $time, ($webMb * 1MB).ToString($culture), (1.0 + 0.2 * $s).ToString($culture)))
            if ($s -le 10) { $diagnostics.Add(('{0},5100,msedgewebview2,True,{1},{2}' -f $time, (10MB).ToString($culture), (0.5 + 0.1 * $s).ToString($culture))) }
        }
        $monitor | Set-Content -LiteralPath (Join-Path $runsDir "$($run.Name).monitor.csv") -Encoding UTF8
        $diagnostics | Set-Content -LiteralPath (Join-Path $runsDir "$($run.Name).monitor.diagnostics.csv") -Encoding UTF8
        $log.Add((@{ name = $run.Name; exitCode = 0; timedOut = $false; monitorExit = 0; monitorCpuSeconds = 1.0 } | ConvertTo-Json -Compress))
    }
    $log | Set-Content -LiteralPath (Join-Path $results 'runs.log') -Encoding UTF8

    $analysis = Join-Path $root 'analysis'
    & (Join-Path $PSScriptRoot 'Summarize-CatalogRuns.ps1') -ResultsDirectory $results -OutputDirectory $analysis | Out-Null
    $runs = @(Import-Csv -LiteralPath (Join-Path $analysis 'runs.csv'))
    $triplets = @(Import-Csv -LiteralPath (Join-Path $analysis 'triplets.csv'))
    $summaryText = Get-Content -LiteralPath (Join-Path $analysis 'summary.md') -Raw
    Assert-True 'summary: 8 runs' ($runs.Count -eq 8)
    Assert-True 'summary: 5 valid runs' (@($runs | Where-Object { $_.Valid -eq 'True' }).Count -eq 5) (($runs | ForEach-Object { "$($_.Name)=$($_.InvalidReason)" }) -join '; ')
    $gapRun = @($runs | Where-Object { $_.Cell -eq 'N2D0' -and $_.Triplet -eq '1' -and $_.Arm -eq 'A' })[0]
    Assert-True 'summary: a 7 s load gap invalidates the run' ($gapRun.Valid -eq 'False' -and $gapRun.InvalidReason -like '*load gap*') $gapRun.InvalidReason
    $failedRun = @($runs | Where-Object { $_.Cell -eq 'N2D16' -and $_.Triplet -eq '2' -and $_.Arm -eq 'B' })[0]
    Assert-True 'summary: a report that did not pass invalidates the run' ($failedRun.Valid -eq 'False' -and $failedRun.InvalidReason -like '*report not passed*w1: completed 39/40*') $failedRun.InvalidReason
    $valid = @($runs | Where-Object { $_.Cell -eq 'N2D16' -and $_.Triplet -eq '1' -and $_.Arm -eq 'B' })[0]
    Assert-Near 'summary: LoadPrivateMBAvg' $valid.LoadPrivateMBAvg 341
    Assert-Near 'summary: host Private' $valid.ExePrivateMBLoadAvg 141
    Assert-Near 'summary: WebView2 Private' $valid.WebViewPrivateMBLoadAvg 200
    Assert-Near 'summary: load CPU is the sum of 20 samples' $valid.LoadCpuSeconds 10
    Assert-Near 'summary: steady Private' $valid.SteadyPrivateMBAvg 341
    Assert-Near 'summary: coverage' $valid.LoadCoverage 1
    # At the end of the run (35 s): host 12.5 + WebView2 8.0 + the helper's last value 1.5 (it left after 10 s).
    Assert-Near 'summary: whole-run CPU sums each process''s last cumulative value' $valid.RunCpuSeconds 22.0 1e-6
    # At the warm-up start (5 s): host 3.5 + WebView2 2.0 + helper 1.0.
    Assert-Near 'summary: startup CPU' $valid.StartupCpuSeconds 6.5 1e-6
    Assert-Near 'summary: one process left the tree before the end' $valid.CpuExitedProcesses 1
    Assert-Near 'summary: three processes counted for CPU' $valid.CpuProcesses 3
    Assert-Near 'summary: whole-run coverage' $valid.RunCoverage 1
    $cpuGapRun = @($runs | Where-Object { $_.Cell -eq 'N2D0' -and $_.Triplet -eq '2' -and $_.Arm -eq 'A' })[0]
    Assert-True 'summary: unreadable CPU after the load phase invalidates the run' ($cpuGapRun.Valid -eq 'False' -and $cpuGapRun.InvalidReason -like '*whole-run CPU: unreadable CPU*' -and $cpuGapRun.InvalidReason -notlike '*load gap*') $cpuGapRun.InvalidReason
    Assert-True 'summary: the 7 s load gap also fails the whole-run check' ($gapRun.InvalidReason -like '*whole-run CPU: gap*') $gapRun.InvalidReason
    $diff = @($triplets | Where-Object { $_.Cell -eq 'N2D16' -and $_.Triplet -eq '1' -and $_.Comparison -eq 'B-A' })[0]
    Assert-Near 'triplet: B - A Σ Private' $diff.LoadPrivateMBDiff (-60)
    Assert-Near 'triplet: B - A host' $diff.ExePrivateMBDiff 40
    Assert-Near 'triplet: B - A WebView2' $diff.WebViewPrivateMBDiff (-100)
    Assert-Near 'triplet: B - A whole-run CPU' $diff.RunCpuSecondsDiff 0 1e-6
    $invalidPair = @($triplets | Where-Object { $_.Cell -eq 'N2D16' -and $_.Triplet -eq '2' })[0]
    Assert-True 'triplet: an invalid run gives no difference' ($invalidPair.Valid -eq 'False' -and $invalidPair.LoadPrivateMBDiff -eq '') $invalidPair.InvalidReason
    Assert-True 'summary.md: descriptive, no conclusion' ($summaryText -like '*Smoke: descriptive, no conclusion*')
    Assert-True 'summary.md: lists invalid runs' ($summaryText -like "*$($gapRun.Name): *load gap*")
    Assert-True 'summary.md: retained size of B above D0 (host 39.5 MB)' ($summaryText -match "\| N2D16 \| B \| 16 \| 16\.0 \| 39\.5 \| 0\.0 \|")
    Assert-True 'processes.csv: host and WebView2 rows' (@(Import-Csv -LiteralPath (Join-Path $analysis 'processes.csv') | Where-Object { $_.Host -eq 'True' }).Count -eq 8)
    $threw = $false
    try { & (Join-Path $PSScriptRoot 'Summarize-CatalogRuns.ps1') -ResultsDirectory $results -OutputDirectory $analysis | Out-Null } catch { $threw = $true }
    Assert-True 'summary: never overwrites an analysis' $threw
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Summarizer with a monitor that records process identities (#43).
# Four runs, one case each:
#   N2D0 A  : a WebView2 child (5200) is in the tree for 3 load samples -> valid, 1 transient process
#   N2D0 B  : one load row has an unverified process                      -> invalid
#   N2D16 A : a WebView2 process of the app is outside the tree           -> invalid
#   N2D16 B : PID 5100 is reused by a new process after the first exits   -> valid, the two are separate CPU processes
$root = Join-Path ([System.IO.Path]::GetTempPath()) ("catalog-test-id-{0}" -f [guid]::NewGuid().ToString('N'))
try {
    $results = Join-Path $root 'results'
    $runsDir = Join-Path $results 'runs'
    New-Item -ItemType Directory -Force -Path $runsDir | Out-Null
    $schedule = @(New-CatalogSchedule -Cells N2D0, N2D16 -Arms A, B -Triplets 1 -Seed 0)
    $schedule | Export-Csv -LiteralPath (Join-Path $results 'schedule.csv') -NoTypeInformation -Encoding UTF8
    [ordered]@{
        scenario = 'M'; phase = 'Smoke'; os = 'Synthetic OS'; machine = 'TEST'; gitHead = 'abc'; gitDirty = $false
        arms = @('A', 'B'); cells = @('N2D0', 'N2D16'); triplets = 1; scheduleSeed = 0; sampleIntervalSeconds = 1
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $results 'configuration.json') -Encoding UTF8
    $start = [DateTimeOffset]::Parse('2026-10-28T10:00:00Z', $culture)
    $log = New-Object System.Collections.Generic.List[string]
    $offset = 0
    foreach ($run in $schedule) {
        $t0 = $start.AddMinutes($offset); $offset += 10
        $case = '{0}{1}' -f $run.Cell, $run.Arm
        [ordered]@{
            schemaVersion = 1; scenario = 'M'; passed = $true; problems = @()
            config = [ordered]@{ arm = $run.Arm; windows = [int]$run.Windows; dataMib = [int]$run.DataMib; records = 1000; rustDataBytes = [int]$run.DataMib * 1MB }
            phases = [ordered]@{
                idleBeforeStartedAt = $t0.ToString('o'); warmupStartedAt = $t0.AddSeconds(5).ToString('o'); loadStartedAt = $t0.AddSeconds(10).ToString('o')
                loadEndedAt = $t0.AddSeconds(30).ToString('o'); endedAt = $t0.AddSeconds(35).ToString('o')
            }
            totals = [ordered]@{ scheduledSteps = 80; completedSteps = 80; failures = 0; mismatches = 0; overruns = 0; maxP95LatencyMs = 3.5; maxTimeToFirstPageMs = 120; loadJsHeapAvgBytes = 8MB }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runsDir "$($run.Name).json") -Encoding UTF8
        $monitor = New-Object System.Collections.Generic.List[string]
        $diagnostics = New-Object System.Collections.Generic.List[string]
        $monitor.Add('Timestamp,Sample,RootPid,ProcessCount,ProcessIds,ProcessKeys,WorkingSetMB,PrivateBytesMB,CpuDeltaSeconds,IntervalSeconds,PrivateMissingCount,CpuUnreadableCount,RejectedPidReuseCount,UnverifiedProcessCount,CpuExitedUnreadIds,CpuAccessDeniedIds,CpuIdentityChangedIds,CpuLeftTreeIds,CpuReadErrorIds')
        $diagnostics.Add('Timestamp,Pid,ProcessKey,Name,InTree,CimPrivatePageCount,ProcTotalProcessorSeconds')
        for ($s = 0; $s -le 36; $s++) {
            $time = $t0.AddSeconds($s).ToString('o')
            $interval = if ($s -eq 0) { '' } else { '1' }
            $members = New-Object System.Collections.Generic.List[object]
            $members.Add(@(4242, '4242@1', 'catalog-bench', 100.0, (2.0 + 0.3 * $s)))
            $members.Add(@(5000, '5000@2', 'msedgewebview2', 200.0, (1.0 + 0.2 * $s)))
            if ($case -eq 'N2D0A' -and $s -ge 15 -and $s -le 17) { $members.Add(@(5200, '5200@9', 'msedgewebview2', 20.0, (0.1 * ($s - 14)))) }
            if ($case -eq 'N2D16B') {
                if ($s -le 10) { $members.Add(@(5100, '5100@3', 'msedgewebview2', 10.0, (0.5 + 0.1 * $s))) }
                elseif ($s -ge 20) { $members.Add(@(5100, '5100@7', 'msedgewebview2', 10.0, (0.05 * ($s - 19)))) }
            }
            $unverified = if ($case -eq 'N2D0B' -and $s -eq 20) { 1 } else { 0 }
            # N2D16 A also loses the CPU time of a child that exited before its first read (monitor reason columns).
            $cpuMissing = if ($case -eq 'N2D16A' -and $s -eq 12) { @(1, '6101,,,,') } else { @(0, ',,,,') }
            $private = ($members | ForEach-Object { $_[3] } | Measure-Object -Sum).Sum
            $monitor.Add(('{0},{1},4242,{2},{3},{4},{5},{6},0.5,{7},0,{9},0,{8},{10}' -f $time, $s, $members.Count, (($members | ForEach-Object { $_[0] }) -join ';'), (($members | ForEach-Object { $_[1] }) -join ';'), ($private + 50).ToString($culture), $private.ToString($culture), $interval, $unverified, $cpuMissing[0], $cpuMissing[1]))
            foreach ($m in $members) { $diagnostics.Add(('{0},{1},{2},{3},True,{4},{5}' -f $time, $m[0], $m[1], $m[2], ($m[3] * 1MB).ToString($culture), ([double]$m[4]).ToString($culture))) }
            if ($case -eq 'N2D16A' -and $s -eq 12) { $diagnostics.Add(('{0},6100,6100@8,msedgewebview2,False,{1},0.1' -f $time, (30MB).ToString($culture))) }
        }
        $monitor | Set-Content -LiteralPath (Join-Path $runsDir "$($run.Name).monitor.csv") -Encoding UTF8
        $diagnostics | Set-Content -LiteralPath (Join-Path $runsDir "$($run.Name).monitor.diagnostics.csv") -Encoding UTF8
        $log.Add((@{ name = $run.Name; exitCode = 0; timedOut = $false; monitorExit = 0; monitorCpuSeconds = 1.0 } | ConvertTo-Json -Compress))
    }
    $log | Set-Content -LiteralPath (Join-Path $results 'runs.log') -Encoding UTF8
    $analysis = Join-Path $root 'analysis'
    & (Join-Path $PSScriptRoot 'Summarize-CatalogRuns.ps1') -ResultsDirectory $results -OutputDirectory $analysis | Out-Null
    $runs = @(Import-Csv -LiteralPath (Join-Path $analysis 'runs.csv'))
    $byCase = @{}
    foreach ($r in $runs) { $byCase['{0}{1}' -f $r.Cell, $r.Arm] = $r }
    $all = ($runs | ForEach-Object { "$($_.Cell)$($_.Arm)=$($_.InvalidReason)" }) -join '; '
    Assert-True 'identity: a verified short-lived child does not invalidate the run' ($byCase['N2D0A'].Valid -eq 'True') $all
    Assert-Near 'identity: the short-lived child is counted as transient' $byCase['N2D0A'].TransientProcesses 1
    Assert-True 'identity: the process count still shows the change' ($byCase['N2D0A'].LoadProcessCountMin -eq '2' -and $byCase['N2D0A'].LoadProcessCountMax -eq '3')
    Assert-Near 'identity: the short-lived child is in the load average (20 MB in 3 of 20 rows)' $byCase['N2D0A'].LoadPrivateMBAvg 303
    Assert-True 'identity: an unverified process in a load row invalidates the run' ($byCase['N2D0B'].Valid -eq 'False' -and $byCase['N2D0B'].InvalidReason -like '*process tree not verified in 1 load row*') $byCase['N2D0B'].InvalidReason
    Assert-True 'identity: an unverified process also fails whole-run CPU' ($byCase['N2D0B'].InvalidReason -like '*whole-run CPU: unverified processes*') $byCase['N2D0B'].InvalidReason
    Assert-True 'identity: a WebView2 process of the app outside the tree invalidates the run' ($byCase['N2D16A'].Valid -eq 'False' -and $byCase['N2D16A'].InvalidReason -like '*outside the monitored tree: 6100*') $byCase['N2D16A'].InvalidReason
    Assert-True 'identity: a CPU value missing for a stated reason invalidates the run and names the reason' ($byCase['N2D16A'].InvalidReason -like '*whole-run CPU: unreadable CPU in a monitor row (ExitedUnread 6101)*') $byCase['N2D16A'].InvalidReason
    Assert-True 'identity: a reused PID does not invalidate the run' ($byCase['N2D16B'].Valid -eq 'True') $byCase['N2D16B'].InvalidReason
    Assert-Near 'identity: a reused PID is a separate CPU process' $byCase['N2D16B'].CpuProcesses 4
    # host 2 + 0.3 * 35 = 12.5, WebView2 1 + 0.2 * 35 = 8.0, first 5100 last 1.5, second 5100 last 0.05 * 16 = 0.8
    Assert-Near 'identity: whole-run CPU keeps both processes that had PID 5100' $byCase['N2D16B'].RunCpuSeconds 22.8 1e-6
    Assert-True 'identity: results without cpuSource are legacy and use the monitor rule' (@($runs | Where-Object { $_.CpuSource -ne 'legacy-monitor' }).Count -eq 0)
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Thresholds (protocol §8b, Q7): forms at and around the floor crossover.
$marginCases = @(
    @('Delta', 'RAM', 150.0, 10.0), @('Delta', 'RAM', 200.0, 10.0), @('Delta', 'RAM', 300.0, 15.0),
    @('Delta', 'CPU', 5.0, 1.0), @('Delta', 'CPU', 10.0, 1.0), @('Delta', 'CPU', 25.0, 2.5),
    @('Eta', 'RAM', 200.0, 10.0), @('Eta', 'RAM', 400.0, 20.0),
    @('Eta', 'CPU', 0.0, 1.0), @('Eta', 'CPU', 20.0, 3.0),
    @('Epsilon', 'RAM', 250.0, 5.0), @('Epsilon', 'RAM', 400.0, 8.0),
    @('Epsilon', 'CPU', 10.0, 0.5), @('Epsilon', 'CPU', 30.0, 1.5)
)
foreach ($case in $marginCases) {
    $margin = Get-CatalogMargin -Kind $case[0] -Outcome $case[1] -Reference $case[2]
    Assert-Near "margin $($case[0]) $($case[1]) at reference $($case[2])" $margin.ToString('R', $culture) $case[3] 1e-12
}
$threw = $false
try { Get-CatalogMargin -Kind Delta -Outcome RAM -Reference -1 | Out-Null } catch { $threw = $true }
Assert-True 'margin: negative reference refused' $threw

# Pilot reference: median of valid pilot runs per cell and arm, rounded; invalid runs and other cells ignored.
function New-ThresholdRun {
    param([string]$Cell, [string]$Arm, [bool]$Valid, [double]$Ram, [double]$Cpu)
    [pscustomobject]@{ Cell = $Cell; Arm = $Arm; Valid = $Valid; LoadPrivateMBAvg = $Ram.ToString('R', $culture); RunCpuSeconds = $Cpu.ToString('R', $culture) }
}
$pilot = New-Object System.Collections.Generic.List[object]
foreach ($pair in @(@(300.04, 20.004), @(310.0, 21.0), @(305.0, 20.5), @(320.0, 22.0), @(290.0, 19.0))) { $pilot.Add((New-ThresholdRun 'N2D16' 'A' $true $pair[0] $pair[1])) }
$pilot.Add((New-ThresholdRun 'N2D16' 'A' $false 1.0 0.1))
foreach ($pair in @(@(250.0, 10.0), @(260.0, 11.0), @(255.0, 10.5), @(270.0, 12.0))) { $pilot.Add((New-ThresholdRun 'N2D16' 'B' $true $pair[0] $pair[1])) }
foreach ($pair in @(@(500.0, 30.0), @(510.0, 31.0), @(505.0, 30.5))) { $pilot.Add((New-ThresholdRun 'N4D64' 'A' $true $pair[0] $pair[1])) }
$pilot.Add((New-ThresholdRun 'N4D64' 'A' $false 900.0 90.0))
foreach ($pair in @(@(400.0, 20.0), @(410.0, 21.0), @(405.0, 20.5), @(415.0, 21.5))) { $pilot.Add((New-ThresholdRun 'N4D64' 'B' $true $pair[0] $pair[1])) }

$refRam = Get-CatalogReference -Runs $pilot.ToArray() -Phase Pilot -Cell N2D16 -Arm A -Outcome RAM
Assert-Near 'reference: odd count, invalid run ignored' $refRam.Reference.ToString('R', $culture) 305.0
Assert-True 'reference: 5 valid runs counted' ($refRam.ValidRuns -eq 5) "got $($refRam.ValidRuns)"
$refB = Get-CatalogReference -Runs $pilot.ToArray() -Phase Pilot -Cell N2D16 -Arm B -Outcome CPU
Assert-Near 'reference: even count takes the mean of the middle two' $refB.Reference.ToString('R', $culture) 10.75
$rounding = @((New-ThresholdRun 'X' 'A' $true 100.04 1.004), (New-ThresholdRun 'X' 'A' $true 100.06 1.006), (New-ThresholdRun 'X' 'A' $true 100.05 1.005), (New-ThresholdRun 'X' 'A' $true 100.05 1.005))
Assert-Near 'reference: RAM rounded to 0.1 MiB' (Get-CatalogReference -Runs $rounding -Phase Pilot -Cell X -Arm A -Outcome RAM).Reference.ToString('R', $culture) 100.1
Assert-Near 'reference: CPU rounded to 0.01 s' (Get-CatalogReference -Runs $rounding -Phase Pilot -Cell X -Arm A -Outcome CPU).Reference.ToString('R', $culture) 1.01
$short = Get-CatalogReference -Runs $pilot.ToArray() -Phase Pilot -Cell N4D64 -Arm A -Outcome RAM
Assert-True 'reference: 3 valid runs give no reference' ($null -eq $short.Reference -and $short.Reason -like '3 valid pilot runs*need 4*') "got '$($short.Reference)' '$($short.Reason)'"
foreach ($phase in @('Confirmatory', 'Smoke', '')) {
    $threw = $false
    try { Get-CatalogReference -Runs $pilot.ToArray() -Phase $phase -Cell N2D16 -Arm A -Outcome RAM | Out-Null } catch { $threw = $true }
    Assert-True "reference: phase '$phase' refused" $threw
    $threw = $false
    try { New-CatalogThresholds -Runs $pilot.ToArray() -Phase $phase -Cells N2D16 | Out-Null } catch { $threw = $true }
    Assert-True "thresholds: phase '$phase' refused" $threw
}

# thresholds.csv content: every cell x kind x outcome; no floor fallback without a reference; CSV round trip keeps the values.
$table = @(New-CatalogThresholds -Runs $pilot.ToArray() -Phase Pilot -Cells N2D16, N4D64)
Assert-True 'thresholds: 2 cells x 6 rows' ($table.Count -eq 12) "got $($table.Count)"
$row = @($table | Where-Object { $_.Cell -eq 'N2D16' -and $_.Kind -eq 'Delta' -and $_.Outcome -eq 'RAM' })[0]
Assert-Near 'thresholds: N2D16 delta RAM = max(10, 5% of 305)' $row.Threshold.ToString('R', $culture) 15.25
$row = @($table | Where-Object { $_.Cell -eq 'N2D16' -and $_.Kind -eq 'Eta' -and $_.Outcome -eq 'CPU' })[0]
Assert-Near 'thresholds: N2D16 eta CPU = 1 + 10% of 20.5' $row.Threshold.ToString('R', $culture) 3.05
$row = @($table | Where-Object { $_.Cell -eq 'N2D16' -and $_.Kind -eq 'Epsilon' -and $_.Outcome -eq 'CPU' })[0]
Assert-Near 'thresholds: N2D16 epsilon CPU from arm B = max(0.5, 5% of 10.75)' $row.Threshold.ToString('R', $culture) 0.5375
$missing = @($table | Where-Object { $_.Cell -eq 'N4D64' -and $_.ReferenceArm -eq 'A' })
Assert-True 'thresholds: N4D64 arm-A rows have no threshold (no floor fallback)' (@($missing | Where-Object { $null -ne $_.Threshold }).Count -eq 0 -and $missing.Count -eq 4)
$present = @($table | Where-Object { $_.Cell -eq 'N4D64' -and $_.ReferenceArm -eq 'B' -and $null -ne $_.Threshold })
Assert-True 'thresholds: N4D64 arm-B rows still have a threshold' ($present.Count -eq 2) "got $($present.Count)"
$csvRuns = @($pilot | ConvertTo-Csv -NoTypeInformation | ConvertFrom-Csv)
$csvTable = @(New-CatalogThresholds -Runs $csvRuns -Phase Pilot -Cells N2D16, N4D64)
Assert-True 'thresholds: same values after a CSV round trip of the runs' ((($table | ForEach-Object { "$($_.Threshold)" }) -join ',') -eq (($csvTable | ForEach-Object { "$($_.Threshold)" }) -join ','))

# The smoke plan written before the run (plans\smoke-abc-3): the runner's -ExpectedSchedule check accepts it
# for the planned parameters and refuses any other seed, cell list or edited row.
$planFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'plans\smoke-abc-3\schedule.csv'
$planCells = @('N2D0', 'N2D16', 'N2D64', 'N4D64')
Assert-True 'plan: smoke-abc-3 matches seed 1, 4 cells, 1 triplet' (Test-CatalogScheduleMatchesFile -Schedule @(New-CatalogSchedule -Cells $planCells -Arms A, B, C -Triplets 1 -Seed 1 -DataSeed 1) -Path $planFile)
Assert-True 'plan: smoke-abc-3 is a complete schedule' (@(Test-CatalogSchedule -Schedule @(Import-Csv -LiteralPath $planFile) -Cells $planCells -Arms A, B, C -Triplets 1).Count -eq 0)
Assert-True 'plan: another schedule seed is refused' (-not (Test-CatalogScheduleMatchesFile -Schedule @(New-CatalogSchedule -Cells $planCells -Arms A, B, C -Triplets 1 -Seed 2 -DataSeed 1) -Path $planFile))
Assert-True 'plan: another data seed is refused' (-not (Test-CatalogScheduleMatchesFile -Schedule @(New-CatalogSchedule -Cells $planCells -Arms A, B, C -Triplets 1 -Seed 1 -DataSeed 2) -Path $planFile))
Assert-True 'plan: fewer cells are refused' (-not (Test-CatalogScheduleMatchesFile -Schedule @(New-CatalogSchedule -Cells N2D0, N2D16 -Arms A, B, C -Triplets 1 -Seed 1 -DataSeed 1) -Path $planFile))

# thresholds.csv for the confirmatory analysis: read only when its SHA-256 matches the frozen value (protocol §10a).
$root = Join-Path ([System.IO.Path]::GetTempPath()) ("catalog-test-hash-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
try {
    $thresholdsCsv = Join-Path $root 'thresholds.csv'
    $originalCulture = [Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('de-AT')
        Export-CatalogThresholds -Rows $table -Path $thresholdsCsv
    } finally {
        [Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
    }
    $frozen = Get-CatalogFileSha256 -Path $thresholdsCsv
    $loaded = Import-CatalogThresholds -Path $thresholdsCsv -ExpectedSha256 $frozen.ToUpperInvariant() -Cells N2D16, N4D64
    Assert-True 'thresholds hash: the frozen file is read, any letter case' ($loaded.Sha256 -eq $frozen -and @($loaded.Rows).Count -eq 12)
    $row = @($loaded.Rows | Where-Object { $_.Cell -eq 'N2D16' -and $_.Kind -eq 'Delta' -and $_.Outcome -eq 'RAM' })[0]
    Assert-Near 'thresholds hash: values survive the file' ([string]$row.Threshold) 15.25
    $refused = {
        param([string]$Name, [string]$Path, [string]$Hash, [string[]]$ForCells, [string]$Pattern)
        $message = ''
        try { Import-CatalogThresholds -Path $Path -ExpectedSha256 $Hash -Cells $ForCells | Out-Null } catch { $message = $_.Exception.Message }
        Assert-True "thresholds hash: $Name stops the analysis" ($message -match $Pattern) "got '$message'"
    }
    $changed = Join-Path $root 'thresholds-changed.csv'
    [System.IO.File]::WriteAllText($changed, ([System.IO.File]::ReadAllText($thresholdsCsv)).Replace('15.25', '15.26'))
    & $refused 'one changed value' $changed $frozen @('N2D16', 'N4D64') 'does not match the frozen'
    & $refused 'a missing file' (Join-Path $root 'none.csv') $frozen @('N2D16', 'N4D64') 'not found'
    & $refused 'a malformed frozen hash' $thresholdsCsv 'abc' @('N2D16', 'N4D64') 'not a 64-digit'
    & $refused 'an empty frozen hash' $thresholdsCsv '' @('N2D16', 'N4D64') 'not a 64-digit'
    & $refused 'a cell missing from the file' $thresholdsCsv $frozen @('N2D16', 'N4D64', 'N2D0') 'missing: N2D0/'
    & $refused 'a cell not in the plan' $thresholdsCsv $frozen @('N2D16') 'unexpected: N4D64/'
    $doubled = Join-Path $root 'thresholds-doubled.csv'
    Export-CatalogThresholds -Rows (@($table) + @($table[0])) -Path $doubled
    & $refused 'a duplicated row' $doubled (Get-CatalogFileSha256 -Path $doubled) @('N2D16', 'N4D64') 'duplicated: N2D16/Delta/RAM'
    $text = Join-Path $root 'thresholds-text.csv'
    [System.IO.File]::WriteAllText($text, ([System.IO.File]::ReadAllText($thresholdsCsv)).Replace('15.25', 'n/a'))
    & $refused 'a non-numeric threshold' $text (Get-CatalogFileSha256 -Path $text) @('N2D16', 'N4D64') 'non-numeric threshold'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# Sign counts at the threshold: d = -delta exactly counts against H1 and stays in n.
$count = Get-SignCount -Differences @(-12.0, -10.0, -15.0, -9.0, -11.0) -Shift 10.0
Assert-True 'sign: at the threshold is neither below nor dropped' ($count.N -eq 5 -and $count.Below -eq 3 -and $count.AtZero -eq 1 -and $count.Above -eq 1) "got $($count.Below)/$($count.AtZero)/$($count.Above) of $($count.N)"
$count = Get-SignCount -Differences @(-1.1, -1.2, 0.5) -Shift 1.1
Assert-True 'sign: fractional CPU threshold hit exactly' ($count.Below -eq 1 -and $count.AtZero -eq 1 -and $count.Above -eq 1)
$count = Get-SignCount -Differences @(2.9, 3.05, 3.1) -Shift -3.05
Assert-True 'sign: non-inferiority shift (d - eta)' ($count.Below -eq 1 -and $count.AtZero -eq 1 -and $count.Above -eq 1)

# Cut-offs of the protocol table (§8b): family P at 0.05/6, non-inferiority at 0.05/3.
foreach ($case in @(@(11, 10), @(14, 12), @(20, 16), @(28, 21))) {
    foreach ($alpha in @((0.05 / 6), (0.05 / 3))) {
        $k = Get-SignCritical -N $case[0] -Alpha $alpha
        Assert-True "critical: n=$($case[0]) alpha=$([Math]::Round($alpha, 4)) is $($case[1])" ($k -eq $case[1]) "got $k"
        Assert-True "critical: n=$($case[0]) size at k within alpha, k-1 above" ((Get-BinomialUpperTail -N $case[0] -K $k -P 0.5) -le $alpha -and (Get-BinomialUpperTail -N $case[0] -K ($k - 1) -P 0.5) -gt $alpha)
    }
}
Assert-Near 'power: n=14, k=12, p=0.90' (Get-BinomialUpperTail -N 14 -K 12 -P 0.9).ToString('R', $culture) 0.8416 0.0001
Assert-True 'critical: too few triplets can never reject' ((Get-SignCritical -N 5 -Alpha (0.05 / 6)) -eq 6)

$diffs = @(-20.0, -20.0, -20.0, -20.0, -20.0, -20.0, -20.0, -20.0, -20.0, -20.0, 5.0)
$test = Test-SignMargin -Differences $diffs -Shift 10.0 -Alpha (0.05 / 6)
Assert-True 'test: 10 of 11 below -delta rejects' ($test.Reject -and $test.Critical -eq 10)
$diffs[0] = -10.0
$test = Test-SignMargin -Differences $diffs -Shift 10.0 -Alpha (0.05 / 6)
Assert-True 'test: one moved onto the threshold no longer rejects' (-not $test.Reject -and $test.Below -eq 9 -and $test.AtZero -eq 1 -and $test.N -eq 11)
$test = Test-SignMargin -Differences @() -Shift 10.0 -Alpha (0.05 / 6)
Assert-True 'test: no triplets never rejects' (-not $test.Reject)

# --- Pilot freeze manifest (CatalogManifest.ps1, protocol §10a).
$pilotSchedule = @(New-CatalogSchedule -Cells $cells -Arms A, B, C -Triplets 6 -Seed 1 -DataSeed 1)
Assert-True 'manifest: the pilot schedule has 72 runs' ($pilotSchedule.Count -eq 72)
$roundTrip = Join-Path ([System.IO.Path]::GetTempPath()) ("catalog-schedule-{0}.csv" -f [guid]::NewGuid().ToString('N'))
try {
    $pilotSchedule | Export-Csv -LiteralPath $roundTrip -NoTypeInformation -Encoding UTF8
    $read = @(Import-Csv -LiteralPath $roundTrip)
    Assert-True 'manifest: schedule content hash survives a CSV round trip' ((Get-CatalogScheduleSha256 $pilotSchedule) -eq (Get-CatalogScheduleSha256 $read))
    (Get-Content -LiteralPath $roundTrip) -join "`r`n" | Set-Content -LiteralPath $roundTrip -Encoding UTF8 -NoNewline
    Assert-True 'manifest: schedule content hash does not depend on line endings' ((Get-CatalogScheduleSha256 $pilotSchedule) -eq (Get-CatalogScheduleSha256 @(Import-Csv -LiteralPath $roundTrip)))
}
finally { Remove-Item -LiteralPath $roundTrip -Force -ErrorAction SilentlyContinue }
$otherSchedule = @(New-CatalogSchedule -Cells $cells -Arms A, B, C -Triplets 6 -Seed 2 -DataSeed 1)
Assert-True 'manifest: another seed gives another schedule hash' ((Get-CatalogScheduleSha256 $pilotSchedule) -ne (Get-CatalogScheduleSha256 $otherSchedule))
function New-TestConfiguration {
    [ordered]@{
        phase = 'Pilot'; machine = 'PC'; os = 'Windows 10 (build 19045)'; webView2 = '130.0'; gitHead = ('a' * 40); gitDirty = $false
        monitorGitHead = ('c' * 40); monitorSha256 = ('D' * 64); monitorUnitCheckRequireChildName = 'msedgewebview2.exe'; cpuSource = 'job'
        jobLimits = [ordered]@{ SampleIntervalMs = 250; MaxBoundaryGapSeconds = 0.5 }; jobScriptSha256 = ('E' * 64)
        executables = [ordered]@{ A = [ordered]@{ sha256 = ('1' * 64); bytes = 100 }; B = [ordered]@{ sha256 = ('2' * 64); bytes = 100 }; C = [ordered]@{ sha256 = ('3' * 64); bytes = 100 } }
        sampleIntervalSeconds = 1; cells = $cells; arms = @('A', 'B', 'C'); triplets = 6; scheduleSeed = 1; dataSeed = 1
        idleBeforeSeconds = 20; warmupSeconds = 30; loadSeconds = 120; idleAfterSeconds = 30; pauseSeconds = 30; stepIntervalMs = 500
        runScriptSha256 = ('F' * 64); scheduleScriptSha256 = ('F' * 64); summarizeScriptSha256 = ('F' * 64); manifestScriptSha256 = ('F' * 64); readmeSha256 = ('F' * 64); protocolSha256 = ('F' * 64)
        createdAt = '2026-11-06T20:00:00Z'; dryRun = $true
    }
}
$manifestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("catalog-manifest-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $manifestRoot | Out-Null
try {
    $frozen = New-CatalogManifest -Configuration (New-TestConfiguration) -Schedule $pilotSchedule
    Assert-True 'manifest: createdAt and dryRun are not frozen' (-not $frozen.Contains('createdAt') -and -not $frozen.Contains('dryRun'))
    Assert-Near 'manifest: 72 runs' $frozen.runs 72
    $frozenPath = Join-Path $manifestRoot 'manifest.json'
    $frozen | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $frozenPath -Encoding UTF8
    $frozenHash = (Get-FileHash -LiteralPath $frozenPath -Algorithm SHA256).Hash
    $same = New-TestConfiguration; $same.createdAt = '2026-11-07T08:00:00Z'; $same.dryRun = $false
    $ok = $null
    try { $ok = Assert-CatalogManifest -FrozenPath $frozenPath -FrozenSha256 $frozenHash -Current (New-CatalogManifest -Configuration $same -Schedule $pilotSchedule) } catch { $ok = $_.Exception.Message }
    Assert-True 'manifest: the same configuration and schedule pass (time and dry-run flag aside)' ($ok -eq $frozenHash.ToLowerInvariant()) $ok
    $cases = @(
        @('scenario SHA', { param($c) $c.gitHead = ('b' * 40) }, 'gitHead'),
        @('dirty checkout', { param($c) $c.gitDirty = $true }, 'gitDirty'),
        @('monitor SHA', { param($c) $c.monitorGitHead = ('0' * 40) }, 'monitorGitHead'),
        @('executable hash', { param($c) $c.executables.C.sha256 = ('9' * 64) }, 'executables.C.sha256'),
        @('load phase length', { param($c) $c.loadSeconds = 60 }, 'loadSeconds'),
        @('job limit', { param($c) $c.jobLimits.MaxBoundaryGapSeconds = 1.0 }, 'jobLimits.MaxBoundaryGapSeconds'),
        @('WebView2 version', { param($c) $c.webView2 = '131.0' }, 'webView2'),
        @('phase', { param($c) $c.phase = 'Smoke' }, 'phase')
    )
    foreach ($case in $cases) {
        $changed = New-TestConfiguration
        & $case[1] $changed
        $message = ''
        try { [void](Assert-CatalogManifest -FrozenPath $frozenPath -FrozenSha256 $frozenHash -Current (New-CatalogManifest -Configuration $changed -Schedule $pilotSchedule)) } catch { $message = $_.Exception.Message }
        Assert-True "manifest: a different $($case[0]) is refused and named" ($message -like "*differs from the frozen manifest*$($case[2]): frozen*") $message
    }
    $message = ''
    try { [void](Assert-CatalogManifest -FrozenPath $frozenPath -FrozenSha256 $frozenHash -Current (New-CatalogManifest -Configuration (New-TestConfiguration) -Schedule $otherSchedule)) } catch { $message = $_.Exception.Message }
    Assert-True 'manifest: a different schedule is refused' ($message -like '*scheduleContentSha256: frozen*') $message
    $message = ''
    try { [void](Assert-CatalogManifest -FrozenPath $frozenPath -FrozenSha256 ('0' * 64) -Current $frozen) } catch { $message = $_.Exception.Message }
    Assert-True 'manifest: a manifest file with another hash is refused' ($message -like '*does not match*nothing was run*') $message
    $message = ''
    try { [void](Assert-CatalogManifest -FrozenPath $frozenPath -FrozenSha256 'abc' -Current $frozen) } catch { $message = $_.Exception.Message }
    Assert-True 'manifest: a malformed frozen hash is refused' ($message -like '*not a 64-digit hex value*') $message
    $message = ''
    try { [void](Assert-CatalogManifest -FrozenPath (Join-Path $manifestRoot 'missing.json') -FrozenSha256 $frozenHash -Current $frozen) } catch { $message = $_.Exception.Message }
    Assert-True 'manifest: a missing manifest is refused' ($message -like '*not found*') $message
    # Separate results directories: never reused, never nested.
    $results = Join-Path $manifestRoot 'pilot'
    New-Item -ItemType Directory -Path $results | Out-Null
    Assert-True 'directories: a new directory is accepted' (@(Test-CatalogResultsDirectory -Path (Join-Path $manifestRoot 'new')).Count -eq 0)
    '{}' | Set-Content -LiteralPath (Join-Path $results 'configuration.json')
    Assert-True 'directories: a used directory is refused' ((@(Test-CatalogResultsDirectory -Path $results) -join ';') -like '*already has configuration.json*')
    Assert-True 'directories: a directory inside another results directory is refused' ((@(Test-CatalogResultsDirectory -Path (Join-Path $results 'confirmatory')) -join ';') -like '*inside another results directory*')
}
finally { Remove-Item -LiteralPath $manifestRoot -Recurse -Force -ErrorAction SilentlyContinue }

# --- Confirmatory analysis inputs (CatalogConfirmatory.ps1, protocol §10a, confirmatory freeze).
# Fixture: a confirmatory freeze of cells N2D16 and N4D64, 2 triplets (12 runs), with the
# thresholds.csv of the pilot fixture above; the run in two sessions split between blocks.
$confirmRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("catalog-confirm-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $confirmRoot | Out-Null
try {
    $confirmCells = @('N2D16', 'N4D64')
    function New-ConfirmConfiguration {
        $c = New-TestConfiguration
        $c.phase = 'Confirmatory'; $c.cells = $confirmCells; $c.triplets = 2; $c.scheduleSeed = 3; $c.dryRun = $false
        $c['signFamilies'] = [ordered]@{ P = @('N2D16/RAM'); 'NI-RAM' = @(); 'NI-CPU' = @('N2D16/CPU') }
        $c
    }
    function New-Freeze {
        param([string]$Name, [System.Collections.IDictionary]$Configuration, [object[]]$Schedule)
        $directory = Join-Path $confirmRoot "freeze-$Name"
        New-Item -ItemType Directory -Path $directory | Out-Null
        $path = Join-Path $directory 'manifest.json'
        New-CatalogManifest -Configuration $Configuration -Schedule $Schedule | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
        [pscustomobject]@{ Path = $path; Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    function New-Session {
        # A results directory as the runner leaves it, with runs.log entries for the given runs.
        param([string]$Name, [object]$Freeze, [object[]]$Schedule, [string[]]$Runs, [hashtable]$Configuration = @{}, [string]$ManifestPath, [string[]]$Skip = @())
        $directory = Join-Path $confirmRoot $Name
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
        $config = [ordered]@{ phase = 'Confirmatory'; dryRun = $false; frozenManifestSha256 = $Freeze.Sha256 }
        foreach ($key in $Configuration.Keys) { $config[$key] = $Configuration[$key] }
        if ($Skip -notcontains 'configuration.json') { $config | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'configuration.json') -Encoding UTF8 }
        if ($Skip -notcontains 'manifest.json') { Copy-Item -LiteralPath $(if ($ManifestPath) { $ManifestPath } else { $Freeze.Path }) -Destination (Join-Path $directory 'manifest.json') }
        if ($Skip -notcontains 'schedule.csv') { $Schedule | Export-Csv -LiteralPath (Join-Path $directory 'schedule.csv') -NoTypeInformation -Encoding UTF8 }
        if ($Skip -notcontains 'runs.log') { @($Runs | ForEach-Object { (@{ name = $_; exitCode = 0 } | ConvertTo-Json -Compress) }) | Set-Content -LiteralPath (Join-Path $directory 'runs.log') -Encoding UTF8 }
        $directory
    }
    $confirmSchedule = @(New-CatalogSchedule -Cells $confirmCells -Arms A, B, C -Triplets 2 -Seed 3 -DataSeed 1)
    $block1 = @($confirmSchedule | Where-Object { [int]$_.Block -eq 1 } | ForEach-Object { $_.Name })
    $block2 = @($confirmSchedule | Where-Object { [int]$_.Block -eq 2 } | ForEach-Object { $_.Name })
    $freeze = New-Freeze 'ok' (New-ConfirmConfiguration) $confirmSchedule
    $thresholdsFile = Join-Path $confirmRoot 'freeze-ok\thresholds.csv'
    Export-CatalogThresholds -Rows $table -Path $thresholdsFile
    $thresholdsSha = (Get-FileHash -LiteralPath $thresholdsFile -Algorithm SHA256).Hash.ToLowerInvariant()
    $session1 = New-Session 'session-1' $freeze $confirmSchedule $block1
    $session2 = New-Session 'session-2' $freeze $confirmSchedule $block2

    function Test-Confirm {
        param([string[]]$Directories, [object]$Freeze = $freeze, [string]$Thresholds = $thresholdsFile, [string]$ThresholdsHash = $thresholdsSha)
        Test-CatalogConfirmatoryInputs -ResultsDirectories $Directories -FrozenManifestPath $Freeze.Path -FrozenManifestSha256 $Freeze.Sha256 -ThresholdsPath $Thresholds -ThresholdsSha256 $ThresholdsHash
    }
    function Assert-ConfirmRefused {
        param([string]$Name, [object]$Checked, [string]$Pattern)
        $text = @($Checked.Problems) -join ' | '
        Assert-True "confirmatory inputs: $Name stops the analysis" ($Checked.Problems.Count -gt 0 -and $text -like "*$Pattern*") "expected '$Pattern', got '$text'"
    }

    Assert-True 'confirmatory fixture: 12 runs in two blocks of 6' ($confirmSchedule.Count -eq 12 -and $block1.Count -eq 6 -and $block2.Count -eq 6)
    $checked = Test-Confirm @($session1, $session2)
    Assert-True 'confirmatory inputs: two sessions split between blocks pass' ($checked.Problems.Count -eq 0) (@($checked.Problems) -join ' | ')
    Assert-True 'confirmatory inputs: every scheduled run is found once, in its session' (@($checked.Runs).Count -eq 12 -and @($checked.Runs | Where-Object { $block2 -contains $_.Name -and $_.Directory -eq $session2 }).Count -eq 6)
    Assert-True 'confirmatory inputs: the verified hashes are returned' ($checked.ThresholdsSha256 -eq $thresholdsSha -and $checked.ManifestSha256 -eq $freeze.Sha256 -and @($checked.Thresholds).Count -eq 12)
    $whole = New-Session 'single' $freeze $confirmSchedule ($block1 + $block2)
    Assert-True 'confirmatory inputs: one complete session passes' ((Test-Confirm @($whole)).Problems.Count -eq 0)
    $ok = Assert-CatalogConfirmatoryInputs -ResultsDirectories @($session1, $session2) -FrozenManifestPath $freeze.Path -FrozenManifestSha256 $freeze.Sha256.ToUpperInvariant() -ThresholdsPath $thresholdsFile -ThresholdsSha256 $thresholdsSha
    Assert-True 'confirmatory inputs: Assert returns the checked inputs, any letter case of the hash' ($ok.ManifestSha256 -eq $freeze.Sha256)
    $secondRuns = New-Item -ItemType Directory -Path (Join-Path $session2 'runs')
    Set-Content -LiteralPath (Join-Path $secondRuns.FullName "$($block2[0]).json") -Value '{"configError":"session two fixture"}' -Encoding UTF8
    $assembled = Join-Path $confirmRoot 'assembled'
    & (Join-Path $PSScriptRoot 'Summarize-CatalogRuns.ps1') -ConfirmatoryDirectories @($session1, $session2) -FrozenManifestPath $freeze.Path -FrozenManifestSha256 $freeze.Sha256 -ThresholdsPath $thresholdsFile -ThresholdsSha256 $thresholdsSha -OutputDirectory $assembled
    $assembledRuns = @(Import-Csv -LiteralPath (Join-Path $assembled 'runs.csv'))
    $assembledPairs = @(Import-Csv -LiteralPath (Join-Path $assembled 'triplets.csv'))
    $assembledSummary = Get-Content -LiteralPath (Join-Path $assembled 'summary.md') -Raw
    $assembledSign = Get-Content -LiteralPath (Join-Path $assembled 'sign-evidence.json') -Raw | ConvertFrom-Json
    Assert-True 'confirmatory summary: preserves all invalid runs and pairs across two sessions' (
        $assembledRuns.Count -eq 12 -and $assembledPairs.Count -eq 12 -and
        @($assembledRuns | Where-Object { $_.Valid -ne 'False' -or $_.InvalidReason -like '*not run*' }).Count -eq 0)
    Assert-True 'confirmatory summary: reads the run artifact from its own session' (
        @($assembledRuns | Where-Object { $_.Name -eq $block2[0] -and $_.InvalidReason -like '*session two fixture*' }).Count -eq 1)
    Assert-True 'confirmatory summary: records both hashes and stays descriptive' (
        $assembledSummary -like '*Confirmatory: descriptive, no conclusion*' -and
        $assembledSummary.Contains($freeze.Sha256) -and $assembledSummary.Contains($thresholdsSha))
    Assert-True 'confirmatory summary: insufficient valid pairs give no sign evidence against H0' (
        $assembledSign.Primary.Evidence[0].N -eq 0 -and $assembledSign.Primary.Evidence[0].PValue -eq 1 -and
        @($assembledSign.Primary.Evidence[0].Excluded).Count -eq 2 -and -not $assembledSign.Primary.Adjustments[0].Reject)
    $pairs = @(foreach ($triplet in ($ok.Schedule | Group-Object Cell, Triplet)) {
        foreach ($comparison in 'C-A', 'C-B', 'B-A') {
            [pscustomobject]@{
                Cell = $triplet.Group[0].Cell; Triplet = $triplet.Group[0].Triplet; Comparison = $comparison
                Valid = $true; LoadPrivateMBDiff = '-40'; RunCpuSecondsDiff = '-2'
            }
        }
    })
    $sign = Get-CatalogCheckedSignResults -CheckedInputs $ok -PairRows $pairs
    Assert-True 'sign analysis: keeps both verified hashes and the frozen triplet count' (
        $sign.ManifestSha256 -eq $freeze.Sha256 -and $sign.ThresholdsSha256 -eq $thresholdsSha -and
        $sign.Primary.Evidence[0].N -eq 2 -and $sign.NiRam.Adjustments.Count -eq 0 -and
        $sign.NiCpu.Evidence[0].Below -eq 2)
    foreach ($fixture in @(
        @{ Rows = @($pairs | Select-Object -SkipLast 1); Checked = $ok; Message = 'do not cover the full frozen schedule' }
        @{ Rows = $pairs + $pairs[0]; Checked = $ok; Message = 'Duplicate pair row' }
        @{ Rows = $pairs; Checked = (Test-Confirm @($session1)); Message = 'validation must pass' }
    )) {
        $errorText = ''
        try { Get-CatalogCheckedSignResults -CheckedInputs $fixture.Checked -PairRows $fixture.Rows | Out-Null }
        catch { $errorText = $_.Exception.Message }
        Assert-True "sign analysis refuses inputs: $($fixture.Message)" ($errorText -like "*$($fixture.Message)*") $errorText
    }

    # Thresholds SHA-256 (Import-CatalogThresholds inside the input check).
    $editedThresholds = Join-Path $confirmRoot 'thresholds-edited.csv'
    [System.IO.File]::WriteAllText($editedThresholds, ([System.IO.File]::ReadAllText($thresholdsFile)).Replace('15.25', '15.26'))
    Assert-ConfirmRefused 'thresholds edited after the freeze' (Test-Confirm @($session1, $session2) -Thresholds $editedThresholds) 'thresholds: thresholds.csv SHA-256'
    Assert-ConfirmRefused 'a wrong thresholds hash' (Test-Confirm @($session1, $session2) -ThresholdsHash ('0' * 64)) 'does not match the frozen'
    Assert-ConfirmRefused 'a malformed thresholds hash' (Test-Confirm @($session1, $session2) -ThresholdsHash 'abc') 'not a 64-digit'
    Assert-ConfirmRefused 'missing thresholds' (Test-Confirm @($session1, $session2) -Thresholds (Join-Path $confirmRoot 'none.csv')) 'thresholds.csv not found'
    Assert-ConfirmRefused 'a frozen manifest edited after the freeze' (Test-Confirm @($session1, $session2) -Freeze ([pscustomobject]@{ Path = $freeze.Path; Sha256 = ('0' * 64) })) 'frozen manifest SHA-256'
    Assert-ConfirmRefused 'a malformed frozen manifest hash' (Test-Confirm @($session1, $session2) -Freeze ([pscustomobject]@{ Path = $freeze.Path; Sha256 = 'abc' })) 'not a 64-digit hex value'

    # Mixed phases.
    $pilotDir = New-Session 'pilot-as-session' $freeze $confirmSchedule $block2 -Configuration @{ phase = 'Pilot' }
    Assert-ConfirmRefused 'a pilot directory among the sessions (mixed phases)' (Test-Confirm @($session1, $pilotDir)) "mixed phases: $pilotDir is phase 'Pilot'"
    $smokeDir = New-Session 'smoke-as-session' $freeze $confirmSchedule $block2 -Configuration @{ phase = 'Smoke' }
    Assert-ConfirmRefused 'a smoke directory among the sessions (mixed phases)' (Test-Confirm @($session1, $smokeDir)) "is phase 'Smoke'"
    $pilotConfiguration = New-ConfirmConfiguration; $pilotConfiguration.phase = 'Pilot'
    $pilotFreeze = New-Freeze 'pilot' $pilotConfiguration $confirmSchedule
    $pilotSessions = @((New-Session 'pilot-freeze-1' $pilotFreeze $confirmSchedule ($block1 + $block2) -Configuration @{ phase = 'Pilot' }))
    Assert-ConfirmRefused 'a pilot freeze given as the confirmatory one' (Test-Confirm $pilotSessions -Freeze $pilotFreeze) "the frozen manifest is phase 'Pilot'"
    $dryDir = New-Session 'dry-run-session' $freeze $confirmSchedule $block2 -Configuration @{ dryRun = $true }
    Assert-ConfirmRefused 'a dry run among the sessions' (Test-Confirm @($session1, $dryDir)) 'is a dry run'
    $stringDry = New-Session 'string-dry-run' $freeze $confirmSchedule $block2 -Configuration @{ dryRun = 'false' }
    Assert-ConfirmRefused 'a string instead of the dry-run marker' (Test-Confirm @($session1, $stringDry)) 'has no boolean dryRun marker'
    $brokenJson = New-Session 'broken-json' $freeze $confirmSchedule $block2
    Set-Content -LiteralPath (Join-Path $brokenJson 'configuration.json') -Value '{' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $brokenJson 'manifest.json') -Value '[{}]' -Encoding UTF8
    $brokenResult = Test-Confirm @($session1, $brokenJson)
    Assert-ConfirmRefused 'a malformed session configuration' $brokenResult 'configuration.json is not a readable JSON object'
    Assert-ConfirmRefused 'a manifest array in the same session' $brokenResult 'manifest.json is not a readable JSON object'
    $otherHead = New-ConfirmConfiguration; $otherHead.gitHead = ('b' * 40)
    $otherHeadFreeze = New-Freeze 'other-head' $otherHead $confirmSchedule
    $otherHeadDir = New-Session 'other-head-session' $freeze $confirmSchedule $block2 -ManifestPath $otherHeadFreeze.Path
    Assert-ConfirmRefused 'a session at another scenario revision' (Test-Confirm @($session1, $otherHeadDir)) 'differs from the frozen manifest: gitHead: frozen'
    $otherExe = New-ConfirmConfiguration; $otherExe.executables.C.sha256 = ('9' * 64)
    $otherExeDir = New-Session 'other-exe-session' $freeze $confirmSchedule $block2 -ManifestPath (New-Freeze 'other-exe' $otherExe $confirmSchedule).Path
    Assert-ConfirmRefused 'a session with another arm C executable' (Test-Confirm @($session1, $otherExeDir)) 'executables.C.sha256: frozen'
    $otherFrozenDir = New-Session 'other-frozen-sha-session' $freeze $confirmSchedule $block2 -Configuration @{ frozenManifestSha256 = ('1' * 64) }
    Assert-ConfirmRefused 'a session run against another frozen manifest' (Test-Confirm @($session1, $otherFrozenDir)) 'was run against manifest SHA-256'

    # Missing data.
    Assert-ConfirmRefused 'a block never run' (Test-Confirm @($session1)) "missing data: run $($block2[0]) was never run"
    $partial = New-Session 'partial-session' $freeze $confirmSchedule ($block2 | Select-Object -Skip 1)
    Assert-ConfirmRefused 'one scheduled run never run' (Test-Confirm @($session1, $partial)) "missing data: run $($block2[0]) was never run"
    foreach ($file in @('configuration.json', 'manifest.json', 'schedule.csv', 'runs.log')) {
        $without = New-Session "no-$file" $freeze $confirmSchedule $block2 -Skip $file
        Assert-ConfirmRefused "a session without $file" (Test-Confirm @($session1, $without)) "missing data: $without has no $file"
    }
    Assert-ConfirmRefused 'a session directory that does not exist' (Test-Confirm @($session1, (Join-Path $confirmRoot 'absent'))) 'not found'
    Assert-ConfirmRefused 'no session at all' (Test-Confirm @()) 'missing data: no results directory'
    Assert-ConfirmRefused 'a missing frozen manifest' (Test-Confirm @($session1, $session2) -Freeze ([pscustomobject]@{ Path = (Join-Path $confirmRoot 'none.json'); Sha256 = $freeze.Sha256 })) 'missing data: frozen manifest'

    # Cell composition.
    $short = @($confirmSchedule | Select-Object -SkipLast 1)
    $shortDir = New-Session 'short-schedule' $freeze $short $block2
    Assert-ConfirmRefused 'a session schedule.csv without one run' (Test-Confirm @($session1, $shortDir)) 'has a schedule.csv other than the frozen schedule'
    $shortFreeze = New-Freeze 'short' (New-ConfirmConfiguration) $short
    $shortSessions = @((New-Session 'short-freeze-session' $shortFreeze $short @($short | ForEach-Object { $_.Name })))
    Assert-ConfirmRefused 'a frozen schedule with an incomplete triplet' (Test-Confirm $shortSessions -Freeze $shortFreeze) 'cell composition: the frozen manifest has 11 runs, not 2 cells x 3 arms x 2 triplets = 12'
    $oneCell = New-ConfirmConfiguration; $oneCell.cells = @('N2D16')
    $oneCellSchedule = @(New-CatalogSchedule -Cells N2D16 -Arms A, B, C -Triplets 2 -Seed 3 -DataSeed 1)
    $oneCellFreeze = New-Freeze 'one-cell' $oneCell $oneCellSchedule
    $oneCellSessions = @((New-Session 'one-cell-session' $oneCellFreeze $oneCellSchedule @($oneCellSchedule | ForEach-Object { $_.Name })))
    Assert-ConfirmRefused 'thresholds for a cell the freeze does not have' (Test-Confirm $oneCellSessions -Freeze $oneCellFreeze) 'unexpected: N4D64/'
    $threeCells = New-ConfirmConfiguration; $threeCells.cells = @('N2D0', 'N2D16', 'N4D64')
    $threeSchedule = @(New-CatalogSchedule -Cells N2D0, N2D16, N4D64 -Arms A, B, C -Triplets 2 -Seed 3 -DataSeed 1)
    $threeFreeze = New-Freeze 'three-cells' $threeCells $threeSchedule
    $threeSessions = @((New-Session 'three-cells-session' $threeFreeze $threeSchedule @($threeSchedule | ForEach-Object { $_.Name })))
    Assert-ConfirmRefused 'a frozen cell without thresholds' (Test-Confirm $threeSessions -Freeze $threeFreeze) 'missing: N2D0/'
    $twoArms = New-ConfirmConfiguration; $twoArms.arms = @('A', 'B')
    $twoArmSchedule = @(New-CatalogSchedule -Cells $confirmCells -Arms A, B -Triplets 2 -Seed 3 -DataSeed 1)
    $twoArmFreeze = New-Freeze 'two-arms' $twoArms $twoArmSchedule
    $twoArmSessions = @((New-Session 'two-arms-session' $twoArmFreeze $twoArmSchedule @($twoArmSchedule | ForEach-Object { $_.Name })))
    Assert-ConfirmRefused 'two arms only' (Test-Confirm $twoArmSessions -Freeze $twoArmFreeze) "arms are 'A,B'"
    $badCell = New-ConfirmConfiguration; $badCell.cells = @('N2D16', 'N4D64', 'X9')
    Assert-ConfirmRefused 'a malformed cell name' (Test-Confirm @($session1, $session2) -Freeze (New-Freeze 'bad-cell' $badCell $confirmSchedule)) "'X9' is not a cell name"
    $doubleCell = New-ConfirmConfiguration; $doubleCell.cells = @('N2D16', 'N4D64', 'N4D64')
    Assert-ConfirmRefused 'a duplicated cell' (Test-Confirm @($session1, $session2) -Freeze (New-Freeze 'double-cell' $doubleCell $confirmSchedule)) 'duplicated cells N4D64'
    $moreTriplets = New-ConfirmConfiguration; $moreTriplets.triplets = 3
    Assert-ConfirmRefused 'a triplet count other than the schedule' (Test-Confirm @($session1, $session2) -Freeze (New-Freeze 'three-triplets' $moreTriplets $confirmSchedule)) 'cell composition: the frozen manifest has 12 runs, not 2 cells x 3 arms x 3 triplets = 18'

    # Runs counted twice or not scheduled; nested sessions.
    $again = New-Session 'again-session' $freeze $confirmSchedule ($block2 + $block1[0])
    Assert-ConfirmRefused 'a run in two sessions' (Test-Confirm @($session1, $again)) "run $($block1[0]) has 2 runs.log entries"
    $splitFirst = New-Session 'split-first' $freeze $confirmSchedule @($block1[0])
    $splitSecond = New-Session 'split-second' $freeze $confirmSchedule (@($block1 | Select-Object -Skip 1) + $block2)
    Assert-ConfirmRefused 'a complete run set split within a block' (Test-Confirm @($splitFirst, $splitSecond)) 'block 1 is split across results directories'
    $invalidLog = New-Session 'invalid-log' $freeze $confirmSchedule $block2
    Add-Content -LiteralPath (Join-Path $invalidLog 'runs.log') -Value '{"name":["a-run"]}', '{}', 'not JSON'
    $invalidLogResult = Test-Confirm @($session1, $invalidLog)
    Assert-ConfirmRefused 'a non-string run name' $invalidLogResult 'runs.log line 7 has no valid run name'
    Assert-ConfirmRefused 'a missing run name' $invalidLogResult 'runs.log line 8 has no valid run name'
    Assert-ConfirmRefused 'an unreadable run log entry' $invalidLogResult 'runs.log line 9 is not readable'
    $extra = New-Session 'extra-session' $freeze $confirmSchedule ($block2 + 'r999-N8D256-A')
    Assert-ConfirmRefused 'a run that is not scheduled' (Test-Confirm @($session1, $extra)) 'run r999-N8D256-A is in runs.log but not in the frozen schedule'
    Assert-ConfirmRefused 'the same session twice' (Test-Confirm @($session1, $session1, $session2)) 'given more than once'
    $nestedSession = New-Session 'session-1\nested' $freeze $confirmSchedule $block2
    Assert-ConfirmRefused 'a session inside another' (Test-Confirm @($session1, $nestedSession)) 'inside another results directory'
    $message = ''
    try { [void](Assert-CatalogConfirmatoryInputs -ResultsDirectories @($session1) -FrozenManifestPath $freeze.Path -FrozenManifestSha256 $freeze.Sha256 -ThresholdsPath $thresholdsFile -ThresholdsSha256 $thresholdsSha) } catch { $message = $_.Exception.Message }
    Assert-True 'confirmatory inputs: Assert stops with every problem named' ($message -like '*the confirmatory analysis stops:*was never run*') $message
}
finally { Remove-Item -LiteralPath $confirmRoot -Recurse -Force -ErrorAction SilentlyContinue }

# --- Whole-run CPU from the job (CatalogJobCpu.ps1, protocol §7 with job CPU).
# Fixture: app started at t0 in an empty job; phases idle-before t0+1, warm-up
# t0+5, load t0+10..t0+30, end t0+35; job rows every 0.25 s from t0 to t0+40 with
# 0.3 s user + 0.1 s kernel per second; the host (4242) and a WebView2 process
# (5000) live through the run; a short child (6000) lives 50 ms between two rows
# at t0+12.1 and is never seen by the monitor; every process has exited by t0+37.
function New-JobFixture {
    param([DateTimeOffset]$T0)
    $rows = New-Object System.Collections.Generic.List[object]
    for ($k = 0; $k -le 160; $k++) {
        $t = $k * 0.25
        $total = if ($t -ge 12.25) { 3 } else { 2 }
        $active = if ($t -ge 37) { 0 } elseif ($t -ge 36.5) { 1 } else { 2 }
        $rows.Add([pscustomobject][ordered]@{
                Utc = $T0.AddSeconds($t).UtcDateTime.ToString('o', $culture); ElapsedSeconds = $t.ToString('F6', $culture)
                UserTicks = [long](0.3 * $t * 1e7); KernelTicks = [long](0.1 * $t * 1e7); CpuSeconds = (0.4 * $t).ToString('F7', $culture)
                TotalProcesses = $total; ActiveProcesses = $active; LimitTerminatedProcesses = 0
            })
    }
    $message = { param($offset, $kind, $id) [pscustomobject][ordered]@{ Utc = $T0.AddSeconds($offset).UtcDateTime.ToString('o', $culture); UtcTicks = $T0.AddSeconds($offset).UtcTicks; Message = $kind; ProcessId = $id } }
    $messages = New-Object System.Collections.Generic.List[object]
    $messages.Add((& $message 0.001 6 4242)); $messages.Add((& $message 0.5 6 5000)); $messages.Add((& $message 12.1 6 6000)); $messages.Add((& $message 12.15 7 6000))
    $messages.Add((& $message 36.5 7 5000)); $messages.Add((& $message 37 7 4242)); $messages.Add((& $message 37 4 0))
    $phases = [pscustomobject][ordered]@{
        idleBeforeStartedAt = $T0.AddSeconds(1).ToString('o'); warmupStartedAt = $T0.AddSeconds(5).ToString('o'); loadStartedAt = $T0.AddSeconds(10).ToString('o')
        loadEndedAt = $T0.AddSeconds(30).ToString('o'); endedAt = $T0.AddSeconds(35).ToString('o')
    }
    [pscustomobject]@{ Rows = $rows; Messages = $messages; Phases = $phases; Keys = @("4242@$($T0.UtcTicks)", "5000@$($T0.AddSeconds(0.49).UtcTicks)") }
}
$jobT0 = [DateTimeOffset]::Parse('2026-11-06T19:00:00Z', $culture)
$f = New-JobFixture $jobT0
$job = Get-CatalogJobCpu -Rows $f.Rows -Messages $f.Messages -Phases $f.Phases -MonitorKeys $f.Keys
Assert-True 'job: a complete run has no problems' ($job.Problems.Count -eq 0) (@($job.Problems) -join '; ')
Assert-Near 'job: whole-run CPU at the end of idle-after; CPU after the end is not counted' $job.RunCpuSeconds 14.0 1e-6
Assert-Near 'job: startup CPU at the warm-up start' $job.StartupCpuSeconds 2.0 1e-6
Assert-Near 'job: load CPU between the load boundaries' $job.LoadCpuSeconds 8.0 1e-6
Assert-Near 'job: a short process between two samples is in the job count' $job.JobProcesses 3
Assert-Near 'job: both monitor processes are members' $job.MonitorProcessesInJob 2
Assert-Near 'job: the short process is the one the monitor never saw' $job.JobProcessesNeverSeenByMonitor 1
Assert-Near 'job: the end boundary falls on a row' $job.EndGapSeconds 0 1e-9

# Artificial CPU after endedAt: 100 s of CPU from 50 ms after the end; the whole-run value stays 14.0.
$f = New-JobFixture $jobT0
foreach ($r in $f.Rows) { if ([DateTimeOffset]::Parse($r.Utc, $culture) -gt $jobT0.AddSeconds(35)) { $r.UserTicks = [long]$r.UserTicks + 1000000000 } }
$job = Get-CatalogJobCpu -Rows $f.Rows -Messages $f.Messages -Phases $f.Phases -MonitorKeys $f.Keys
Assert-True 'job: artificial CPU after endedAt does not enter the whole-run value' ($job.Problems.Count -eq 0 -and [Math]::Abs($job.RunCpuSeconds - 14.0) -lt 1e-6) ("{0}; {1}" -f $job.RunCpuSeconds, (@($job.Problems) -join '; '))

$f = New-JobFixture $jobT0
$f.Rows = @($f.Rows | Where-Object { $t = ([DateTimeOffset]::Parse($_.Utc, $culture) - $jobT0).TotalSeconds; $t -le 34 -or $t -ge 36 })
$job = Get-CatalogJobCpu -Rows $f.Rows -Messages $f.Messages -Phases $f.Phases -MonitorKeys $f.Keys
Assert-True 'job: a row more than 0.5 s before the end is refused' ((@($job.Problems) -join ';') -like '*end of the interval: last job row 1.000 s before*' -and $null -eq $job.RunCpuSeconds) (@($job.Problems) -join '; ')
Assert-True 'job: a 2 s gap between rows is refused' ((@($job.Problems) -join ';') -like '*job rows 2.000 s apart*') (@($job.Problems) -join '; ')

$f = New-JobFixture $jobT0
$f.Rows[50].UserTicks = $f.Rows[49].UserTicks - 1
$job = Get-CatalogJobCpu -Rows $f.Rows -Messages $f.Messages -Phases $f.Phases -MonitorKeys $f.Keys
Assert-True 'job: a counter that decreases is refused' ((@($job.Problems) -join ';') -like '*decrease at row 50*') (@($job.Problems) -join '; ')

$f = New-JobFixture $jobT0
for ($k = 100; $k -lt $f.Rows.Count; $k++) { $f.Rows[$k].ElapsedSeconds = ([double]::Parse($f.Rows[$k].ElapsedSeconds, $culture) + 0.2).ToString('F6', $culture) }
$job = Get-CatalogJobCpu -Rows $f.Rows -Messages $f.Messages -Phases $f.Phases -MonitorKeys $f.Keys
Assert-True 'job: a wall clock that drifts 0.2 s from the stopwatch is refused' ((@($job.Problems) -join ';') -like '*wall clock drifted 0.200 s*') (@($job.Problems) -join '; ')

$f = New-JobFixture $jobT0
$f.Messages = @($f.Messages | Where-Object { -not ($_.Message -eq 6 -and $_.ProcessId -eq 6000) })
$job = Get-CatalogJobCpu -Rows $f.Rows -Messages $f.Messages -Phases $f.Phases -MonitorKeys $f.Keys
Assert-True 'job: a lost membership message makes membership unverified' ((@($job.Problems) -join ';') -like '*job messages incomplete (new 2 of 3*membership not verified*') (@($job.Problems) -join '; ')

$f = New-JobFixture $jobT0
$foreign = "7000@$($jobT0.AddSeconds(3).UtcTicks)"
$job = Get-CatalogJobCpu -Rows $f.Rows -Messages $f.Messages -Phases $f.Phases -MonitorKeys (@($f.Keys) + $foreign)
Assert-True 'job: a monitor-tree process outside the job is refused' ((@($job.Problems) -join ';') -like "*without a job membership message: $foreign*") (@($job.Problems) -join '; ')

$f = New-JobFixture $jobT0
$reused = "5000@$($jobT0.AddSeconds(20).UtcTicks)"
$job = Get-CatalogJobCpu -Rows $f.Rows -Messages $f.Messages -Phases $f.Phases -MonitorKeys @($f.Keys[0], $reused)
Assert-True 'job: a reused PID is not matched to the earlier process''s message' ((@($job.Problems) -join ';') -like "*without a job membership message: $reused*") (@($job.Problems) -join '; ')

$f = New-JobFixture $jobT0
foreach ($r in $f.Rows) { if ([int]$r.ActiveProcesses -eq 0) { $r.ActiveProcesses = 1 } }
$f.Messages = @($f.Messages | Where-Object { $_.Message -ne 4 -and -not ($_.Message -eq 7 -and $_.ProcessId -eq 4242) })
$job = Get-CatalogJobCpu -Rows $f.Rows -Messages $f.Messages -Phases $f.Phases -MonitorKeys $f.Keys
Assert-True 'job: a process still running at the last row is refused' ((@($job.Problems) -join ';') -like '*1 job process(es) still running*') (@($job.Problems) -join '; ')
Assert-True 'job: with one process running the exit messages still match' ((@($job.Problems) -join ';') -notlike '*messages incomplete*') (@($job.Problems) -join '; ')

$f = New-JobFixture $jobT0
$f.Rows = @($f.Rows | Where-Object { ([DateTimeOffset]::Parse($_.Utc, $culture) - $jobT0).TotalSeconds -ge 1.5 })
$job = Get-CatalogJobCpu -Rows $f.Rows -Messages $f.Messages -Phases $f.Phases -MonitorKeys $f.Keys
Assert-True 'job: sampling that starts after the idle-before phase is refused' ((@($job.Problems) -join ';') -like '*first job row after the idle-before phase*') (@($job.Problems) -join '; ')

$f = New-JobFixture $jobT0
$f.Rows[150].LimitTerminatedProcesses = 1
$job = Get-CatalogJobCpu -Rows $f.Rows -Messages $f.Messages -Phases $f.Phases -MonitorKeys $f.Keys
Assert-True 'job: a process terminated by a job limit is refused' ((@($job.Problems) -join ';') -like '*terminated by a job limit*') (@($job.Problems) -join '; ')

# Summarizer with cpuSource = job in configuration.json. Six runs:
#   N2D0 A  : job complete; the monitor lost a child's CPU (ExitedUnread) -> valid, CPU from the job
#   N2D0 B  : job complete; private memory missing in a load row          -> invalid for RAM only
#   N2D16 A : a monitor-tree process has no job membership message         -> invalid (job CPU)
#   N2D16 B : valid RAM and monitor CPU, but no job CSV or messages        -> invalid, never the monitor
#   N2D64 A : job CSV present, messages file missing                       -> invalid
#   N2D64 B : job complete                                                 -> valid
$root = Join-Path ([System.IO.Path]::GetTempPath()) ("catalog-test-job-{0}" -f [guid]::NewGuid().ToString('N'))
try {
    $results = Join-Path $root 'results'
    $runsDir = Join-Path $results 'runs'
    New-Item -ItemType Directory -Force -Path $runsDir | Out-Null
    $schedule = @(New-CatalogSchedule -Cells N2D0, N2D16, N2D64 -Arms A, B -Triplets 1 -Seed 0)
    $schedule | Export-Csv -LiteralPath (Join-Path $results 'schedule.csv') -NoTypeInformation -Encoding UTF8
    [ordered]@{
        scenario = 'M'; phase = 'Smoke'; os = 'Synthetic OS'; machine = 'TEST'; gitHead = 'abc'; gitDirty = $false
        arms = @('A', 'B'); cells = @('N2D0', 'N2D16', 'N2D64'); triplets = 1; scheduleSeed = 0; sampleIntervalSeconds = 1; cpuSource = 'job'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $results 'configuration.json') -Encoding UTF8
    $log = New-Object System.Collections.Generic.List[string]
    $offset = 0
    foreach ($run in $schedule) {
        $t0 = $jobT0.AddMinutes($offset); $offset += 10
        $case = '{0}{1}' -f $run.Cell, $run.Arm
        $f = New-JobFixture $t0
        [ordered]@{
            schemaVersion = 1; scenario = 'M'; passed = $true; problems = @()
            config = [ordered]@{ arm = $run.Arm; windows = [int]$run.Windows; dataMib = [int]$run.DataMib; records = 1000; rustDataBytes = [int]$run.DataMib * 1MB }
            phases = $f.Phases
            totals = [ordered]@{ scheduledSteps = 80; completedSteps = 80; failures = 0; mismatches = 0; overruns = 0; maxP95LatencyMs = 3.5; maxTimeToFirstPageMs = 120; loadJsHeapAvgBytes = 8MB }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runsDir "$($run.Name).json") -Encoding UTF8
        $monitor = New-Object System.Collections.Generic.List[string]
        $diagnostics = New-Object System.Collections.Generic.List[string]
        $monitor.Add('Timestamp,Sample,RootPid,ProcessCount,ProcessIds,ProcessKeys,WorkingSetMB,PrivateBytesMB,CpuDeltaSeconds,IntervalSeconds,PrivateMissingCount,CpuUnreadableCount,RejectedPidReuseCount,UnverifiedProcessCount,CpuExitedUnreadIds,CpuAccessDeniedIds,CpuIdentityChangedIds,CpuLeftTreeIds,CpuReadErrorIds')
        $diagnostics.Add('Timestamp,Pid,ProcessKey,Name,InTree,CimPrivatePageCount,ProcTotalProcessorSeconds')
        $keys = @($f.Keys)
        if ($case -eq 'N2D16A') { $keys += "7000@$($t0.AddSeconds(3).UtcTicks)" }
        for ($s = 1; $s -le 36; $s++) {
            $time = $t0.AddSeconds($s).ToString('o')
            $members = New-Object System.Collections.Generic.List[object]
            $members.Add(@(4242, $keys[0], 'catalog-bench', 100.0, (0.3 * $s)))
            $members.Add(@(5000, $keys[1], 'msedgewebview2', 200.0, (0.1 * $s)))
            if ($case -eq 'N2D16A' -and $s -ge 3 -and $s -le 5) { $members.Add(@(7000, $keys[2], 'msedgewebview2', 10.0, 0.01)) }
            $cpuMissing = if ($case -eq 'N2D0A' -and $s -eq 12) { @(1, '6000,,,,') } else { @(0, ',,,,') }
            $privateMissing = if ($case -eq 'N2D0B' -and $s -eq 20) { 1 } else { 0 }
            $private = ($members | ForEach-Object { $_[3] } | Measure-Object -Sum).Sum
            $monitor.Add(('{0},{1},4242,{2},{3},{4},{5},{6},0.4,{7},{8},{9},0,0,{10}' -f $time, $s, $members.Count, (($members | ForEach-Object { $_[0] }) -join ';'), (($members | ForEach-Object { $_[1] }) -join ';'), ($private + 50).ToString($culture), $private.ToString($culture), $(if ($s -eq 1) { '' } else { '1' }), $privateMissing, $cpuMissing[0], $cpuMissing[1]))
            foreach ($m in $members) { $diagnostics.Add(('{0},{1},{2},{3},True,{4},{5}' -f $time, $m[0], $m[1], $m[2], ($m[3] * 1MB).ToString($culture), ([double]$m[4]).ToString($culture))) }
        }
        $monitor | Set-Content -LiteralPath (Join-Path $runsDir "$($run.Name).monitor.csv") -Encoding UTF8
        $diagnostics | Set-Content -LiteralPath (Join-Path $runsDir "$($run.Name).monitor.diagnostics.csv") -Encoding UTF8
        if ($case -ne 'N2D16B') { $f.Rows | Export-Csv -LiteralPath (Join-Path $runsDir "$($run.Name).job.csv") -NoTypeInformation -Encoding UTF8 }
        if ($case -ne 'N2D16B' -and $case -ne 'N2D64A') { $f.Messages | Export-Csv -LiteralPath (Join-Path $runsDir "$($run.Name).job.messages.csv") -NoTypeInformation -Encoding UTF8 }
        $log.Add((@{ name = $run.Name; exitCode = 0; timedOut = $false; monitorExit = 0; monitorCpuSeconds = 1.0; jobTerminated = $false; jobLeftoverProcesses = 0; jobError = $null } | ConvertTo-Json -Compress))
    }
    $log | Set-Content -LiteralPath (Join-Path $results 'runs.log') -Encoding UTF8
    $analysis = Join-Path $root 'analysis'
    & (Join-Path $PSScriptRoot 'Summarize-CatalogRuns.ps1') -ResultsDirectory $results -OutputDirectory $analysis | Out-Null
    $runs = @(Import-Csv -LiteralPath (Join-Path $analysis 'runs.csv'))
    $byCase = @{}
    foreach ($r in $runs) { $byCase['{0}{1}' -f $r.Cell, $r.Arm] = $r }
    $all = ($runs | ForEach-Object { "$($_.Cell)$($_.Arm)=$($_.InvalidReason)" }) -join '; '
    Assert-True 'job summary: a CPU value the monitor lost does not invalidate a run with a complete job' ($byCase['N2D0A'].Valid -eq 'True' -and $byCase['N2D0A'].CpuSource -eq 'job') $all
    Assert-Near 'job summary: whole-run CPU is the job value' $byCase['N2D0A'].RunCpuSeconds 14.0 1e-6
    Assert-Near 'job summary: load CPU is the job value' $byCase['N2D0A'].LoadCpuSeconds 8.0 1e-6
    Assert-True 'job summary: the monitor''s reason stays as a note' ($byCase['N2D0A'].MonitorCpuNotes -like '*ExitedUnread 6000*') $byCase['N2D0A'].MonitorCpuNotes
    Assert-Near 'job summary: the monitor''s own CPU stays as a diagnostic' $byCase['N2D0A'].MonitorRunCpuSeconds 14.0 1e-6
    Assert-Near 'job summary: processes the monitor never saw' $byCase['N2D0A'].JobProcessesNeverSeenByMonitor 1
    Assert-True 'job summary: RAM checks still apply with a complete job' ($byCase['N2D0B'].Valid -eq 'False' -and $byCase['N2D0B'].InvalidReason -like '*missing or non-finite private memory*' -and $byCase['N2D0B'].InvalidReason -notlike '*whole-run CPU*') $byCase['N2D0B'].InvalidReason
    Assert-True 'job summary: a monitor-tree process outside the job invalidates the run' ($byCase['N2D16A'].Valid -eq 'False' -and $byCase['N2D16A'].InvalidReason -like '*whole-run CPU (job): monitor-tree process(es) without a job membership message: 7000@*' -and $byCase['N2D16A'].RunCpuSeconds -eq '') $byCase['N2D16A'].InvalidReason
    Assert-True 'job summary: cpuSource=job with no job CSV is invalid even with valid RAM and monitor CPU' ($byCase['N2D16B'].Valid -eq 'False' -and $byCase['N2D16B'].CpuSource -eq 'job' -and $byCase['N2D16B'].InvalidReason -eq ("whole-run CPU (job): missing job artifact(s): {0}.job.csv, {0}.job.messages.csv" -f $byCase['N2D16B'].Name) -and $byCase['N2D16B'].RunCpuSeconds -eq '') "$($byCase['N2D16B'].Name): $($byCase['N2D16B'].InvalidReason)"
    Assert-Near 'job summary: the monitor CPU of that run is still shown as a diagnostic' $byCase['N2D16B'].MonitorRunCpuSeconds 14.0 1e-6
    Assert-True 'job summary: a missing job messages file is invalid' ($byCase['N2D64A'].Valid -eq 'False' -and $byCase['N2D64A'].InvalidReason -like '*missing job artifact(s): *.job.messages.csv') $byCase['N2D64A'].InvalidReason
    Assert-True 'job summary: a complete run is valid' ($byCase['N2D64B'].Valid -eq 'True') $byCase['N2D64B'].InvalidReason
    $config = Get-Content -LiteralPath (Join-Path $results 'configuration.json') -Raw | ConvertFrom-Json
    $config | Add-Member -NotePropertyName cpuSource -NotePropertyValue 'other' -Force
    $config | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $results 'configuration.json') -Encoding UTF8
    $threw = $false
    try { & (Join-Path $PSScriptRoot 'Summarize-CatalogRuns.ps1') -ResultsDirectory $results -OutputDirectory (Join-Path $root 'analysis-other') | Out-Null } catch { $threw = $_.Exception.Message -like "*unknown cpuSource 'other'*" }
    Assert-True 'job summary: an unknown cpuSource stops the summarizer' $threw
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "$($failures.Count) failure(s):"
    $failures | ForEach-Object { Write-Host "FAIL $_" }
    exit 1
}
Write-Host 'All catalog script tests passed.'
