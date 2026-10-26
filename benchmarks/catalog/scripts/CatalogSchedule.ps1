<#
.SYNOPSIS
The balanced run order of scenario M (protocol §6), dot-sourced by
Run-CatalogTriplets.ps1 and Test-CatalogScripts.ps1.

.DESCRIPTION
The unit is a triplet: one run of each arm, adjacent in time, same cell.
Cells are interleaved block by block: block b runs one triplet of every cell,
with the cell order rotated by one each block. Over all triplets in run
order, arm orders come from Latin squares taken whole and in turn (with three
arms: the three cyclic shifts of A,B,C, then the three of C,B,A), so every arm
takes every position equally often (within one) and every permutation is used
equally often (within one). Cells are interleaved and the first triplets use
different orders, so each cell starts at a different order. The seed picks
the first square, the shift inside it and the first cell rotation; it is
recorded with the schedule. With two arms (smoke runs) the same rules give
alternating pairs.
#>

Set-StrictMode -Version 2.0

function Get-LatinSquares {
    # Cyclic shifts of the arms form a Latin square: in every run of n
    # consecutive orders from one square, each arm takes each position once.
    # With three arms the shifts of the reversed list are the other three
    # permutations, so both squares together use all six.
    param([string[]]$Arms)
    $n = $Arms.Count
    $shifts = {
        param([string[]]$List)
        , @(for ($k = 0; $k -lt $n; $k++) { , @(for ($j = 0; $j -lt $n; $j++) { $List[($k + $j) % $n] }) })
    }
    $squares = New-Object System.Collections.Generic.List[object]
    $squares.Add((& $shifts $Arms))
    if ($n -ge 3) {
        $reversed = @($Arms); [array]::Reverse($reversed)
        $squares.Add((& $shifts $reversed))
    }
    return , $squares.ToArray()
}

function ConvertFrom-CellName {
    param([string]$Cell)
    if ($Cell -cnotmatch '^N([1-8])D(\d{1,3})$') { throw "Cell '$Cell' must look like N2D16 (windows 1-8, data 0-256 MiB)." }
    $data = [int]$Matches[2]
    if ($data -gt 256) { throw "Cell '$Cell': data must be at most 256 MiB." }
    return [pscustomobject]@{ Cell = $Cell; Windows = [int]$Matches[1]; DataMib = $data }
}

function New-CatalogSchedule {
    param(
        [Parameter(Mandatory = $true)][string[]]$Cells,
        [Parameter(Mandatory = $true)][string[]]$Arms,
        [Parameter(Mandatory = $true)][int]$Triplets,
        [Parameter(Mandatory = $true)][int]$Seed,
        [int]$DataSeed = 1
    )
    if (@($Cells | Select-Object -Unique).Count -ne $Cells.Count) { throw 'Cells must be distinct.' }
    if (@($Arms | Select-Object -Unique).Count -ne $Arms.Count) { throw 'Arms must be distinct.' }
    if ($Seed -lt 0) { throw 'Seed must be non-negative.' }
    $parsed = @($Cells | ForEach-Object { ConvertFrom-CellName $_ })
    $n = $Arms.Count
    $squares = Get-LatinSquares $Arms
    $firstSquare = $Seed % $squares.Count
    $firstShift = [int][Math]::Floor($Seed / $squares.Count) % $n
    $firstRotation = [int][Math]::Floor($Seed / ($squares.Count * $n)) % $parsed.Count
    $rows = New-Object System.Collections.Generic.List[object]
    $unit = 0
    for ($block = 1; $block -le $Triplets; $block++) {
        for ($k = 0; $k -lt $parsed.Count; $k++) {
            $cell = $parsed[($firstRotation + $block - 1 + $k) % $parsed.Count]
            $square = $squares[([int][Math]::Floor($unit / $n) + $firstSquare) % $squares.Count]
            $order = $square[($unit + $firstShift) % $n]
            for ($position = 1; $position -le $order.Count; $position++) {
                $arm = $order[$position - 1]
                $rows.Add([pscustomobject][ordered]@{
                        Seq = $rows.Count + 1; Block = $block; Cell = $cell.Cell; Windows = $cell.Windows; DataMib = $cell.DataMib
                        Triplet = $block; Position = $position; Arm = $arm; Permutation = ($order -join ''); DataSeed = $DataSeed
                        ScheduleSeed = $Seed; Name = ('{0}-t{1:D2}-p{2}-{3}' -f $cell.Cell, $block, $position, $arm)
                    })
            }
            $unit++
        }
    }
    return $rows.ToArray()
}
