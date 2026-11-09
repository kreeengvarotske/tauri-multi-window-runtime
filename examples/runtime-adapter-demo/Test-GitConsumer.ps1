[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('\A[0-9a-fA-F]{40}\z')]
    [string]$Revision,

    [string]$OutputParent = [IO.Path]::GetTempPath(),

    [switch]$Offline,

    [switch]$RequireMatchingRevision
)

$ErrorActionPreference = 'Stop'
$source = 'https://github.com/kreeengvarotske/tauri-multi-window-runtime.git'
$root = Join-Path $PSScriptRoot '../..'
$demoRevision = & git -C $root rev-parse --verify HEAD
if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the demo revision.' }
if ($RequireMatchingRevision -and $demoRevision -ne $Revision) {
    throw "Release verification requires matching demo and dependency revisions. Demo: $demoRevision. Dependencies: $Revision."
}
$Revision = $Revision.ToLowerInvariant()
$output = Join-Path $OutputParent ('tmwr-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
$null = New-Item -ItemType Directory -Path $output
$output = (Resolve-Path -LiteralPath $output).Path
$archive = Join-Path $output 'demo.tar'
Write-Host "Consumer evidence directory: $output"

& git -C $root archive --format=tar "--output=$archive" $demoRevision -- examples/runtime-adapter-demo
if ($LASTEXITCODE -ne 0) { throw 'Could not archive the tracked demo files.' }
& tar -xf $archive -C $output --strip-components 2
if ($LASTEXITCODE -ne 0) { throw 'Could not extract the demo.' }

$manifest = Join-Path $output 'Cargo.toml'
$content = Get-Content -LiteralPath $manifest -Raw
foreach ($crate in @('shared-runtime', 'shared-runtime-tauri')) {
    $pattern = '(?m)^' + [regex]::Escape($crate) + ' = \{ path = "[^"]+" \}\r?$'
    if ([regex]::Matches($content, $pattern).Count -ne 1) {
        throw "Expected one workspace path dependency for $crate."
    }
    $content = $content -replace $pattern, ('{0} = {{ git = "{1}", rev = "{2}" }}' -f $crate, $source, $Revision)
}
[IO.File]::WriteAllText($manifest, "[workspace]`n`n$content", [Text.UTF8Encoding]::new($false))

$networkArgs = @()
if ($Offline) { $networkArgs += '--offline' }
$targetDir = Join-Path $output 'target'
$evidence = [ordered]@{
    demoRevision = $demoRevision
    dependencyRevision = $Revision
    dependencyRepository = $source
    offline = [bool]$Offline
}
$evidence | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'revisions.json') -Encoding UTF8
Push-Location -LiteralPath $output
try {
    & cargo generate-lockfile @networkArgs
    if ($LASTEXITCODE -ne 0) { throw 'Could not resolve consumer dependencies.' }
    $lock = Get-Content -LiteralPath 'Cargo.lock' -Raw
    $expectedSource = 'git+{0}?rev={1}#{1}' -f $source, $Revision
    foreach ($crate in @('runtime-core', 'shared-runtime', 'shared-runtime-tauri')) {
        $packagePattern = '(?m)^\[\[package\]\]\r?\nname = "' + [regex]::Escape($crate) + '"\r?\n(?<fields>(?:(?!^\[\[package\]\])[\s\S])*)'
        $package = [regex]::Matches($lock, $packagePattern)
        if ($package.Count -ne 1 -or
            $package[0].Groups['fields'].Value -notmatch ('(?m)^source = "' + [regex]::Escape($expectedSource) + '"\r?$')) {
            throw "Expected exactly one $crate package pinned to $Revision in Cargo.lock."
        }
    }
    & cargo build --release --locked --target-dir $targetDir @networkArgs
    if ($LASTEXITCODE -ne 0) { throw 'Consumer Release build failed.' }

    $exe = Join-Path $targetDir 'release/runtime-adapter-demo.exe'
    $report = Join-Path $output 'self-test.json'
    $process = Start-Process -FilePath $exe -ArgumentList @('--self-test', ('"{0}"' -f $report)) -PassThru -WindowStyle Hidden
    if (-not $process.WaitForExit(120000)) {
        Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
        throw 'Consumer self-test timed out.'
    }
    if ($process.ExitCode -ne 0) { throw "Consumer self-test exited with code $($process.ExitCode)." }
    $result = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    if ($result.passed -isnot [bool] -or -not $result.passed) {
        throw "Consumer self-test failed. Report: $report"
    }
    if ($RequireMatchingRevision -and
        ($result.catalogExecutions -ne 1 -or $result.catalogCacheEntries -ne 1 -or
         $result.refusedAfterExit -ne $true -or $result.cachesEmptyAfterExit -ne $true)) {
        throw "Consumer self-test is missing release evidence. Report: $report"
    }
    Write-Host "Consumer self-test passed. Report: $report"
}
finally {
    Pop-Location
}
