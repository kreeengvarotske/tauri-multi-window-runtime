# Input checks of the confirmatory analysis of scenario M (protocol #33 §10a,
# confirmatory freeze; #45 review 6693217194). Before any confirmatory number
# is computed, the analysis checks everything it reads and stops on any
# problem, naming all of them:
#
# - the frozen confirmatory manifest: its SHA-256, phase Confirmatory;
# - thresholds.csv through Import-CatalogThresholds (frozen SHA-256, one row
#   per cell, kind and outcome of the frozen cells);
# - every results directory (one per session; a run longer than about 12 h
#   is split between blocks, §8b): configuration.json, manifest.json,
#   schedule.csv and runs.log present; phase Confirmatory and not a dry run
#   (no mixed phases); the frozen manifest SHA-256 recorded; its manifest
#   equal to the frozen one field by field (no mixed revisions, executables,
#   seeds or phase lengths); its schedule.csv equal to the frozen schedule
#   content hash; no directory inside another;
# - the cell composition: cells, arms A, B and C, and triplets of the frozen
#   manifest; every cell and triplet complete with one run per arm
#   (Test-CatalogSchedule); runs = cells x arms x triplets;
# - completeness: every scheduled run has a runs.log entry in exactly one
#   session, no session has an unscheduled run, and blocks are not split.
#
# A run that was started but is invalid by §7 (no report, a failed monitor,
# missing job artifacts) is not missing data here: it stays in the analysis
# as an invalid run with its reason, as the protocol requires. Missing data
# is a frozen file, a session file, or a scheduled run that was never run.
#
# Dot-sourced after CatalogSchedule.ps1, CatalogThresholds.ps1 and
# CatalogManifest.ps1. Pure functions, no output files.

function Get-CatalogJsonProperty {
    param([AllowNull()][object]$Object, [string]$Name)
    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { return $null }
    $Object.PSObject.Properties[$Name].Value
}

function Read-CatalogConfirmatoryJson {
    param([string]$Path, [System.Collections.Generic.List[string]]$Problems)
    try {
        $json = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ($json -notmatch '^\s*\{') { throw 'Expected a JSON object.' }
        $value = ConvertFrom-Json -InputObject $json -ErrorAction Stop
        if ($value -isnot [pscustomobject]) { throw 'Expected a JSON object.' }
        $value
    }
    catch { $Problems.Add("$Path is not a readable JSON object: $($_.Exception.Message)") }
}

function Test-CatalogConfirmatoryInputs {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ResultsDirectories,
        [Parameter(Mandatory = $true)][string]$FrozenManifestPath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$FrozenManifestSha256,
        [Parameter(Mandatory = $true)][string]$ThresholdsPath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ThresholdsSha256
    )
    $problems = New-Object System.Collections.Generic.List[string]
    $result = [ordered]@{ Problems = $problems; ManifestSha256 = $null; ThresholdsSha256 = $null; Thresholds = $null; Schedule = $null; Runs = @() }

    # The frozen manifest.
    $frozen = $null
    if ($FrozenManifestSha256 -notmatch '^[0-9a-fA-F]{64}$') { $problems.Add("the frozen manifest SHA-256 is not a 64-digit hex value ('$FrozenManifestSha256')") }
    elseif (-not (Test-Path -LiteralPath $FrozenManifestPath -PathType Leaf)) { $problems.Add("missing data: frozen manifest '$FrozenManifestPath' not found") }
    else {
        $actual = (Get-FileHash -LiteralPath $FrozenManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $FrozenManifestSha256.ToLowerInvariant()) { $problems.Add("frozen manifest SHA-256 $actual does not match $($FrozenManifestSha256.ToLowerInvariant())") }
        else {
            $result.ManifestSha256 = $actual
            $frozen = Read-CatalogConfirmatoryJson -Path $FrozenManifestPath -Problems $problems
        }
    }
    $cells = @(); $arms = @(); $triplets = 0
    if ($null -ne $frozen) {
        $phase = [string](Get-CatalogJsonProperty $frozen 'phase')
        if ($phase -ne 'Confirmatory') { $problems.Add("mixed phases: the frozen manifest is phase '$phase', not Confirmatory") }
        $cells = @(Get-CatalogJsonProperty $frozen 'cells' | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        $arms = @(Get-CatalogJsonProperty $frozen 'arms' | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        $triplets = [int](Get-CatalogJsonProperty $frozen 'triplets')
        # Cell composition fixed by the freeze.
        if ($cells.Count -eq 0) { $problems.Add('cell composition: the frozen manifest has no cells') }
        $duplicateCells = @($cells | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
        if ($duplicateCells.Count -gt 0) { $problems.Add("cell composition: duplicated cells $($duplicateCells -join ', ')") }
        foreach ($cell in $cells) {
            try { ConvertFrom-CellName $cell | Out-Null } catch { $problems.Add("cell composition: '$cell' is not a cell name") }
        }
        if ((@($arms | Sort-Object) -join ',') -ne 'A,B,C') { $problems.Add("cell composition: arms are '$($arms -join ',')', the confirmatory families need A, B and C") }
        if ($triplets -lt 1) { $problems.Add("cell composition: triplets '$(Get-CatalogJsonProperty $frozen 'triplets')' per cell") }
        $expectedRuns = $cells.Count * $arms.Count * $triplets
        if ([int](Get-CatalogJsonProperty $frozen 'runs') -ne $expectedRuns) { $problems.Add("cell composition: the frozen manifest has $(Get-CatalogJsonProperty $frozen 'runs') runs, not $($cells.Count) cells x $($arms.Count) arms x $triplets triplets = $expectedRuns") }

        # Thresholds of exactly these cells, at the frozen SHA-256.
        try {
            $thresholds = Import-CatalogThresholds -Path $ThresholdsPath -ExpectedSha256 $ThresholdsSha256 -Cells $cells
            $result.Thresholds = $thresholds.Rows
            $result.ThresholdsSha256 = $thresholds.Sha256
        }
        catch { $problems.Add("thresholds: $($_.Exception.Message)") }
    }

    # The sessions.
    if ($ResultsDirectories.Count -eq 0) { $problems.Add('missing data: no results directory') }
    $full = @($ResultsDirectories | ForEach-Object { [System.IO.Path]::GetFullPath($_).TrimEnd('\', '/') })
    $duplicated = @($full | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($duplicated.Count -gt 0) { $problems.Add("results directory given more than once: $($duplicated -join ', ')") }
    foreach ($a in $full) {
        foreach ($b in $full) {
            if ($a -ne $b -and ($b.StartsWith($a + '\') -or $b.StartsWith($a + '/'))) { $problems.Add("$b is inside another results directory ($a)") }
        }
    }
    $entries = @{}
    $schedule = $null
    foreach ($directory in @($full | Select-Object -Unique)) {
        $missing = @('configuration.json', 'manifest.json', 'schedule.csv', 'runs.log' | Where-Object { -not (Test-Path -LiteralPath (Join-Path $directory $_) -PathType Leaf) })
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { $problems.Add("missing data: results directory $directory not found"); continue }
        if ($missing.Count -gt 0) { $problems.Add("missing data: $directory has no $($missing -join ', ')") }
        if ($missing -notcontains 'configuration.json') {
            $configuration = Read-CatalogConfirmatoryJson -Path (Join-Path $directory 'configuration.json') -Problems $problems
            if ($null -ne $configuration) {
                $phase = [string](Get-CatalogJsonProperty $configuration 'phase')
                if ($phase -ne 'Confirmatory') { $problems.Add("mixed phases: $directory is phase '$phase', not Confirmatory") }
                $dryRun = $null
                if ($configuration.PSObject.Properties['dryRun']) { $dryRun = $configuration.PSObject.Properties['dryRun'].Value }
                if ($dryRun -isnot [bool]) { $problems.Add("$directory has no boolean dryRun marker") }
                elseif ($dryRun) { $problems.Add("$directory is a dry run") }
                $recorded = [string](Get-CatalogJsonProperty $configuration 'frozenManifestSha256')
                if ($null -ne $result.ManifestSha256 -and $recorded.ToLowerInvariant() -ne $result.ManifestSha256) { $problems.Add("$directory was run against manifest SHA-256 '$recorded', not the frozen $($result.ManifestSha256)") }
            }
        }
        if ($missing -notcontains 'manifest.json' -and $null -ne $frozen) {
            $own = Read-CatalogConfirmatoryJson -Path (Join-Path $directory 'manifest.json') -Problems $problems
            if ($null -ne $own) {
                $differences = @(Compare-CatalogManifest -Frozen $frozen -Current $own)
                if ($differences.Count -gt 0) { $problems.Add("$directory differs from the frozen manifest: $($differences -join '; ')") }
            }
        }
        if ($missing -notcontains 'schedule.csv') {
            $own = @(Import-Csv -LiteralPath (Join-Path $directory 'schedule.csv') | Sort-Object { [int]$_.Seq })
            if ($null -ne $frozen -and (Get-CatalogScheduleSha256 -Schedule $own) -ne [string](Get-CatalogJsonProperty $frozen 'scheduleContentSha256')) { $problems.Add("$directory has a schedule.csv other than the frozen schedule") }
            elseif ($null -eq $schedule) { $schedule = $own }
        }
        if ($missing -notcontains 'runs.log') {
            $lineNumber = 0
            foreach ($line in Get-Content -LiteralPath (Join-Path $directory 'runs.log')) {
                $lineNumber++
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try { $event = ConvertFrom-Json -InputObject $line -ErrorAction Stop }
                catch { $problems.Add("$directory runs.log line $lineNumber is not readable"); continue }
                $name = $null
                if ($null -ne $event -and $null -ne $event.PSObject.Properties['name']) {
                    $name = $event.PSObject.Properties['name'].Value
                }
                if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name)) {
                    $problems.Add("$directory runs.log line $lineNumber has no valid run name")
                    continue
                }
                if (-not $entries.ContainsKey($name)) { $entries[$name] = New-Object System.Collections.Generic.List[string] }
                $entries[$name].Add($directory)
            }
        }
    }

    # Composition of the frozen schedule and completeness of the runs.
    if ($null -ne $schedule -and $null -ne $frozen) {
        $result.Schedule = $schedule
        if ($schedule.Count -ne [int](Get-CatalogJsonProperty $frozen 'runs')) { $problems.Add("cell composition: the schedule has $($schedule.Count) runs, the frozen manifest $(Get-CatalogJsonProperty $frozen 'runs')") }
        $scheduleProblems = @(Test-CatalogSchedule -Schedule $schedule -Cells $cells -Arms $arms -Triplets $triplets)
        foreach ($p in $scheduleProblems) { $problems.Add("cell composition: $p") }
        $runs = New-Object System.Collections.Generic.List[object]
        $blockSessions = @{}
        foreach ($planned in $schedule) {
            $name = [string]$planned.Name
            $where = @(if ($entries.ContainsKey($name)) { $entries[$name] })
            if ($where.Count -eq 0) { $problems.Add("missing data: run $name was never run (no runs.log entry in any session)") }
            elseif ($where.Count -gt 1) { $problems.Add("run $name has $($where.Count) runs.log entries ($($where -join ', '))") }
            else {
                $runs.Add([pscustomobject]@{ Name = $name; Cell = $planned.Cell; Arm = $planned.Arm; Triplet = [int]$planned.Triplet; Directory = $where[0] })
                $block = [int]$planned.Block
                if (-not $blockSessions.ContainsKey($block)) { $blockSessions[$block] = @{} }
                $blockSessions[$block][$where[0]] = $true
            }
        }
        foreach ($block in @($blockSessions.Keys | Sort-Object)) {
            $sessions = @($blockSessions[$block].Keys | Sort-Object)
            if ($sessions.Count -gt 1) { $problems.Add("block $block is split across results directories: $($sessions -join ', ')") }
        }
        $scheduled = @{}
        foreach ($planned in $schedule) { $scheduled[[string]$planned.Name] = $true }
        foreach ($name in @($entries.Keys | Sort-Object)) { if (-not $scheduled.ContainsKey($name)) { $problems.Add("run $name is in runs.log but not in the frozen schedule") } }
        $result.Runs = $runs.ToArray()
    }
    [pscustomobject]$result
}

function Assert-CatalogConfirmatoryInputs {
    # Test-CatalogConfirmatoryInputs, stopping on any problem.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ResultsDirectories,
        [Parameter(Mandatory = $true)][string]$FrozenManifestPath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$FrozenManifestSha256,
        [Parameter(Mandatory = $true)][string]$ThresholdsPath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ThresholdsSha256
    )
    $checked = Test-CatalogConfirmatoryInputs @PSBoundParameters
    if ($checked.Problems.Count -gt 0) { throw "The confirmatory inputs are not complete and consistent; the confirmatory analysis stops: $($checked.Problems -join ' | ')" }
    $checked
}
