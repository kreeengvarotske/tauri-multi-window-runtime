function Get-VerifiedPrivateUnitRatio {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [double[]]$Ratios
    )

    # Discard only non-finite values; an empty valid set must be a hard failure.
    $valid = @($Ratios | Where-Object {
        -not [double]::IsNaN([double]$_) -and -not [double]::IsInfinity([double]$_)
    })
    if ($valid.Count -eq 0) {
        throw "Could not compare PrivatePageCount with Get-Process PrivateMemorySize64 for any process. The PrivateBytesMB unit is unverified; refusing to start a measurement that could report an unverified metric. Retry with appropriate process access or use -Diagnostics to investigate."
    }

    $sorted = @($valid | Sort-Object)
    $middle = [int][Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) {
        $median = [double]$sorted[$middle]
    }
    else {
        $median = ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2.0
    }

    if ($median -lt 0.9 -or $median -gt 1.1) {
        throw ("PrivatePageCount does not look like bytes on this system: its median ratio to Get-Process PrivateMemorySize64 is {0} over {1} processes (1 = bytes). PrivateBytesMB would be wrong. Run with -Diagnostics and report the output." -f $median.ToString('F6', [System.Globalization.CultureInfo]::InvariantCulture), $valid.Count)
    }

    return [double]$median
}

Export-ModuleMember -Function Get-VerifiedPrivateUnitRatio
