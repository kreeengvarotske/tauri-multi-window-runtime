[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('\A[0-9a-fA-F]{40}\z')][string]$Revision,
    [string]$OutputParent = [IO.Path]::GetTempPath()
)
$ErrorActionPreference = 'Stop'
$Revision = $Revision.ToLowerInvariant()
$fixture = Join-Path $PSScriptRoot 'window-notes'
$output = Join-Path $OutputParent ('tmwr-notes-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $output 'src')
Copy-Item -LiteralPath (Join-Path $fixture 'src/main.rs') -Destination (Join-Path $output 'src/main.rs')
$manifest = Get-Content (Join-Path $fixture 'Cargo.toml') -Raw
if ([regex]::Matches($manifest, 'rev = "[0-9a-f]{40}"').Count -ne 1) { throw 'Expected one pinned Git dependency.' }
$manifest = $manifest -replace 'rev = "[0-9a-f]{40}"', ('rev = "' + $Revision + '"')
[IO.File]::WriteAllText((Join-Path $output 'Cargo.toml'), $manifest, [Text.UTF8Encoding]::new($false))
Push-Location -LiteralPath $output
try {
    & cargo generate-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'Independent lock resolution failed.' }
    $lock = Get-Content Cargo.lock -Raw
    $source = 'git+https://github.com/kreeengvarotske/tauri-multi-window-runtime.git?rev=' + $Revision + '#' + $Revision
    foreach ($name in @('runtime-core', 'shared-runtime')) {
        $pattern = '(?m)^\[\[package\]\]\r?\nname = "' + $name + '"\r?\n(?<fields>(?:(?!^\[\[package\]\])[\s\S])*)'
        $packages = [regex]::Matches($lock, $pattern)
        if ($packages.Count -ne 1 -or $packages[0].Groups['fields'].Value -notmatch ('(?m)^source = "' + [regex]::Escape($source) + '"\r?$')) { throw "Wrong public Git identity for $name." }
    }
    & cargo run --locked --target-dir (Join-Path $output 'target')
    if ($LASTEXITCODE -ne 0) { throw 'Independent notes consumer failed.' }
    [ordered]@{revision=$Revision;directory=$output;passed=$true;backendOnly=$true;cargoLockSha256=(Get-FileHash Cargo.lock).Hash;rustc=(& rustc -V);completedAt=[DateTimeOffset]::UtcNow.ToString('o')} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'consumer-result.json')
    Write-Host "Consumer evidence retained: $output"
} finally { Pop-Location }
