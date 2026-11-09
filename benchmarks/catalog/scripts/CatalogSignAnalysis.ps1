# Pure helpers for paired summaries and the draft confirmatory sign tests.
# The caller supplies the frozen family membership and validated paired data.
. (Join-Path $PSScriptRoot 'CatalogThresholds.ps1')

function Get-CatalogPairCorrelation {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$ValidPairs)
    if ($ValidPairs.Count -lt 2) { return $null }
    $ramMean = ($ValidPairs | Measure-Object -Property LoadPrivateMBDiff -Average).Average
    $cpuMean = ($ValidPairs | Measure-Object -Property RunCpuSecondsDiff -Average).Average
    $cross = 0.0; $ramSquares = 0.0; $cpuSquares = 0.0
    foreach ($pair in $ValidPairs) {
        $ram = $pair.LoadPrivateMBDiff - $ramMean
        $cpu = $pair.RunCpuSecondsDiff - $cpuMean
        $cross += $ram * $cpu
        $ramSquares += $ram * $ram
        $cpuSquares += $cpu * $cpu
    }
    if ($ramSquares -eq 0 -or $cpuSquares -eq 0) { return $null }
    $coefficient = $cross / ([Math]::Sqrt($ramSquares) * [Math]::Sqrt($cpuSquares))
    [Math]::Max(-1.0, [Math]::Min(1.0, $coefficient))
}

function Get-CatalogPairedDifferences {
    # Reads one comparison from the summarizer's triplets.csv rows. Missing
    # or duplicate rows are input errors; explicitly invalid pairs stay in
    # the audit trail and do not contribute a numerical difference.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory = $true)][string]$Cell,
        [Parameter(Mandatory = $true)][ValidateSet('C-A', 'C-B', 'B-A')][string]$Comparison,
        [Parameter(Mandatory = $true)][ValidateSet('RAM', 'CPU')][string]$Outcome,
        [Parameter(Mandatory = $true)][ValidateRange(1, 50)][int]$Triplets
    )
    $measure = if ($Outcome -eq 'RAM') { 'LoadPrivateMBDiff' } else { 'RunCpuSecondsDiff' }
    $pairs = @{}
    foreach ($row in $Rows) {
        if ($row.Cell -ne $Cell -or $row.Comparison -ne $Comparison) { continue }
        $number = 0
        if (-not [int]::TryParse([string]$row.Triplet, [ref]$number) -or $number -lt 1 -or $number -gt $Triplets -or $pairs.ContainsKey($number)) {
            throw "Unexpected or duplicate triplet '$($row.Triplet)' for $Cell/$Comparison."
        }
        $pairs[$number] = $row
    }
    $differences = New-Object 'System.Collections.Generic.List[double]'
    $excluded = New-Object 'System.Collections.Generic.List[object]'
    for ($number = 1; $number -le $Triplets; $number++) {
        if (-not $pairs.ContainsKey($number)) { throw "Missing triplet $number for $Cell/$Comparison." }
        $row = $pairs[$number]
        $valid = $false
        if (-not [bool]::TryParse([string]$row.Valid, [ref]$valid)) {
            throw "Invalid validity marker on triplet $number for $Cell/$Comparison."
        }
        if (-not $valid) {
            $excluded.Add([pscustomobject]@{ Triplet = $number; Reason = [string]$row.InvalidReason })
            continue
        }
        $raw = $row.$measure
        $value = 0.0
        $parsed = $true
        if ($raw -is [double]) { $value = $raw }
        else {
            $parsed = [double]::TryParse([string]$raw, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)
        }
        if (-not $parsed -or [double]::IsNaN($value) -or [double]::IsInfinity($value)) {
            throw "Missing or non-finite $measure on valid triplet $number for $Cell/$Comparison."
        }
        $differences.Add($value)
    }
    [pscustomobject]@{ Differences = $differences.ToArray(); Excluded = $excluded.ToArray() }
}

function Get-CatalogSignEvidence {
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Id,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][double[]]$Differences,
        [Parameter(Mandatory = $true)][double]$Shift
    )
    if ([double]::IsNaN($Shift) -or [double]::IsInfinity($Shift)) {
        throw 'The frozen shift must be finite.'
    }
    foreach ($difference in $Differences) {
        if ([double]::IsNaN($difference) -or [double]::IsInfinity($difference)) {
            throw "Hypothesis '$Id' contains a non-finite paired difference."
        }
    }
    $counts = Get-SignCount -Differences $Differences -Shift $Shift
    $pValue = if ($counts.Below -eq 0) { 1.0 } else {
        [Math]::Min(1.0, (Get-BinomialUpperTail -N $counts.N -K $counts.Below -P 0.5))
    }
    [pscustomobject]@{
        Id = $Id
        N = $counts.N
        Below = $counts.Below
        Ties = $counts.AtZero
        Above = $counts.Above
        Shift = $Shift
        PValue = $pValue
    }
}

function Resolve-CatalogHolmFamily {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$FrozenIds,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Evidence,
        [double]$Alpha = 0.05
    )
    if ([double]::IsNaN($Alpha) -or $Alpha -le 0 -or $Alpha -ge 1) {
        throw 'Alpha must be strictly between 0 and 1.'
    }
    $expected = @{}
    foreach ($id in $FrozenIds) {
        if ([string]::IsNullOrWhiteSpace($id) -or $expected.ContainsKey($id)) {
            throw "Empty or duplicate frozen hypothesis '$id'."
        }
        $expected[$id] = $true
    }
    $seen = @{}
    $validated = @(foreach ($item in $Evidence) {
        if ($null -eq $item -or -not $item.PSObject.Properties['Id'] -or
            -not $item.PSObject.Properties['PValue'] -or $null -eq $item.PValue) {
            throw 'Each evidence row must contain a hypothesis ID and p-value.'
        }
        $id = [string]$item.Id
        if (-not $expected.ContainsKey($id) -or $seen.ContainsKey($id)) {
            throw "Unexpected or duplicate evidence for hypothesis '$id'."
        }
        $p = [double]$item.PValue
        if ([double]::IsNaN($p) -or $p -lt 0 -or $p -gt 1) {
            throw "Invalid p-value for hypothesis '$id'."
        }
        $seen[$id] = $true
        [pscustomobject]@{ Id = $id; PValue = $p }
    })
    foreach ($id in $FrozenIds) {
        if (-not $seen.ContainsKey($id)) { throw "Missing evidence for frozen hypothesis '$id'." }
    }

    $ordered = @($validated | Sort-Object PValue, Id)
    $adjusted = 0.0
    for ($index = 0; $index -lt $ordered.Count; $index++) {
        $remaining = $ordered.Count - $index
        $item = $ordered[$index]
        $adjusted = [Math]::Max($adjusted, [Math]::Min(1.0, $remaining * $item.PValue))
        [pscustomobject]@{
            Id = $item.Id
            Rank = $index + 1
            FamilySize = $ordered.Count
            PValue = $item.PValue
            CriticalAlpha = $Alpha / $remaining
            AdjustedPValue = $adjusted
            Reject = $adjusted -le $Alpha
        }
    }
}

function Get-CatalogMedianInterval {
    # Two-sided order-statistic interval at the alpha supplied by the caller.
    # With too few pairs the requested coverage needs unbounded endpoints.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][double[]]$Differences,
        [Parameter(Mandatory = $true)][double]$Alpha
    )
    if ([double]::IsNaN($Alpha) -or $Alpha -le 0 -or $Alpha -ge 1) {
        throw 'Alpha must be strictly between 0 and 1.'
    }
    foreach ($difference in $Differences) {
        if ([double]::IsNaN($difference) -or [double]::IsInfinity($difference)) {
            throw 'The interval contains a non-finite paired difference.'
        }
    }
    $n = $Differences.Count
    $rank = 0
    $coverage = 1.0
    for ($k = 1; $k -le [Math]::Floor(($n + 1) / 2); $k++) {
        $nonCoverage = 2 * (Get-BinomialUpperTail -N $n -K ($n - $k + 1) -P 0.5)
        if ($nonCoverage -gt $Alpha) { break }
        $rank = $k
        $coverage = 1.0 - $nonCoverage
    }
    $sorted = @($Differences | Sort-Object)
    [pscustomobject]@{
        N = $n
        Rank = $rank
        Lower = if ($rank -gt 0) { $sorted[$rank - 1] } else { $null }
        Upper = if ($rank -gt 0) { $sorted[$n - $rank] } else { $null }
        Coverage = $coverage
    }
}

function Get-CatalogConfirmatorySignFamily {
    # The freeze defines membership. This function never selects hypotheses
    # from observed data or recomputes margins from confirmatory runs.
    param(
        [Parameter(Mandatory = $true)][ValidateSet('P', 'NI-RAM', 'NI-CPU')][string]$Family,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$FrozenIds,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$ThresholdRows,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$PairRows,
        [Parameter(Mandatory = $true)][ValidateRange(1, 50)][int]$Triplets
    )
    $kind = if ($Family -eq 'P') { 'Delta' } else { 'Eta' }
    $evidence = @(foreach ($id in $FrozenIds) {
        $parsed = [regex]::Match($id, '^(?<cell>N[0-9]+D[0-9]+)/(?<outcome>RAM|CPU)$')
        if (-not $parsed.Success) { throw "Invalid frozen hypothesis ID '$id'." }
        $cell = $parsed.Groups['cell'].Value
        $outcome = $parsed.Groups['outcome'].Value
        if ($cell -eq 'N2D0' -or ($Family -ne 'P' -and $Family -ne "NI-$outcome")) {
            throw "Hypothesis '$id' does not belong to family '$Family'."
        }
        $threshold = @($ThresholdRows | Where-Object { $_.Cell -eq $cell -and $_.Kind -eq $kind -and $_.Outcome -eq $outcome })
        $margin = 0.0
        if ($threshold.Count -ne 1 -or
            -not [double]::TryParse([string]$threshold[0].Threshold, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$margin) -or
            [double]::IsNaN($margin) -or [double]::IsInfinity($margin) -or $margin -lt 0) {
            throw "Missing or invalid frozen $kind threshold for '$id'."
        }
        $pairs = Get-CatalogPairedDifferences -Rows $PairRows -Cell $cell -Comparison C-A -Outcome $outcome -Triplets $Triplets
        $shift = if ($Family -eq 'P') { $margin } else { -$margin }
        $result = Get-CatalogSignEvidence -Id $id -Differences $pairs.Differences -Shift $shift
        $status = 'Evaluated'
        if ($Family -eq 'P' -and $result.N -lt 10) {
            # Protocol §8b keeps the hypothesis in Holm with p = 1.
            $result.PValue = 1.0
            $status = 'InsufficientValidTriplets'
        }
        $result | Add-Member -NotePropertyName Status -NotePropertyValue $status
        $result | Add-Member -NotePropertyName Excluded -NotePropertyValue $pairs.Excluded
        $result
    })
    [pscustomobject]@{
        Family = $Family
        Evidence = $evidence
        Adjustments = @(Resolve-CatalogHolmFamily -FrozenIds $FrozenIds -Evidence $evidence)
    }
}

function Get-CatalogFixedCostControl {
    param(
        [Parameter(Mandatory = $true)][object[]]$PairRows,
        [Parameter(Mandatory = $true)][ValidateRange(1, 50)][int]$Triplets
    )
    foreach ($outcome in 'RAM', 'CPU') {
        $band = if ($outcome -eq 'RAM') { 10 } else { 1 }
        $pairs = Get-CatalogPairedDifferences -Rows $PairRows -Cell N2D0 -Comparison C-A -Outcome $outcome -Triplets $Triplets
        $interval = Get-CatalogMedianInterval -Differences $pairs.Differences -Alpha 0.05
        $withinBand = $null
        if ($interval.Rank -gt 0) { $withinBand = $interval.Lower -ge -$band -and $interval.Upper -le $band }
        [pscustomobject]@{
            Cell = 'N2D0'; Comparison = 'C-A'; Outcome = $outcome
            Band = $band; NominalCoverage = 0.95; Interval = $interval
            WithinReferenceBand = $withinBand; Excluded = $pairs.Excluded
        }
    }
}

function Get-CatalogCheckedSignResults {
    # Pair rows must be produced by the summarizer from the checked sessions.
    # This step checks their schedule coverage before computing sign evidence.
    param(
        [Parameter(Mandatory = $true)][object]$CheckedInputs,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$PairRows
    )
    if ($CheckedInputs.Problems.Count -ne 0 -or -not $CheckedInputs.ManifestSha256 -or
        -not $CheckedInputs.ThresholdsSha256 -or -not $CheckedInputs.Schedule) {
        throw 'Confirmatory input validation must pass before sign analysis.'
    }
    $expected = @{}
    foreach ($run in $CheckedInputs.Schedule) { $expected["$($run.Cell)/$($run.Triplet)"] = $true }
    $observed = @{}
    foreach ($row in $PairRows) {
        $key = "$($row.Cell)/$($row.Triplet)"
        if (-not $expected.ContainsKey($key) -or $row.Comparison -notin @('C-A', 'C-B', 'B-A')) {
            throw "Pair row '$key/$($row.Comparison)' is outside the frozen schedule."
        }
        $pairKey = "$key/$($row.Comparison)"
        if ($observed.ContainsKey($pairKey)) { throw "Duplicate pair row '$pairKey'." }
        $observed[$pairKey] = $true
    }
    if ($observed.Count -ne (3 * $expected.Count)) { throw 'Pair rows do not cover the full frozen schedule.' }

    $families = $CheckedInputs.Manifest.PSObject.Properties['signFamilies']
    if ($null -eq $families -or $families.Value -isnot [pscustomobject]) {
        throw 'The frozen manifest must contain a signFamilies object.'
    }
    $ids = @{}
    foreach ($family in 'P', 'NI-RAM', 'NI-CPU') {
        $member = $families.Value.PSObject.Properties[$family]
        if ($null -eq $member -or $member.Value -isnot [array]) {
            throw "The frozen signFamilies object must contain an array for '$family'."
        }
        foreach ($id in $member.Value) {
            if ($id -isnot [string] -or [string]::IsNullOrWhiteSpace($id)) {
                throw "Frozen family '$family' contains an invalid hypothesis ID."
            }
        }
        $ids[$family] = [string[]]$member.Value
    }
    $triplets = ($CheckedInputs.Schedule | Measure-Object -Property Triplet -Maximum).Maximum
    $inputs = @{ ThresholdRows = $CheckedInputs.Thresholds; PairRows = $PairRows; Triplets = $triplets }
    $fixedCost = @(if ($CheckedInputs.Schedule.Cell -contains 'N2D0') {
        Get-CatalogFixedCostControl -PairRows $PairRows -Triplets $triplets
    })
    [pscustomobject]@{
        ManifestSha256 = $CheckedInputs.ManifestSha256
        ThresholdsSha256 = $CheckedInputs.ThresholdsSha256
        Primary = Get-CatalogConfirmatorySignFamily @inputs -Family P -FrozenIds $ids['P']
        NiRam = Get-CatalogConfirmatorySignFamily @inputs -Family NI-RAM -FrozenIds $ids['NI-RAM']
        NiCpu = Get-CatalogConfirmatorySignFamily @inputs -Family NI-CPU -FrozenIds $ids['NI-CPU']
        DescriptiveFixedCost = $fixedCost
    }
}

function Get-CatalogSavingStatement {
    # Protocol §8b, per cell. Guardrails can block a statement. A
    # non-inferiority result alone never establishes a saving.
    param(
        [Parameter(Mandatory = $true)][bool]$GuardrailsPassed,
        [Parameter(Mandatory = $true)][bool]$RamSaving,
        [Parameter(Mandatory = $true)][bool]$CpuSaving,
        [Parameter(Mandatory = $true)][bool]$RamNotWorse,
        [Parameter(Mandatory = $true)][bool]$CpuNotWorse
    )
    if (-not $GuardrailsPassed) { return 'BlockedByGuardrails' }
    if ($RamSaving -and $CpuSaving) { return 'SavesRamAndCpu' }
    if ($RamSaving) {
        if ($CpuNotWorse) { return 'SavesRamCpuNotWorse' }
        return 'SavesRamPossibleCpuCost'
    }
    if ($CpuSaving) {
        if ($RamNotWorse) { return 'SavesCpuRamNotWorse' }
        return 'SavesCpuPossibleRamCost'
    }
    return 'NoSavingShown'
}
