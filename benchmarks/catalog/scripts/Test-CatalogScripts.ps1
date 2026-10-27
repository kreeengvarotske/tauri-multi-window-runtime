<#
.SYNOPSIS
Tests CatalogSchedule.ps1 (balance of the pilot order),
CatalogThresholds.ps1 (threshold forms, pilot reference, sign counts at the
threshold, cut-offs) and Summarize-CatalogRuns.ps1 (validity, triplet differences, retained size) on
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

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "$($failures.Count) failure(s):"
    $failures | ForEach-Object { Write-Host "FAIL $_" }
    exit 1
}
Write-Host 'All catalog script tests passed.'
