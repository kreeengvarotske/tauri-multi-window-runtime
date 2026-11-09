# Pure helpers for the sign tests in the draft confirmatory protocol.
# The caller supplies the frozen family membership and validated paired data.
. (Join-Path $PSScriptRoot 'CatalogThresholds.ps1')

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
