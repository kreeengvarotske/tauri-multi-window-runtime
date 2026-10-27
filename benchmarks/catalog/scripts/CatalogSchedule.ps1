<#
.SYNOPSIS
The balanced run order of scenario M (protocol §6), dot-sourced by
Run-CatalogTriplets.ps1 and Test-CatalogScripts.ps1.

.DESCRIPTION
The unit is a triplet: one run of each arm, adjacent in time, same cell.
Cells are interleaved block by block: block b runs one triplet of every cell,
with the cell order rotated by one each block.

Arm orders are balanced per cell (protocol §6, Q8). The permutations are
the rows of the Latin squares (with three arms: the three cyclic shifts of
A,B,C, then the three of C,B,A, which together are all six). Each cell
walks through them in turn from its own starting point, one per triplet, so
6 triplets of a cell use every permutation once and put every arm in every
position twice; for any other count the permutations of a cell differ by
at most one use. Cells start at different permutations (as long as there are
no more cells than permutations). The seed picks the first starting point and
the first cell rotation; it is recorded with the schedule. With two arms
(smoke runs) each cell alternates AB and BA.

Test-CatalogSchedule checks a whole schedule (every cell, triplet and arm
exactly once, adjacent triplets, contiguous Seq) and is run on schedule.csv
as written, before the first run.
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

function Get-ArmPermutations {
    # The rows of the Latin squares, in order: square by square.
    param([string[]]$Arms)
    $permutations = New-Object System.Collections.Generic.List[object]
    foreach ($square in (Get-LatinSquares $Arms)) {
        foreach ($order in $square) { $permutations.Add(@($order)) }
    }
    return , $permutations.ToArray()
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
    if ($Triplets -lt 1) { throw 'Triplets must be at least 1.' }
    $parsed = @($Cells | ForEach-Object { ConvertFrom-CellName $_ })
    $permutations = Get-ArmPermutations $Arms
    $count = $permutations.Count
    $firstOffset = $Seed % $count
    $firstRotation = [int][Math]::Floor($Seed / $count) % $parsed.Count
    $rows = New-Object System.Collections.Generic.List[object]
    for ($block = 1; $block -le $Triplets; $block++) {
        for ($k = 0; $k -lt $parsed.Count; $k++) {
            $index = ($firstRotation + $block - 1 + $k) % $parsed.Count
            $cell = $parsed[$index]
            # Cell `index` starts at its own permutation and takes the next
            # one for each of its triplets.
            $order = $permutations[($firstOffset + $index + $block - 1) % $count]
            for ($position = 1; $position -le $order.Count; $position++) {
                $arm = $order[$position - 1]
                $rows.Add([pscustomobject][ordered]@{
                        Seq = $rows.Count + 1; Block = $block; Cell = $cell.Cell; Windows = $cell.Windows; DataMib = $cell.DataMib
                        Triplet = $block; Position = $position; Arm = $arm; Permutation = ($order -join ''); DataSeed = $DataSeed
                        ScheduleSeed = $Seed; Name = ('{0}-t{1:D2}-p{2}-{3}' -f $cell.Cell, $block, $position, $arm)
                    })
            }
        }
    }
    return $rows.ToArray()
}

function Test-CatalogSchedule {
    # Returns the problems with a schedule (rows as written or read back from
    # schedule.csv); an empty list means it is complete and well formed.
    param(
        [Parameter(Mandatory = $true)][object[]]$Schedule,
        [Parameter(Mandatory = $true)][string[]]$Cells,
        [Parameter(Mandatory = $true)][string[]]$Arms,
        [Parameter(Mandatory = $true)][int]$Triplets
    )
    $problems = New-Object System.Collections.Generic.List[string]
    $expected = $Cells.Count * $Arms.Count * $Triplets
    if ($Schedule.Count -ne $expected) { $problems.Add("expected $expected runs, found $($Schedule.Count)") }
    $seqs = @($Schedule | ForEach-Object { [int]$_.Seq })
    if (($seqs -join ',') -ne ((1..$Schedule.Count) -join ',')) { $problems.Add('Seq is not 1..n in order') }
    $names = @($Schedule | ForEach-Object { $_.Name })
    if (@($names | Select-Object -Unique).Count -ne $names.Count) { $problems.Add('run names are not unique') }
    $wantArms = (@($Arms | Sort-Object) -join ',')
    foreach ($cell in $Cells) {
        for ($t = 1; $t -le $Triplets; $t++) {
            $unit = @($Schedule | Where-Object { $_.Cell -eq $cell -and [int]$_.Triplet -eq $t } | Sort-Object { [int]$_.Position })
            $label = "$cell triplet $t"
            if ($unit.Count -ne $Arms.Count) { $problems.Add("${label}: $($unit.Count) runs"); continue }
            if ((@($unit | ForEach-Object { $_.Arm } | Sort-Object) -join ',') -ne $wantArms) { $problems.Add("${label}: arms are not each arm once") }
            if ((@($unit | ForEach-Object { [int]$_.Position }) -join ',') -ne ((1..$Arms.Count) -join ',')) { $problems.Add("${label}: positions are not 1..$($Arms.Count)") }
            if ((@($unit | ForEach-Object { $_.Arm }) -join '') -ne $unit[0].Permutation) { $problems.Add("${label}: arms do not follow the permutation") }
            $unitSeqs = @($unit | ForEach-Object { [int]$_.Seq })
            if ((($unitSeqs | Measure-Object -Maximum).Maximum - ($unitSeqs | Measure-Object -Minimum).Minimum) -ne $Arms.Count - 1) { $problems.Add("${label}: runs are not adjacent") }
        }
    }
    foreach ($row in $Schedule) {
        if ($Cells -cnotcontains $row.Cell) { $problems.Add("unknown cell '$($row.Cell)'") }
        if ($Arms -cnotcontains $row.Arm) { $problems.Add("unknown arm '$($row.Arm)'") }
    }
    return , $problems.ToArray()
}
