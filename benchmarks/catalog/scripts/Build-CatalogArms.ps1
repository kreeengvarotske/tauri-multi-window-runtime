# Builds release executables and records their provenance without running them.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$TargetDirectory,
    [switch]$Offline
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CatalogManifest.ps1')
$benchRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $benchRoot)
$lock = Join-Path $repoRoot 'Cargo.lock'
$manifest = Join-Path $benchRoot 'src-tauri\Cargo.toml'

function Assert-CleanScenario {
    $status = & git -C $repoRoot status --porcelain
    if ($LASTEXITCODE -ne 0 -or $status) {
        throw 'Build records require a clean scenario checkout. Keep the output directory outside the checkout or under an ignored path.'
    }
}

Assert-CleanScenario
$revision = (& git -C $repoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Could not read the scenario revision.' }
$framework = Get-CatalogFrameworkRevision -ManifestPath $manifest -LockPath $lock
$lockHash = (Get-FileHash -LiteralPath $lock -Algorithm SHA256).Hash
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Choose a new output directory.' }
$null = New-Item -ItemType Directory -Path (Join-Path $OutputDirectory 'bin')
$output = (Resolve-Path -LiteralPath $OutputDirectory).Path
Assert-CleanScenario
$target = if ($TargetDirectory) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TargetDirectory) } else { Join-Path $output 'target' }
$networkArgs = @(if ($Offline) { '--offline' })
$features = [ordered]@{
    A = 'tauri/custom-protocol'
    B = 'tauri/custom-protocol,shared'
    C = 'tauri/custom-protocol,framework'
}

Push-Location $benchRoot
try {
    & npm ci @networkArgs
    if ($LASTEXITCODE -ne 0) { throw 'npm ci failed.' }
    & npm run build
    if ($LASTEXITCODE -ne 0) { throw 'The catalog frontend build failed.' }
}
finally { Pop-Location }

Push-Location $repoRoot
try {
    $artifacts = @(foreach ($arm in $features.Keys) {
        & cargo build --release --locked -p catalog-bench --target-dir $target --features $features[$arm] @networkArgs | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Arm $arm build failed." }
        $name = "arm-$arm.exe"
        $file = Join-Path $output "bin\$name"
        Copy-Item -LiteralPath (Join-Path $target 'release\catalog-bench.exe') -Destination $file
        [ordered]@{
            name = $name
            features = $features[$arm]
            sha256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        }
    })
}
finally { Pop-Location }

Assert-CleanScenario
if ((& git -C $repoRoot rev-parse HEAD).Trim() -ne $revision -or
    (Get-FileHash -LiteralPath $lock -Algorithm SHA256).Hash -ne $lockHash) {
    throw 'The scenario revision or lockfile changed during the build.'
}
$record = [ordered]@{
    kind = 'build-only'
    scenarioRevision = $revision
    frameworkRevision = $framework
    cargoLockSha256 = $lockHash
    rustc = (& rustc -V)
    cargo = (& cargo -V)
    node = (& node -v)
    npm = (& npm -v)
    artifacts = $artifacts
}
$path = Join-Path $output 'build-record.json'
$record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path -Encoding UTF8
Write-Host "Built A, B and C without starting them. Build record: $path"
