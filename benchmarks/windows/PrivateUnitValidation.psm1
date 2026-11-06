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

function Get-StablePrivateUnitRatios {
    <#
    The CIM read (PrivatePageCount) and the Get-Process read
    (PrivateMemorySize64) of a process are milliseconds apart. While a
    process is growing, as WebView2 processes do at startup, their ratio is
    not 1 even when both are bytes. A ratio is therefore used only for a
    process whose two values both changed by at most MaxRelativeChange since
    the previous sample of the same process (same identity key). The 0.9-1.1
    acceptance band of Get-VerifiedPrivateUnitRatio is not changed.

    Current: one object per process with Key, Cim and Proc (bytes or $null).
    Previous: hashtable Key -> object with Cim and Proc from the previous sample.
    Returns one object per current process with Stable and Ratio.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Current,
        [Parameter(Mandatory = $true)][hashtable]$Previous,
        [double]$MaxRelativeChange = 0.01
    )

    foreach ($item in $Current) {
        $stable = $false
        $ratio = $null
        $previousItem = $null
        if (-not [string]::IsNullOrEmpty([string]$item.Key) -and $Previous.ContainsKey([string]$item.Key)) {
            $previousItem = $Previous[[string]$item.Key]
        }
        $values = @($item.Cim, $item.Proc)
        if ($null -ne $previousItem) { $values += @($previousItem.Cim, $previousItem.Proc) }
        $allPositive = $null -ne $previousItem -and @($values | Where-Object { $null -eq $_ -or [double]$_ -le 0 }).Count -eq 0
        if ($allPositive) {
            $cimChange = [Math]::Abs([double]$item.Cim - [double]$previousItem.Cim) / [double]$previousItem.Cim
            $procChange = [Math]::Abs([double]$item.Proc - [double]$previousItem.Proc) / [double]$previousItem.Proc
            $stable = $cimChange -le $MaxRelativeChange -and $procChange -le $MaxRelativeChange
        }
        if ($null -ne $item.Cim -and $null -ne $item.Proc -and [double]$item.Proc -gt 0) {
            $ratio = [double]$item.Cim / [double]$item.Proc
        }
        [pscustomobject]@{
            Key      = $item.Key
            Cim      = $item.Cim
            Proc     = $item.Proc
            PrevCim  = if ($null -ne $previousItem) { $previousItem.Cim } else { $null }
            PrevProc = if ($null -ne $previousItem) { $previousItem.Proc } else { $null }
            Stable   = $stable
            Ratio    = $ratio
        }
    }
}

function Select-PrivateUnitRatios {
    <#
    The ratios the startup unit check may decide on. Candidates: one object
    per process with Pid, Name, Stable and Ratio. In the general mode any
    stable process with a ratio counts. With RequiredChildName (for the
    catalog Scenario M: msedgewebview2.exe) the check is not ready until at
    least one stable process of that name other than the root is among
    them, so it cannot pass on the host process alone; all stable ratios,
    the root's included, still go to Get-VerifiedPrivateUnitRatio.
    Returns Ready, Ratios and StableChildCount.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Candidates,
        [Parameter(Mandatory = $true)][int]$RootPid,
        [string]$RequiredChildName
    )
    $stable = @($Candidates | Where-Object { $_.Stable -and $null -ne $_.Ratio })
    $children = @($stable | Where-Object { [int]$_.Pid -ne $RootPid -and ([string]::IsNullOrEmpty($RequiredChildName) -or [string]$_.Name -ieq $RequiredChildName) })
    $ready = if ([string]::IsNullOrEmpty($RequiredChildName)) { $stable.Count -gt 0 } else { $children.Count -gt 0 }
    [pscustomobject]@{
        Ready            = $ready
        Ratios           = [double[]]@($stable | ForEach-Object { [double]$_.Ratio })
        StableChildCount = $children.Count
    }
}

Export-ModuleMember -Function Get-VerifiedPrivateUnitRatio, Get-StablePrivateUnitRatios, Select-PrivateUnitRatios
