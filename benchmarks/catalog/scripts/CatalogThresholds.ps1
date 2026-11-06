<#
.SYNOPSIS
Threshold reference, margins and sign-test counts of the confirmatory plan
(protocol #33 §8b, Q7 proposal), dot-sourced by Test-CatalogScripts.ps1 and
by the confirmatory analysis.

.DESCRIPTION
The form of each threshold (floor and percentage) is fixed in the protocol.
The value the percentage applies to is the median of arm A (for δ and η) or
arm B (for ε) over the valid PILOT runs of a cell, rounded to 0.1 MiB or
0.01 s. It needs at least 4 valid pilot runs; otherwise the cell has no
threshold for that outcome (no fallback to the floor). The thresholds are
written to thresholds.csv at the freeze, before any confirmatory run, and
never recomputed from confirmatory data: New-CatalogThresholds refuses any
phase but Pilot. The confirmatory analysis reads them only through
Import-CatalogThresholds, which checks the SHA-256 recorded at the freeze.

Sign test: a triplet supports H1 only when d + shift is strictly below 0
(shift = +δ for a saving, −η for non-inferiority). A difference exactly at
the threshold counts against H1 and stays in n.
#>

Set-StrictMode -Version 2.0

$script:CatalogOutcomeColumns = @{ RAM = 'LoadPrivateMBAvg'; CPU = 'RunCpuSeconds' }
$script:CatalogOutcomeDigits = @{ RAM = 1; CPU = 2 }

function Get-CatalogThresholdForms {
    # Kind, outcome, reference arm, floor, share of the reference, and how they combine (protocol §8b).
    @(
        [pscustomobject]@{ Kind = 'Delta'; Outcome = 'RAM'; ReferenceArm = 'A'; Floor = 10.0; Share = 0.05; Combine = 'Max' }
        [pscustomobject]@{ Kind = 'Delta'; Outcome = 'CPU'; ReferenceArm = 'A'; Floor = 1.0; Share = 0.10; Combine = 'Max' }
        [pscustomobject]@{ Kind = 'Eta'; Outcome = 'RAM'; ReferenceArm = 'A'; Floor = 10.0; Share = 0.05; Combine = 'Max' }
        [pscustomobject]@{ Kind = 'Eta'; Outcome = 'CPU'; ReferenceArm = 'A'; Floor = 1.0; Share = 0.10; Combine = 'Sum' }
        [pscustomobject]@{ Kind = 'Epsilon'; Outcome = 'RAM'; ReferenceArm = 'B'; Floor = 5.0; Share = 0.02; Combine = 'Max' }
        [pscustomobject]@{ Kind = 'Epsilon'; Outcome = 'CPU'; ReferenceArm = 'B'; Floor = 0.5; Share = 0.05; Combine = 'Max' }
    )
}

function Get-CatalogMargin {
    param([Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Outcome, [Parameter(Mandatory)][double]$Reference)
    $form = @(Get-CatalogThresholdForms | Where-Object { $_.Kind -eq $Kind -and $_.Outcome -eq $Outcome })
    if ($form.Count -ne 1) { throw "Unknown threshold $Kind/$Outcome." }
    if ($Reference -lt 0 -or [double]::IsNaN($Reference) -or [double]::IsInfinity($Reference)) { throw "Reference '$Reference' is not a non-negative number." }
    $share = $form[0].Share * $Reference
    if ($form[0].Combine -eq 'Sum') { return $form[0].Floor + $share }
    [Math]::Max($form[0].Floor, $share)
}

function Test-CatalogRunValid {
    param($Run)
    # Valid is a bool in memory and the string 'True'/'False' after a CSV round trip.
    if ($Run.Valid -is [bool]) { return $Run.Valid }
    [string]$Run.Valid -eq 'True'
}

function Get-CatalogReference {
    param(
        [Parameter(Mandatory)][object[]]$Runs,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$Cell,
        [Parameter(Mandatory)][string]$Arm,
        [Parameter(Mandatory)][string]$Outcome,
        [int]$MinValid = 4
    )
    if ($Phase -ne 'Pilot') { throw "Threshold references come from pilot runs only (got phase '$Phase')." }
    if (-not $script:CatalogOutcomeColumns.ContainsKey($Outcome)) { throw "Unknown outcome '$Outcome'." }
    $column = $script:CatalogOutcomeColumns[$Outcome]
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $values = New-Object System.Collections.Generic.List[double]
    foreach ($run in $Runs) {
        if ($run.Cell -ne $Cell -or $run.Arm -ne $Arm -or -not (Test-CatalogRunValid $run)) { continue }
        $value = [double]::NaN
        if (-not [double]::TryParse([string]$run.$column, [System.Globalization.NumberStyles]::Float, $culture, [ref]$value)) { continue }
        $values.Add($value)
    }
    $result = [ordered]@{ Cell = $Cell; Outcome = $Outcome; Arm = $Arm; ValidRuns = $values.Count; Reference = $null; Reason = '' }
    if ($values.Count -lt $MinValid) {
        $result.Reason = "$($values.Count) valid pilot runs with $column (need $MinValid)"
        return [pscustomobject]$result
    }
    $sorted = @($values | Sort-Object)
    $middle = [int][Math]::Floor($sorted.Count / 2)
    $median = if ($sorted.Count % 2 -eq 1) { $sorted[$middle] } else { ($sorted[$middle - 1] + $sorted[$middle]) / 2 }
    # Rounded as a decimal (15 significant digits), so a median such as 1.005 rounds up as written.
    $result.Reference = [double][Math]::Round([decimal]$median, [int]$script:CatalogOutcomeDigits[$Outcome], [MidpointRounding]::AwayFromZero)
    [pscustomobject]$result
}

function New-CatalogThresholds {
    # One row per cell, kind and outcome: the content of thresholds.csv.
    param([Parameter(Mandatory)][object[]]$Runs, [Parameter(Mandatory)][string]$Phase, [Parameter(Mandatory)][string[]]$Cells, [int]$MinValid = 4)
    if ($Phase -ne 'Pilot') { throw "Thresholds are computed from pilot runs only (got phase '$Phase')." }
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    foreach ($cell in $Cells) {
        foreach ($form in Get-CatalogThresholdForms) {
            $reference = Get-CatalogReference -Runs $Runs -Phase $Phase -Cell $cell -Arm $form.ReferenceArm -Outcome $form.Outcome -MinValid $MinValid
            $threshold = $null
            if ($null -ne $reference.Reference) { $threshold = Get-CatalogMargin -Kind $form.Kind -Outcome $form.Outcome -Reference $reference.Reference }
            [pscustomobject][ordered]@{
                Cell = $cell; Kind = $form.Kind; Outcome = $form.Outcome; ReferenceArm = $form.ReferenceArm
                Reference = $reference.Reference; ValidPilotRuns = $reference.ValidRuns
                Form = ('{0}({1}, {2} x Ref)' -f $form.Combine.ToLowerInvariant(), $form.Floor.ToString($culture), $form.Share.ToString($culture))
                Threshold = $threshold; Reason = $reference.Reason
            }
        }
    }
}

function Get-CatalogFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Import-CatalogThresholds {
    <#
    Reads thresholds.csv for the confirmatory analysis (protocol #33 §10a).
    ExpectedSha256 is the hash recorded at the confirmatory freeze. The file
    is hashed before it is parsed, and any difference stops the analysis:
    a missing file, a malformed expected hash, a hash mismatch, or a table
    that does not have exactly one row per cell, kind and outcome. Returns
    the rows and the verified hash, to be written next to the results.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedSha256,
        [Parameter(Mandatory)][string[]]$Cells
    )
    if ($ExpectedSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw "The frozen SHA-256 of thresholds.csv is not a 64-digit hex value ('$ExpectedSha256'); the confirmatory analysis stops." }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "thresholds.csv not found at '$Path'; the confirmatory analysis stops." }
    $actual = Get-CatalogFileSha256 -Path $Path
    if ($actual -ne $ExpectedSha256.ToLowerInvariant()) { throw "thresholds.csv SHA-256 $actual does not match the frozen $($ExpectedSha256.ToLowerInvariant()); the confirmatory analysis stops." }
    $rows = @(Import-Csv -LiteralPath $Path)
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $expected = New-Object System.Collections.Generic.List[string]
    foreach ($cell in $Cells) { foreach ($form in Get-CatalogThresholdForms) { $expected.Add("$cell/$($form.Kind)/$($form.Outcome)") } }
    $present = @($rows | ForEach-Object { "$($_.Cell)/$($_.Kind)/$($_.Outcome)" })
    $missing = @($expected | Where-Object { $present -notcontains $_ })
    $extra = @($present | Where-Object { $expected -notcontains $_ })
    $duplicates = @($present | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($missing.Count -gt 0 -or $extra.Count -gt 0 -or $duplicates.Count -gt 0) {
        throw "thresholds.csv does not have one row per cell, kind and outcome (missing: $($missing -join ', '); unexpected: $($extra -join ', '); duplicated: $($duplicates -join ', ')); the confirmatory analysis stops."
    }
    foreach ($row in $rows) {
        $value = [double]::NaN
        if (-not [string]::IsNullOrEmpty([string]$row.Threshold) -and -not [double]::TryParse([string]$row.Threshold, [System.Globalization.NumberStyles]::Float, $culture, [ref]$value)) {
            throw "thresholds.csv has a non-numeric threshold '$($row.Threshold)' for $($row.Cell)/$($row.Kind)/$($row.Outcome); the confirmatory analysis stops."
        }
    }
    [pscustomobject]@{ Sha256 = $actual; Rows = $rows }
}

function Get-SignCount {
    # Counts of d + Shift below, at and above 0. Only "below" supports H1.
    param([Parameter(Mandatory)][AllowEmptyCollection()][double[]]$Differences, [Parameter(Mandatory)][double]$Shift)
    $below = 0; $at = 0; $above = 0
    foreach ($d in $Differences) {
        $x = $d + $Shift
        if ($x -lt 0) { $below++ } elseif ($x -eq 0) { $at++ } else { $above++ }
    }
    [pscustomobject]@{ N = $Differences.Count; Below = $below; AtZero = $at; Above = $above }
}

function Get-BinomialUpperTail {
    # P(X >= K) for X ~ Binomial(N, P).
    param([Parameter(Mandatory)][int]$N, [Parameter(Mandatory)][int]$K, [Parameter(Mandatory)][double]$P)
    $sum = 0.0
    for ($i = [Math]::Max($K, 0); $i -le $N; $i++) {
        $logChoose = 0.0
        for ($j = 1; $j -le $i; $j++) { $logChoose += [Math]::Log($N - $i + $j) - [Math]::Log($j) }
        $term = $logChoose
        if ($i -gt 0) { $term += $i * [Math]::Log($P) }
        if ($N - $i -gt 0) { $term += ($N - $i) * [Math]::Log(1 - $P) }
        $sum += [Math]::Exp($term)
    }
    $sum
}

function Get-SignCritical {
    # Smallest count K with P(X >= K | N, 1/2) <= Alpha; N + 1 when no count is small enough.
    param([Parameter(Mandatory)][int]$N, [Parameter(Mandatory)][double]$Alpha)
    for ($k = 0; $k -le $N; $k++) {
        if ((Get-BinomialUpperTail -N $N -K $k -P 0.5) -le $Alpha) { return $k }
    }
    $N + 1
}

function Test-SignMargin {
    # One-sided sign test of H1: median d < -Shift, at level Alpha.
    param([Parameter(Mandatory)][AllowEmptyCollection()][double[]]$Differences, [Parameter(Mandatory)][double]$Shift, [Parameter(Mandatory)][double]$Alpha)
    $count = Get-SignCount -Differences $Differences -Shift $Shift
    $critical = Get-SignCritical -N $count.N -Alpha $Alpha
    [pscustomobject]@{ N = $count.N; Below = $count.Below; AtZero = $count.AtZero; Critical = $critical; Reject = ($count.N -gt 0 -and $count.Below -ge $critical) }
}
