[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'PrivateUnitValidation.psm1') -Force

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$MessagePattern, [string]$Description)
    $threw = $false
    try {
        & $Action | Out-Null
    }
    catch {
        $threw = $true
        if ($_.Exception.Message -notmatch $MessagePattern) {
            throw "$Description threw the wrong error: $($_.Exception.Message)"
        }
    }
    if (-not $threw) { throw "$Description did not fail closed." }
}

$validMedian = Get-VerifiedPrivateUnitRatio -Ratios ([double[]]@(0.99, 1.01, 1.0))
Assert-True ([Math]::Abs($validMedian - 1.0) -lt 0.000001) 'valid byte ratios should return the median'

Assert-Throws { Get-VerifiedPrivateUnitRatio -Ratios ([double[]]@()) } 'unit is unverified|Could not compare' 'empty ratio list'
Assert-Throws { Get-VerifiedPrivateUnitRatio -Ratios ([double[]]@([double]::NaN, [double]::PositiveInfinity)) } 'unit is unverified|Could not compare' 'non-finite-only ratio list'
Assert-Throws { Get-VerifiedPrivateUnitRatio -Ratios ([double[]]@(1.0 / 4096.0, 1.0 / 4096.0)) } 'does not look like bytes' 'page-count-sized ratios'

Write-Host 'PASS: private-memory unit validation accepts confirmed bytes and fails closed for empty, non-finite, and wrong-unit ratios.'
