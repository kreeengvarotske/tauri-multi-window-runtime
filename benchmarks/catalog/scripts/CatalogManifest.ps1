# Run manifest of scenario M (protocol #33 §10a, pilot freeze; #45 review
# 6693217194). The manifest holds everything a frozen run depends on: the
# phase, the revisions and hashes of the scenario, monitor, protocol and
# scripts, the executables, the cells, arms, triplets, seeds, phase lengths,
# sampling, the CPU source and job limits, the machine, OS and WebView2
# version, and the schedule's content hash. A dry run writes it without
# starting any app; the real run is given the frozen manifest and its SHA-256
# and refuses to start on any difference.
#
# Dot-sourced by Run-CatalogTriplets.ps1 and the tests. Pure functions.

$script:CatalogManifestFields = @(
    'phase', 'machine', 'os', 'webView2', 'gitHead', 'gitDirty', 'monitorGitHead', 'monitorSha256', 'monitorUnitCheckRequireChildName',
    'frameworkGitRevision', 'cargoLockSha256', 'buildRecordSha256',
    'cpuSource', 'jobLimits', 'jobScriptSha256', 'executables', 'sampleIntervalSeconds', 'cells', 'arms', 'triplets', 'scheduleSeed', 'dataSeed',
    'idleBeforeSeconds', 'warmupSeconds', 'loadSeconds', 'idleAfterSeconds', 'pauseSeconds', 'stepIntervalMs',
    'runScriptSha256', 'scheduleScriptSha256', 'summarizeScriptSha256', 'manifestScriptSha256', 'readmeSha256', 'protocolSha256'
)

function Get-CatalogFrameworkRevision {
    param([string]$ManifestPath, [string]$LockPath)
    $source = 'https://github.com/kreeengvarotske/tauri-multi-window-runtime.git'
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw
    $pin = [regex]::Match($manifest, '(?m)^shared-runtime = \{ git = "' + [regex]::Escape($source) + '", rev = "(?<sha>[0-9a-f]{40})", optional = true \}\r?$')
    if (-not $pin.Success) { throw 'Arm C requires an optional shared-runtime Git dependency pinned to a full SHA.' }
    $revision = $pin.Groups['sha'].Value
    $gitSource = [regex]::Escape(('git+{0}?rev={1}#{1}' -f $source, $revision))
    $lock = Get-Content -LiteralPath $LockPath -Raw
    $package = '(?m)^\[\[package\]\]\r?\nname = "shared-runtime"\r?\nversion = "[^"]+"\r?\nsource = "' + $gitSource + '"\r?$'
    if ([regex]::Matches($lock, $package).Count -ne 1) {
        throw "Arm C's shared-runtime Git pin $revision does not match Cargo.lock."
    }
    return $revision
}

function Assert-CatalogBuildRecord {
    param(
        [string]$RecordPath, [string]$BinaryDirectory, [string[]]$Arms,
        [string]$ScenarioRevision, [string]$FrameworkRevision, [string]$CargoLockSha256
    )
    $record = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json
    if ($record.kind -ne 'build-only' -or $record.scenarioRevision -ne $ScenarioRevision -or
        $record.cargoLockSha256 -ne $CargoLockSha256) {
        throw 'The build record does not match the scenario revision and Cargo.lock.'
    }
    if ($Arms -contains 'C' -and $record.frameworkRevision -ne $FrameworkRevision) {
        throw 'The build record does not match the framework Git revision for arm C.'
    }
    foreach ($arm in $Arms) {
        $name = "arm-$arm.exe"
        $entries = @($record.artifacts | Where-Object { $_.name -ceq $name })
        if ($entries.Count -ne 1) { throw "Expected one build record entry for $name." }
        $file = Join-Path $BinaryDirectory $name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or
            (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $entries[0].sha256) {
            throw "The executable $name does not match the build record."
        }
    }
    return (Get-FileHash -LiteralPath $RecordPath -Algorithm SHA256).Hash
}

function Get-CatalogScheduleSha256 {
    # Hash of the schedule's content (fields in a fixed order, one line per
    # run, LF), so line endings or CSV quoting of a checkout do not change it.
    param([Parameter(Mandatory = $true)][object[]]$Schedule)
    $columns = @('Seq', 'Block', 'Cell', 'Windows', 'DataMib', 'Triplet', 'Position', 'Arm', 'Permutation', 'DataSeed', 'ScheduleSeed', 'Name')
    $lines = @($Schedule | ForEach-Object { $row = $_; ($columns | ForEach-Object { [string]$row.$_ }) -join ',' })
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($lines -join "`n") + "`n")
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}

function New-CatalogManifest {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Configuration,
        [Parameter(Mandatory = $true)][object[]]$Schedule
    )
    $manifest = [ordered]@{ manifestVersion = 1 }
    foreach ($field in $script:CatalogManifestFields) {
        $manifest[$field] = if ($Configuration.Contains($field)) { $Configuration[$field] } else { $null }
    }
    $manifest['runs'] = $Schedule.Count
    $manifest['scheduleContentSha256'] = Get-CatalogScheduleSha256 -Schedule $Schedule
    $manifest
}

function ConvertTo-CatalogFlatMap {
    # Nested dictionaries, objects and arrays as "a.b[0]" -> invariant text.
    param([AllowNull()][object]$Value, [string]$Prefix = '')
    $map = [ordered]@{}
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if ($null -eq $Value) { $map[$Prefix] = '<null>'; return $map }
    if ($Value -is [string]) { $map[$Prefix] = $Value; return $map }
    if ($Value -is [bool]) { $map[$Prefix] = $Value.ToString().ToLowerInvariant(); return $map }
    if ($Value -is [System.ValueType]) { $map[$Prefix] = ([System.IConvertible]$Value).ToString($culture); return $map }
    $children = $null
    if ($Value -is [System.Collections.IDictionary]) { $children = @($Value.Keys | ForEach-Object { , @([string]$_, $Value[$_]) }) }
    elseif ($Value -is [System.Collections.IEnumerable]) {
        $i = 0
        $children = @($Value | ForEach-Object { , @("[$i]", $_); $i++ })
        if ($children.Count -eq 0) { $map[$Prefix] = '<empty>'; return $map }
        foreach ($child in $children) { foreach ($entry in (ConvertTo-CatalogFlatMap -Value $child[1] -Prefix "$Prefix$($child[0])").GetEnumerator()) { $map[$entry.Key] = $entry.Value } }
        return $map
    }
    else { $children = @($Value.PSObject.Properties | ForEach-Object { , @($_.Name, $_.Value) }) }
    foreach ($child in $children) {
        $key = if ($Prefix -eq '') { $child[0] } else { "$Prefix.$($child[0])" }
        foreach ($entry in (ConvertTo-CatalogFlatMap -Value $child[1] -Prefix $key).GetEnumerator()) { $map[$entry.Key] = $entry.Value }
    }
    $map
}

function Compare-CatalogManifest {
    # Every field that differs, is missing or is extra, as text; empty = same.
    param([Parameter(Mandatory = $true)][object]$Frozen, [Parameter(Mandatory = $true)][object]$Current)
    $a = ConvertTo-CatalogFlatMap -Value $Frozen
    $b = ConvertTo-CatalogFlatMap -Value $Current
    $differences = New-Object System.Collections.Generic.List[string]
    foreach ($key in $a.Keys) {
        if (-not $b.Contains($key)) { $differences.Add("${key}: frozen '$($a[$key])', now missing") }
        elseif ($a[$key] -cne $b[$key]) { $differences.Add("${key}: frozen '$($a[$key])', now '$($b[$key])'") }
    }
    foreach ($key in $b.Keys) { if (-not $a.Contains($key)) { $differences.Add("${key}: not in the frozen manifest, now '$($b[$key])'") } }
    @($differences)
}

function Assert-CatalogManifest {
    # Stops unless FrozenPath has FrozenSha256 and its content equals Current.
    param(
        [Parameter(Mandatory = $true)][string]$FrozenPath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$FrozenSha256,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Current
    )
    if ($FrozenSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw "The frozen manifest SHA-256 is not a 64-digit hex value ('$FrozenSha256'); nothing was run." }
    if (-not (Test-Path -LiteralPath $FrozenPath -PathType Leaf)) { throw "Frozen manifest '$FrozenPath' not found; nothing was run." }
    $actual = (Get-FileHash -LiteralPath $FrozenPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $FrozenSha256.ToLowerInvariant()) { throw "Frozen manifest SHA-256 $actual does not match $($FrozenSha256.ToLowerInvariant()); nothing was run." }
    $frozen = Get-Content -LiteralPath $FrozenPath -Raw | ConvertFrom-Json
    # The current manifest goes through the same JSON round trip as the frozen file.
    $currentRoundTrip = $Current | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $differences = @(Compare-CatalogManifest -Frozen $frozen -Current $currentRoundTrip)
    if ($differences.Count -gt 0) { throw "The run differs from the frozen manifest; nothing was run: $($differences -join '; ')" }
    $actual
}

function Test-CatalogResultsDirectory {
    # A results directory is used once and never nested in another one, so
    # phases (smoke, pilot, confirmatory) and dry runs stay in separate trees.
    param([Parameter(Mandatory = $true)][string]$Path)
    $problems = New-Object System.Collections.Generic.List[string]
    $full = [System.IO.Path]::GetFullPath($Path)
    if (Test-Path -LiteralPath $full) {
        foreach ($existing in @('configuration.json', 'schedule.csv', 'runs.log', 'manifest.json')) {
            if (Test-Path -LiteralPath (Join-Path $full $existing)) { $problems.Add("$full already has $existing") }
        }
        $runs = Join-Path $full 'runs'
        if ((Test-Path -LiteralPath $runs) -and @(Get-ChildItem -LiteralPath $runs).Count -gt 0) { $problems.Add("$runs is not empty") }
    }
    $parent = Split-Path -Parent $full
    while (-not [string]::IsNullOrEmpty($parent)) {
        if (Test-Path -LiteralPath (Join-Path $parent 'configuration.json')) { $problems.Add("$full is inside another results directory ($parent)") ; break }
        $next = Split-Path -Parent $parent
        if ($next -eq $parent) { break }
        $parent = $next
    }
    @($problems)
}
