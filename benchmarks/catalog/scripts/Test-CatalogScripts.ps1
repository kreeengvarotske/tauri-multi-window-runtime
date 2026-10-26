<#
.SYNOPSIS
Tests CatalogSchedule.ps1 (balance of the pilot order) and
Summarize-CatalogRuns.ps1 (validity, triplet differences, retained size) on
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

# --- Schedule: the pilot shape (protocol §6, §8a).
$cells = @('N2D0', 'N2D16', 'N2D64', 'N4D64')
foreach ($seed in 0, 1, 7, 23) {
    $schedule = @(New-CatalogSchedule -Cells $cells -Arms A, B, C -Triplets 5 -Seed $seed)
    Assert-True "seed ${seed}: 60 runs" ($schedule.Count -eq 60) "got $($schedule.Count)"
    Assert-True "seed ${seed}: Seq is 1..60" ((@($schedule | ForEach-Object { $_.Seq }) -join ',') -eq ((1..60) -join ','))
    $units = @($schedule | Where-Object { $_.Position -eq 1 })
    $permutationCounts = @($units | Group-Object Permutation | ForEach-Object { $_.Count })
    Assert-True "seed ${seed}: all 6 permutations used" (@($units | Group-Object Permutation).Count -eq 6)
    Assert-True "seed ${seed}: every permutation 3-4 times" (@($permutationCounts | Where-Object { $_ -lt 3 -or $_ -gt 4 }).Count -eq 0) ($permutationCounts -join ',')
    $positionCounts = @($schedule | Group-Object Arm, Position | ForEach-Object { $_.Count })
    Assert-True "seed ${seed}: every arm in every position 6-7 times" ($positionCounts.Count -eq 9 -and @($positionCounts | Where-Object { $_ -lt 6 -or $_ -gt 7 }).Count -eq 0) ($positionCounts -join ',')
    $firstPermutations = @($cells | ForEach-Object { $cell = $_; @($units | Where-Object { $_.Cell -eq $cell -and $_.Triplet -eq 1 })[0].Permutation })
    Assert-True "seed ${seed}: each cell starts at a different permutation" (@($firstPermutations | Select-Object -Unique).Count -eq 4) ($firstPermutations -join ',')
    $blocksOk = $true
    for ($block = 1; $block -le 5; $block++) {
        $blockRows = @($schedule | Where-Object { $_.Block -eq $block })
        $blockCells = @($blockRows | Where-Object { $_.Position -eq 1 } | ForEach-Object { $_.Cell })
        if ($blockRows.Count -ne 12 -or @($blockCells | Select-Object -Unique).Count -ne 4) { $blocksOk = $false }
        foreach ($group in ($blockRows | Group-Object Cell)) {
            $arms = @($group.Group | Sort-Object Position | ForEach-Object { $_.Arm }) -join ''
            $seqs = @($group.Group | ForEach-Object { $_.Seq })
            if ((@($arms.ToCharArray() | Sort-Object) -join '') -ne 'ABC' -or (($seqs | Measure-Object -Maximum).Maximum - ($seqs | Measure-Object -Minimum).Minimum) -ne 2) { $blocksOk = $false }
        }
    }
    Assert-True "seed ${seed}: blocks hold one adjacent triplet of each cell" $blocksOk
    $firstCells = @(1..5 | ForEach-Object { $b = $_; @($schedule | Where-Object { $_.Block -eq $b })[0].Cell })
    Assert-True "seed ${seed}: cell order rotates per block" (@($firstCells | Select-Object -Unique).Count -eq 4) ($firstCells -join ',')
}
$again = (@(New-CatalogSchedule -Cells $cells -Arms A, B, C -Triplets 5 -Seed 7) | ConvertTo-Csv -NoTypeInformation) -join "`n"
$once = (@(New-CatalogSchedule -Cells $cells -Arms A, B, C -Triplets 5 -Seed 7) | ConvertTo-Csv -NoTypeInformation) -join "`n"
Assert-True 'schedule is reproducible from its seed' ($again -eq $once)
$pairs = @(New-CatalogSchedule -Cells N2D0, N4D16 -Arms A, B -Triplets 3 -Seed 0)
Assert-True 'two arms: 12 runs' ($pairs.Count -eq 12)
$pairOrders = @($pairs | Where-Object { $_.Position -eq 1 } | ForEach-Object { $_.Permutation }) -join ','
Assert-True 'two arms: orders alternate' ($pairOrders -eq 'AB,BA,AB,BA,AB,BA') $pairOrders
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
        $diagnostics.Add('Timestamp,Pid,Name,InTree,CimPrivatePageCount')
        # The first A run in N2D0 has a 7 s monitor gap during load.
        $gap = $run.Cell -eq 'N2D0' -and $run.Triplet -eq 1 -and $run.Arm -eq 'A'
        for ($s = 0; $s -le 36; $s++) {
            if ($gap -and $s -ge 15 -and $s -lt 22) { continue }
            $time = $t0.AddSeconds($s).ToString('o')
            $interval = if ($s -eq 0) { '' } elseif ($gap -and $s -eq 22) { '7' } else { '1' }
            $monitor.Add(('{0},{1},4242,5,{2},{3},0.5,{4},0,0' -f $time, $s, ($hostMb + $webMb + 50).ToString($culture), ($hostMb + $webMb).ToString($culture), $interval))
            $diagnostics.Add(('{0},4242,catalog-bench,True,{1}' -f $time, ($hostMb * 1MB).ToString($culture)))
            $diagnostics.Add(('{0},5000,msedgewebview2,True,{1}' -f $time, ($webMb * 1MB).ToString($culture)))
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
    Assert-True 'summary: 6 valid runs' (@($runs | Where-Object { $_.Valid -eq 'True' }).Count -eq 6) (($runs | ForEach-Object { "$($_.Name)=$($_.InvalidReason)" }) -join '; ')
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
    $diff = @($triplets | Where-Object { $_.Cell -eq 'N2D16' -and $_.Triplet -eq '1' -and $_.Comparison -eq 'B-A' })[0]
    Assert-Near 'triplet: B - A Σ Private' $diff.LoadPrivateMBDiff (-60)
    Assert-Near 'triplet: B - A host' $diff.ExePrivateMBDiff 40
    Assert-Near 'triplet: B - A WebView2' $diff.WebViewPrivateMBDiff (-100)
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

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "$($failures.Count) failure(s):"
    $failures | ForEach-Object { Write-Host "FAIL $_" }
    exit 1
}
Write-Host 'All catalog script tests passed.'
