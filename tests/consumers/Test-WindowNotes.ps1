#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('\A[0-9a-fA-F]{40}\z')][string]$Revision,
    [string]$OutputParent = [IO.Path]::GetTempPath(),
    [switch]$Desktop
)
$ErrorActionPreference = 'Stop'
$Revision = $Revision.ToLowerInvariant()
$fixture = Join-Path $PSScriptRoot $(if ($Desktop) { 'notes-desktop' } else { 'window-notes' })
$output = Join-Path $OutputParent ('tmwr-notes-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $output 'src')
Write-Host "Consumer evidence directory: $output"
Copy-Item -LiteralPath (Join-Path $fixture 'src/main.rs') -Destination (Join-Path $output 'src/main.rs')
if ($Desktop) {
    foreach ($name in @('build.rs', 'tauri.conf.json', 'capabilities', 'icons', 'ui')) {
        Copy-Item -LiteralPath (Join-Path $fixture $name) -Destination (Join-Path $output $name) -Recurse
    }
}
$manifest = Get-Content (Join-Path $fixture 'Cargo.toml') -Raw
$expectedDependencies = if ($Desktop) { 2 } else { 1 }
if ([regex]::Matches($manifest, 'rev = "[0-9a-f]{40}"').Count -ne $expectedDependencies) { throw 'Unexpected pinned Git dependencies.' }
$manifest = $manifest -replace 'rev = "[0-9a-f]{40}"', ('rev = "' + $Revision + '"')
[IO.File]::WriteAllText((Join-Path $output 'Cargo.toml'), $manifest, [Text.UTF8Encoding]::new($false))
Push-Location -LiteralPath $output
try {
    & cargo generate-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'Independent lock resolution failed.' }
    $lock = Get-Content Cargo.lock -Raw
    $source = 'git+https://github.com/kreeengvarotske/tauri-multi-window-runtime.git?rev=' + $Revision + '#' + $Revision
    $packagesToVerify = @('runtime-core', 'shared-runtime')
    if ($Desktop) { $packagesToVerify += 'shared-runtime-tauri' }
    foreach ($name in $packagesToVerify) {
        $pattern = '(?m)^\[\[package\]\]\r?\nname = "' + $name + '"\r?\n(?<fields>(?:(?!^\[\[package\]\])[\s\S])*)'
        $packages = [regex]::Matches($lock, $pattern)
        if ($packages.Count -ne 1 -or $packages[0].Groups['fields'].Value -notmatch ('(?m)^source = "' + [regex]::Escape($source) + '"\r?$')) { throw "Wrong public Git identity for $name." }
    }
    if ($Desktop) {
        & cargo build --locked --target-dir (Join-Path $output 'target')
        if ($LASTEXITCODE -ne 0) { throw 'Desktop consumer build failed.' }
        $report = Join-Path $output 'native-report.json'
        $binary = Join-Path $output ('target/debug/tmwr-notes-desktop-consumer' + $(if ($IsWindows) { '.exe' } else { '' }))
        if ($IsWindows) {
            $previousProfile = $env:WEBVIEW2_USER_DATA_FOLDER
            try {
                $env:WEBVIEW2_USER_DATA_FOLDER = Join-Path $output 'webview-profile'
                $process = Start-Process -FilePath $binary -ArgumentList ('"{0}"' -f $report) -PassThru -WindowStyle Hidden
                $null = $process.Handle
                if (-not $process.WaitForExit(120000)) { Stop-Process -InputObject $process -ErrorAction SilentlyContinue; throw 'Notes desktop timeout.' }
                if ($process.ExitCode -ne 0) { throw 'Notes desktop exited unsuccessfully.' }
            } finally { $env:WEBVIEW2_USER_DATA_FOLDER = $previousProfile }
        } else {
            & timeout 120 xvfb-run -a $binary $report
            if ($LASTEXITCODE -ne 0) { throw 'Notes desktop exited unsuccessfully.' }
        }
        $native = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
        $native | ConvertTo-Json | Write-Host
        if ($native.passed -ne $true -or $native.refusedAfterExit -ne $true -or $native.cacheEntriesAfterExit -ne 0) { throw 'Notes native assertions failed.' }
    } else {
        & cargo run --locked --target-dir (Join-Path $output 'target')
        if ($LASTEXITCODE -ne 0) { throw 'Independent notes consumer failed.' }
    }
    [ordered]@{revision=$Revision;directory=$output;passed=$true;backendOnly=(-not $Desktop);cargoLockSha256=(Get-FileHash Cargo.lock).Hash;rustc=(& rustc -V);completedAt=[DateTimeOffset]::UtcNow.ToString('o')} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'consumer-result.json')
    Write-Host "Consumer evidence retained: $output"
} finally { Pop-Location }
