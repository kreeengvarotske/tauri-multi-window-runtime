[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CatalogSignAnalysis.ps1')

function Assert-True {
    param([string]$Name, [bool]$Condition)
    if (-not $Condition) { throw "Failed: $Name" }
    Write-Host "ok $Name"
}

function Assert-Refused {
    param([string]$Name, [scriptblock]$Command, [string]$Message)
    $refused = $false
    try { & $Command | Out-Null }
    catch { $refused = $_.Exception.Message -like "*$Message*" }
    Assert-True $Name $refused
}

$pairRows = @(
    [pscustomobject]@{ Cell = 'N4D64'; Comparison = 'C-A'; Triplet = '2'; Valid = 'False'; InvalidReason = 'CPU coverage'; LoadPrivateMBDiff = ''; RunCpuSecondsDiff = '' }
    [pscustomobject]@{ Cell = 'N4D64'; Comparison = 'C-A'; Triplet = '1'; Valid = 'True'; InvalidReason = ''; LoadPrivateMBDiff = '-12.5'; RunCpuSecondsDiff = '-0.75' }
    [pscustomobject]@{ Cell = 'N4D64'; Comparison = 'C-B'; Triplet = '1'; Valid = 'True'; InvalidReason = ''; LoadPrivateMBDiff = '2'; RunCpuSecondsDiff = '0.25' }
)
$paired = Get-CatalogPairedDifferences -Rows $pairRows -Cell N4D64 -Comparison C-A -Outcome RAM -Triplets 2
Assert-True 'valid pairs are numerical and invalid pairs keep their reason' ($paired.Differences.Count -eq 1 -and $paired.Differences[0] -eq -12.5 -and $paired.Excluded[0].Reason -eq 'CPU coverage')
$cpu = Get-CatalogPairedDifferences -Rows $pairRows -Cell N4D64 -Comparison C-B -Outcome CPU -Triplets 1
Assert-True 'CPU uses only the requested comparison' ($cpu.Differences.Count -eq 1 -and $cpu.Differences[0] -eq 0.25)
Assert-Refused 'missing pair is not treated as invalid' { Get-CatalogPairedDifferences -Rows $pairRows -Cell N4D64 -Comparison C-A -Outcome RAM -Triplets 3 } 'Missing triplet 3'
Assert-Refused 'duplicate pair is rejected' { Get-CatalogPairedDifferences -Rows ($pairRows + $pairRows[0]) -Cell N4D64 -Comparison C-A -Outcome RAM -Triplets 2 } 'duplicate triplet'
$pairRows[1].LoadPrivateMBDiff = ''
Assert-Refused 'missing value on valid pair is rejected' { Get-CatalogPairedDifferences -Rows $pairRows -Cell N4D64 -Comparison C-A -Outcome RAM -Triplets 2 } 'Missing or non-finite'

$evidence = Get-CatalogSignEvidence -Id 'N4D64/RAM' -Differences (@(-12) * 10 + @(-10)) -Shift 10
Assert-True 'ties remain in N and do not support H1' ($evidence.N -eq 11 -and $evidence.Below -eq 10 -and $evidence.Ties -eq 1)
Assert-True '10 of 11 has the exact protocol tail' ([Math]::Abs($evidence.PValue - (12.0 / 2048)) -lt 1e-12)
$none = Get-CatalogSignEvidence -Id 'empty' -Differences @() -Shift 0
Assert-True 'no valid pairs give no evidence against H0' ($none.N -eq 0 -and $none.PValue -eq 1)
Assert-Refused 'non-finite pair refused' { Get-CatalogSignEvidence -Id 'bad' -Differences @([double]::NaN) -Shift 0 } 'non-finite paired difference'

$rows = @(
    [pscustomobject]@{ Id = 'D'; PValue = 0.04 }
    [pscustomobject]@{ Id = 'B'; PValue = 0.009 }
    [pscustomobject]@{ Id = 'A'; PValue = 0.001 }
    [pscustomobject]@{ Id = 'C'; PValue = 0.03 }
)
$ids = @('A', 'B', 'C', 'D')
$family = @(Resolve-CatalogHolmFamily -FrozenIds $ids -Evidence $rows)
Assert-True 'Holm sorts by raw p-value' (($family.Id -join '') -eq 'ABCD')
Assert-True 'Holm stops after the first non-rejection' ($family[0].Reject -and $family[1].Reject -and -not $family[2].Reject -and -not $family[3].Reject)
Assert-True 'adjusted values remain monotone' ([Math]::Abs($family[3].AdjustedPValue - 0.06) -lt 1e-12)
Assert-Refused 'missing evidence cannot shrink a frozen family' { Resolve-CatalogHolmFamily -FrozenIds $ids -Evidence @($rows[0..2]) } 'Missing evidence'
Assert-Refused 'duplicate evidence is rejected' { Resolve-CatalogHolmFamily -FrozenIds $ids -Evidence ($rows + $rows[0]) } 'duplicate evidence'
Assert-Refused 'unfrozen hypothesis is rejected' { Resolve-CatalogHolmFamily -FrozenIds @('A') -Evidence $rows } 'Unexpected'
Assert-Refused 'duplicate frozen hypothesis is rejected' { Resolve-CatalogHolmFamily -FrozenIds @('A', 'A') -Evidence @() } 'duplicate frozen'
Assert-Refused 'invalid probability is rejected' { Resolve-CatalogHolmFamily -FrozenIds @('A') -Evidence @([pscustomobject]@{ Id = 'A'; PValue = 1.1 }) } 'Invalid p-value'

$small = Get-CatalogMedianInterval -Differences (1..5) -Alpha 0.05
Assert-True 'insufficient pairs produce unbounded endpoints' ($small.N -eq 5 -and $null -eq $small.Lower -and $null -eq $small.Upper)
$six = Get-CatalogMedianInterval -Differences (6..1) -Alpha 0.05
Assert-True 'six pairs can only use their extrema at 95 percent' ($six.Rank -eq 1 -and $six.Lower -eq 1 -and $six.Upper -eq 6 -and [Math]::Abs($six.Coverage - 0.96875) -lt 1e-12)
$eleven = Get-CatalogMedianInterval -Differences (11..1) -Alpha 0.05
Assert-True 'eleven pairs use the second and tenth order statistics' ($eleven.Rank -eq 2 -and $eleven.Lower -eq 2 -and $eleven.Upper -eq 10)

Write-Host 'All synthetic sign, Holm and median interval checks passed.'
