<#
.SYNOPSIS
Pilot preparation without starting any app: a 72-run dry run of
Run-CatalogTriplets.ps1 -Phase Pilot, the manifest freeze, separate output
directories, and the refusal of a run whose manifest, SHA-256 or
configuration differs from the frozen one (protocol §10a).

.DESCRIPTION
Windows only (the runner reads the OS, CPU and WebView2 version), in Windows
PowerShell 5.1 and PowerShell 7; the runner is started in the same edition
as this script. The arm executables are three small text files named
arm-A.exe, arm-B.exe and arm-C.exe, and the monitor is a stub with the
parameters of the #43 monitor that writes a marker file if it is ever
started. Neither can run an app, and the test also checks that nothing was
started: no runs.log, an empty runs\ directory, no monitor marker.

Everything is written to a new directory (-OutputDirectory, or a temporary
one that is removed at the end). Exits 1 on any failure.
#>
[CmdletBinding()]
param([string]$OutputDirectory)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CatalogSchedule.ps1')
. (Join-Path $PSScriptRoot 'CatalogManifest.ps1')
$failures = New-Object System.Collections.Generic.List[string]
$runner = Join-Path $PSScriptRoot 'Run-CatalogTriplets.ps1'
$hostExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$pilotCells = @('N2D0', 'N2D16', 'N2D64', 'N4D64')

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if (-not $Condition) { $failures.Add("${Name}: $Detail") } else { Write-Host "ok   $Name" }
}

function Invoke-Native {
    # A native command whose stderr must not stop this script.
    param([string]$File, [string[]]$Arguments)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $text = (& $File @Arguments 2>&1 | Out-String) } finally { $ErrorActionPreference = $saved }
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $text }
}

function Invoke-DryRun {
    # The runner in its own process, as on the PC; a refusal is a non-zero exit.
    # -Settings overrides the pilot defaults below; -Extra adds parameters.
    param([string]$Output, [hashtable]$Settings = @{}, [string[]]$Extra = @(), [string]$From, [switch]$NoDryRun)
    $values = [ordered]@{ Phase = 'Pilot'; Triplets = '6'; ScheduleSeed = '1'; DataSeed = '1' }
    foreach ($key in $Settings.Keys) { $values[$key] = [string]$Settings[$key] }
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner,
        '-ExecutablesFrom', $From, '-MonitorScript', $monitor, '-OutputDirectory', $Output)
    foreach ($key in $values.Keys) { $arguments += @("-$key", $values[$key]) }
    if (-not $NoDryRun) { $arguments += '-DryRun' }
    $result = Invoke-Native -File $hostExe -Arguments ($arguments + $Extra)
    # Windows PowerShell may wrap a long error at the console width; compare without whitespace.
    $result | Add-Member -NotePropertyName Flat -NotePropertyValue ($result.Output -replace '\s', '')
    $result
}

function Test-Says {
    param([object]$Result, [string]$Text)
    $Result.Flat -like ('*' + ($Text -replace '\s', '') + '*')
}

function Test-NothingStarted {
    param([string]$Name, [string]$Directory)
    $runs = Join-Path $Directory 'runs'
    Assert-True "${Name}: no runs.log" (-not (Test-Path -LiteralPath (Join-Path $Directory 'runs.log')))
    Assert-True "${Name}: runs\ is empty" (-not (Test-Path -LiteralPath $runs) -or @(Get-ChildItem -LiteralPath $runs -Force).Count -eq 0)
    Assert-True "${Name}: the monitor was never started" (-not (Test-Path -LiteralPath $monitorMarker))
}

function Test-Refused {
    # A refused invocation stops before writing configuration, schedule or manifest.
    param([string]$Name, [object]$Result, [string]$Directory, [string]$Expected)
    Assert-True "${Name}: refused (non-zero exit)" ($Result.ExitCode -ne 0) "exit $($Result.ExitCode)"
    Assert-True "${Name}: says why" (Test-Says $Result $Expected) "expected '$Expected' in: $($Result.Output.Trim())"
    foreach ($file in @('configuration.json', 'schedule.csv', 'manifest.json')) {
        Assert-True "${Name}: no $file written" (-not (Test-Path -LiteralPath (Join-Path $Directory $file)))
    }
    Test-NothingStarted -Name $Name -Directory $Directory
}

$keep = [bool]$OutputDirectory
$root = if ($keep) { $OutputDirectory } else { Join-Path ([System.IO.Path]::GetTempPath()) ("tmwr-pilot-dryrun-" + [guid]::NewGuid().ToString('N')) }
if (Test-Path -LiteralPath $root) { throw "$root exists; give a new -OutputDirectory." }
New-Item -ItemType Directory -Path $root | Out-Null
$root = (Resolve-Path -LiteralPath $root).Path
try {
    # Stand-in executables: text files, never started.
    $from = Join-Path $root 'executables'
    New-Item -ItemType Directory -Path (Join-Path $from 'bin') | Out-Null
    foreach ($arm in 'A', 'B', 'C') { Set-Content -LiteralPath (Join-Path $from "bin\arm-$arm.exe") -Value "stand-in for arm $arm; not an executable" -Encoding ASCII }

    # Stub monitor in its own git repository, so monitorGitHead is a real SHA.
    $monitorDirectory = Join-Path $root 'monitor'
    New-Item -ItemType Directory -Path $monitorDirectory | Out-Null
    $monitor = Join-Path $monitorDirectory 'Measure-ProcessTree.ps1'
    $monitorMarker = Join-Path $root 'MONITOR-WAS-STARTED'
    @(
        'param([int]$RootPid, [string]$OutputPath, [double]$IntervalSeconds, [int]$MaxSamples, [string]$StopFile, [string]$UnitCheckRequireChildName)',
        "Set-Content -LiteralPath '$monitorMarker' -Value 'started'",
        'exit 1'
    ) | Set-Content -LiteralPath $monitor -Encoding ASCII
    $git = @('-C', $monitorDirectory, '-c', 'user.name=dry-run test', '-c', 'user.email=dry-run@example.invalid', '-c', 'commit.gpgsign=false')
    foreach ($step in @(@('init', '-q'), @('add', 'Measure-ProcessTree.ps1'), @('commit', '-q', '-m', 'stub monitor'))) {
        $result = Invoke-Native -File 'git' -Arguments ($git + $step)
        if ($result.ExitCode -ne 0) { throw "git $($step -join ' ') failed: $($result.Output)" }
    }

    # --- 1. The dry run: 72 runs, written and checked, nothing started.
    $dry = Join-Path $root 'pilot-dry-run'
    $result = Invoke-DryRun -Output $dry -From $from
    Assert-True 'dry run: exit 0' ($result.ExitCode -eq 0) $result.Output.Trim()
    Assert-True 'dry run: reports that no app was started' (Test-Says $result 'No app was started.') $result.Output.Trim()
    foreach ($file in @('configuration.json', 'schedule.csv', 'manifest.json', 'README.md')) {
        Assert-True "dry run: $file written" (Test-Path -LiteralPath (Join-Path $dry $file))
    }
    Test-NothingStarted -Name 'dry run' -Directory $dry
    $schedule = @(Import-Csv -LiteralPath (Join-Path $dry 'schedule.csv'))
    Assert-True 'dry run: 72 runs scheduled' ($schedule.Count -eq 72) "got $($schedule.Count)"
    $scheduleProblems = @(Test-CatalogSchedule -Schedule $schedule -Cells $pilotCells -Arms @('A', 'B', 'C') -Triplets 6)
    Assert-True 'dry run: schedule.csv is complete and balanced' ($scheduleProblems.Count -eq 0) ($scheduleProblems -join '; ')
    $expected = New-CatalogSchedule -Cells $pilotCells -Arms @('A', 'B', 'C') -Triplets 6 -Seed 1 -DataSeed 1
    Assert-True 'dry run: schedule.csv is the schedule of these seeds' ((Get-CatalogScheduleSha256 -Schedule $schedule) -eq (Get-CatalogScheduleSha256 -Schedule $expected))
    $configuration = Get-Content -LiteralPath (Join-Path $dry 'configuration.json') -Raw | ConvertFrom-Json
    Assert-True 'dry run: configuration says Pilot, dry run, job CPU' ($configuration.phase -eq 'Pilot' -and $configuration.dryRun -eq $true -and $configuration.cpuSource -eq 'job')
    $manifest = Get-Content -LiteralPath (Join-Path $dry 'manifest.json') -Raw | ConvertFrom-Json
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    $cargoLock = Join-Path $repoRoot 'Cargo.lock'
    Assert-True 'dry run records the preview framework SHA' ($manifest.frameworkGitRevision -eq '2dac921fcccde1bbadd86da16dbb3136d00341da')
    Assert-True 'dry run freezes the Cargo lockfile hash' ($manifest.cargoLockSha256 -eq (Get-FileHash -LiteralPath $cargoLock -Algorithm SHA256).Hash)
    $invalidLock = Join-Path $root 'wrong-pin.lock'
    (Get-Content -LiteralPath $cargoLock -Raw).Replace($manifest.frameworkGitRevision, ('0' * 40)) |
        Set-Content -LiteralPath $invalidLock -Encoding UTF8
    $pinRejected = $false
    try {
        $null = Get-CatalogFrameworkRevision -ManifestPath (Join-Path $PSScriptRoot '..\src-tauri\Cargo.toml') -LockPath $invalidLock
    } catch {
        $pinRejected = $_.Exception.Message -like '*does not match Cargo.lock*'
    }
    Assert-True 'a lockfile pinned to a different revision is rejected' $pinRejected
    Assert-True 'dry run: manifest has 72 runs and the schedule content hash' ($manifest.runs -eq 72 -and $manifest.scheduleContentSha256 -eq (Get-CatalogScheduleSha256 -Schedule $schedule))
    Assert-True 'dry run: manifest has the phase, cells and triplets' ($manifest.phase -eq 'Pilot' -and (@($manifest.cells) -join ',') -eq ($pilotCells -join ',') -and $manifest.triplets -eq 6)
    Assert-True 'dry run: manifest has the monitor SHA and its git head' ($manifest.monitorSha256 -eq (Get-FileHash -LiteralPath $monitor -Algorithm SHA256).Hash -and $manifest.monitorGitHead -match '^[0-9a-f]{40}$')
    Assert-True 'dry run: manifest has every executable SHA' ((@('A', 'B', 'C') | Where-Object { $manifest.executables.$_.sha256 -eq (Get-FileHash -LiteralPath (Join-Path $from "bin\arm-$_.exe") -Algorithm SHA256).Hash }).Count -eq 3)
    Assert-True 'dry run: manifest has the job limits and the script hashes' ($null -ne $manifest.jobLimits -and $manifest.runScriptSha256 -match '^[0-9A-F]{64}$' -and $manifest.manifestScriptSha256 -match '^[0-9A-F]{64}$')

    # --- 2. Freeze: a copy of manifest.json outside any results directory, and its SHA-256.
    $frozenDirectory = Join-Path $root 'frozen'
    New-Item -ItemType Directory -Path $frozenDirectory | Out-Null
    $frozen = Join-Path $frozenDirectory 'manifest.json'
    Copy-Item -LiteralPath (Join-Path $dry 'manifest.json') -Destination $frozen
    $frozenSha = (Get-FileHash -LiteralPath $frozen -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True 'freeze: the dry run printed the manifest SHA-256' (Test-Says $result $frozenSha)
    $freeze = @('-Manifest', $frozen, '-ManifestSha256', $frozenSha)

    # --- 3. The same invocation against the frozen manifest passes, in a new directory.
    $same = Join-Path $root 'pilot-same'
    $result = Invoke-DryRun -Output $same -From $from -Extra $freeze
    Assert-True 'frozen, unchanged: passes' ($result.ExitCode -eq 0) $result.Output.Trim()
    if ($result.ExitCode -eq 0) {
        $sameConfiguration = Get-Content -LiteralPath (Join-Path $same 'configuration.json') -Raw | ConvertFrom-Json
        Assert-True 'frozen, unchanged: configuration records the frozen manifest SHA-256' ($sameConfiguration.frozenManifestSha256 -eq $frozenSha)
        Assert-True 'frozen, unchanged: the new manifest.json is byte-identical' ((Get-FileHash -LiteralPath (Join-Path $same 'manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant() -eq $frozenSha)
        Test-NothingStarted -Name 'frozen, unchanged' -Directory $same
    }

    # --- 4. Every difference from the frozen manifest is refused before anything is written.
    $cases = @(
        @{ Name = 'another schedule seed'; Settings = @{ ScheduleSeed = 2 }; Expected = "scheduleSeed: frozen '1', now '2'" },
        @{ Name = 'another data seed'; Settings = @{ DataSeed = 2 }; Expected = "dataSeed: frozen '1', now '2'" },
        @{ Name = 'another load phase'; Settings = @{ LoadSeconds = 121 }; Expected = "loadSeconds: frozen '120', now '121'" },
        @{ Name = 'another warm-up'; Settings = @{ WarmupSeconds = 31 }; Expected = "warmupSeconds: frozen '30', now '31'" },
        @{ Name = 'another pause'; Settings = @{ PauseSeconds = 31 }; Expected = "pauseSeconds: frozen '30', now '31'" },
        @{ Name = 'another step interval'; Settings = @{ StepIntervalMs = 400 }; Expected = "stepIntervalMs: frozen '500', now '400'" },
        @{ Name = 'five triplets'; Settings = @{ Triplets = 5 }; Expected = "triplets: frozen '6', now '5'" },
        @{ Name = 'another phase'; Settings = @{ Phase = 'Smoke' }; Expected = "phase: frozen 'Pilot', now 'Smoke'" }
    )
    foreach ($case in $cases) {
        $directory = Join-Path $root ('refused-' + ($case.Name -replace '[^a-z0-9]+', '-'))
        $result = Invoke-DryRun -Output $directory -From $from -Settings $case.Settings -Extra $freeze
        Test-Refused -Name "frozen, $($case.Name)" -Result $result -Directory $directory -Expected $case.Expected
        Assert-True "frozen, $($case.Name): names the difference from the frozen manifest" (Test-Says $result 'differs from the frozen manifest')
    }

    # An executable that differs by one byte.
    $otherFrom = Join-Path $root 'executables-other'
    Copy-Item -LiteralPath $from -Destination $otherFrom -Recurse
    Add-Content -LiteralPath (Join-Path $otherFrom 'bin\arm-C.exe') -Value 'x' -Encoding ASCII
    $directory = Join-Path $root 'refused-other-executable'
    $result = Invoke-DryRun -Output $directory -From $otherFrom -Extra $freeze
    Test-Refused -Name 'frozen, another arm C executable' -Result $result -Directory $directory -Expected 'executables.C.sha256: frozen'

    # A monitor with one more commit (same file content, another git head).
    $result = Invoke-Native -File 'git' -Arguments ($git + @('commit', '-q', '--allow-empty', '-m', 'another head'))
    if ($result.ExitCode -ne 0) { throw "git commit failed: $($result.Output)" }
    $directory = Join-Path $root 'refused-monitor-head'
    $result = Invoke-DryRun -Output $directory -From $from -Extra $freeze
    Test-Refused -Name 'frozen, another monitor git head' -Result $result -Directory $directory -Expected 'monitorGitHead: frozen'
    $result = Invoke-Native -File 'git' -Arguments ($git + @('reset', '-q', '--hard', 'HEAD~1'))
    if ($result.ExitCode -ne 0) { throw "git reset failed: $($result.Output)" }

    # A frozen manifest edited after the freeze: its SHA-256 no longer matches.
    $edited = Join-Path $frozenDirectory 'manifest-edited.json'
    $editedText = (Get-Content -LiteralPath $frozen -Raw) -replace '("loadSeconds":\s*)120', '${1}121'
    Assert-True 'frozen, edited manifest: the edit changed the file' ($editedText -ne (Get-Content -LiteralPath $frozen -Raw))
    [System.IO.File]::WriteAllText($edited, $editedText)
    $directory = Join-Path $root 'refused-edited-manifest'
    $result = Invoke-DryRun -Output $directory -From $from -Extra @('-Manifest', $edited, '-ManifestSha256', $frozenSha)
    Test-Refused -Name 'frozen, manifest edited after the freeze' -Result $result -Directory $directory -Expected 'does not match'

    $wrongSha = $(if ($frozenSha[0] -eq '0') { '1' } else { '0' }) + $frozenSha.Substring(1)
    $directory = Join-Path $root 'refused-wrong-sha'
    $result = Invoke-DryRun -Output $directory -From $from -Extra @('-Manifest', $frozen, '-ManifestSha256', $wrongSha)
    Test-Refused -Name 'frozen, wrong SHA-256' -Result $result -Directory $directory -Expected 'does not match'

    $directory = Join-Path $root 'refused-malformed-sha'
    $result = Invoke-DryRun -Output $directory -From $from -Extra @('-Manifest', $frozen, '-ManifestSha256', 'abc')
    Test-Refused -Name 'frozen, malformed SHA-256' -Result $result -Directory $directory -Expected 'not a 64-digit hex value'

    $directory = Join-Path $root 'refused-missing-manifest'
    $result = Invoke-DryRun -Output $directory -From $from -Extra @('-Manifest', (Join-Path $frozenDirectory 'absent.json'), '-ManifestSha256', $frozenSha)
    Test-Refused -Name 'frozen, missing manifest file' -Result $result -Directory $directory -Expected 'not found'

    $directory = Join-Path $root 'refused-manifest-without-sha'
    $result = Invoke-DryRun -Output $directory -From $from -Extra @('-Manifest', $frozen)
    Test-Refused -Name 'frozen, -Manifest without -ManifestSha256' -Result $result -Directory $directory -Expected 'go together'

    # --- 5. Separate output directories.
    $result = Invoke-DryRun -Output $dry -From $from
    Assert-True 'directories: a used results directory is refused' ($result.ExitCode -ne 0 -and (Test-Says $result 'already has configuration.json')) $result.Output.Trim()
    $nested = Join-Path $dry 'nested'
    $result = Invoke-DryRun -Output $nested -From $from
    Test-Refused -Name 'directories: a directory inside another results directory' -Result $result -Directory $nested -Expected 'inside another results directory'
    Assert-True 'directories: the first dry run is unchanged' ((Get-FileHash -LiteralPath (Join-Path $dry 'manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant() -eq $frozenSha)

    # --- 6. The pilot itself still refuses to start.
    $directory = Join-Path $root 'refused-pilot'
    $result = Invoke-DryRun -Output $directory -From $from -NoDryRun -Extra $freeze
    Test-Refused -Name 'pilot without -DryRun, even with a matching manifest' -Result $result -Directory $directory -Expected 'The pilot runs only after'
}
finally {
    if (-not $keep) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "$($failures.Count) failure(s):"
    $failures | ForEach-Object { Write-Host "FAIL $_" }
    exit 1
}
Write-Host 'All pilot dry-run checks passed.'
