# Tauri shared runtime for Windows

This example shows two Tauri windows reading from one Rust catalog. Each window requests a bounded page over IPC. The runtime keeps the catalog in Rust, and each window receives only its requested page. The example also exercises per-window state and cleanup when a window closes.

## Build and run on Windows

Use a Windows desktop session with the Tauri v2 Windows build prerequisites,
including the MSVC C++ build tools and WebView2 Runtime, and a Rust toolchain
compatible with the repository's lockfile. Run these commands from the
repository root on a reviewed checkout containing the adapter and its demo.

```powershell
cargo build --release --locked -p runtime-adapter-demo
if ($LASTEXITCODE -ne 0) { throw 'Demo build failed' }
$demo = Join-Path $PWD 'target\release\runtime-adapter-demo.exe'
& $demo
```

Close the interactive demo before running its self-test. Two real WebViews request
different pages over IPC. The report records one catalog execution and one cached
catalog entry, and checks window-specific access, cleanup, and shutdown. Every
attempt below gets a fresh evidence directory and its own WebView2 profile.

The lifecycle check also keeps an old window's view queued while the real
window is destroyed and reopened under the same label. A passing report
requires `queuedViewSeparated` and `queuedViewCacheStable`: the old call
must not read or replace the reopened window's cached note. This is a
functional check, not a measurement of application memory.

The demo explicitly allows four active projections and 32 waiting views.
Its native check fills that queue, verifies that the next adapter call
returns `OVERLOADED`, cancels the waiters, and checks that the queue and
active slots are empty after shutdown. A passing report requires
`projectionQueueBounded` and `projectionQueueEmptyAfterExit` too.

```powershell
$evidence = Join-Path ([IO.Path]::GetTempPath()) ('tmwr-manual-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $evidence
$report = Join-Path $evidence 'self-test.json'
$previousProfile = $env:WEBVIEW2_USER_DATA_FOLDER
try {
    $env:WEBVIEW2_USER_DATA_FOLDER = Join-Path $evidence 'webview-profile'
    $run = Start-Process -FilePath $demo -ArgumentList @('--self-test', ('"{0}"' -f $report)) -PassThru -WindowStyle Hidden
    $null = $run.Handle
    if (-not $run.WaitForExit(120000)) {
        Stop-Process -InputObject $run -ErrorAction SilentlyContinue
        throw "Self-test timed out. Evidence: $evidence"
    }
    if ($run.ExitCode -ne 0) { throw "Self-test exited with code $($run.ExitCode). Evidence: $evidence" }
    $result = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    if ($result.passed -isnot [bool] -or -not $result.passed) { throw "Self-test failed. Evidence: $evidence" }
    $result
}
finally {
    if ($null -eq $previousProfile) {
        Remove-Item Env:WEBVIEW2_USER_DATA_FOLDER -ErrorAction SilentlyContinue
    } else {
        $env:WEBVIEW2_USER_DATA_FOLDER = $previousProfile
    }
    Write-Host "Retained self-test evidence and WebView profile: $evidence"
}
```

This manual launcher checks functional behavior. `Start-Process` and the demo's
exit code do not establish ownership or cleanup of all WebView descendants.
The timeout stops only the launched demo; it does not kill processes by name.
Retain the report and profile for inspection. Release verification also needs
process accounting and cleanup evidence from a launcher that owns the process
tree through a Windows Job Object; see the
[release review](../../docs/stable-release-qualification.md).

## Integrate the pattern

1. Build one shared runtime at application startup and register the Rust operations and bounded views that your app needs.
2. Install the adapter plugin on your Tauri builder. Expose each view through a typed command and grant it only to the appropriate windows in your Tauri capabilities.
3. Derive caller identity with `shared_runtime_tauri::caller(&window)` from the
   window Tauri injects. Never accept a frontend window label as caller identity.
   Charge the response budget before copying each item into a page, then decode
   its bounded response in the frontend.

See the [adapter guide](../../crates/shared-runtime-tauri/README.md), the
[Rust integration](src/lib.rs), the [frontend example](ui/main.js), and the
[three runnable runtime recipes](../../docs/recipes.md).

The [build script](build.rs) registers application commands through
`tauri_build::AppManifest::commands`. Tauri generates each command's permissions;
[capabilities/default.json](capabilities/default.json) grants catalog pages and
per-window notes to the demo windows, while
[capabilities/main.json](capabilities/main.json) grants stats only to `main`.
Your application must register and grant its own commands in the same way.

The demo chooses four active operations, 64 queued operations, four active
projections, 32 queued projections, a ten-second default deadline, a two-second
shutdown grace, and a one-second adapter abort wait. Its runtime cache budget is
16 MiB, with 8 MiB reserved for the catalog and 64 KiB for window notes. A catalog
page has at most 100 items and 32 KiB of charged response data; its command accepts
at most 256 request bytes and serializes at most 64 KiB. These are demo choices,
not global defaults. Set and measure limits for your application's workload.

Runtime configuration requires `max_queued_projections` in every
`RuntimeConfig` literal. Pick an application-specific limit; the demo's
32 positions are an example, not a framework default. The [queue guide](../../docs/projection-queue-review.md)
describes overload handling, counters and the limits of this protection.

### Use the runtime from another project

For application use, prefer a verified published Git release. Once the
[Windows release](https://github.com/kreeengvarotske/tauri-multi-window-runtime/releases/tag/v0.1.0)
is published, verify that its tag resolves to the qualified commit stated in the
Release text before using these entries under `[dependencies]`:

```toml
shared-runtime = { git = "https://github.com/kreeengvarotske/tauri-multi-window-runtime.git", tag = "v0.1.0" }
shared-runtime-tauri = { git = "https://github.com/kreeengvarotske/tauri-multi-window-runtime.git", tag = "v0.1.0" }
```

Check the remote tag identity with:

```powershell
git ls-remote https://github.com/kreeengvarotske/tauri-multi-window-runtime.git 'refs/tags/v0.1.0' 'refs/tags/v0.1.0^{}'
```

For an annotated tag, compare the SHA on the `^{}` line; for a lightweight tag,
compare the tag line's SHA. It must match the Release's qualified full commit
SHA. A missing release or tag is not a verified release installation. Keep both
dependencies on the same tag and check that their resolved Git sources in your
application's `Cargo.lock` point to that commit.

For development, or evaluation before a release is published, use one reviewed
Git commit available from the repository. From that reviewed checkout, resolve
the full revision and print the two dependency entries:

```powershell
$sdkRevision = (& git rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $sdkRevision -notmatch '\A[0-9a-fA-F]{40}\z') { throw 'Could not resolve the reviewed SDK revision' }
@"
shared-runtime = { git = "https://github.com/kreeengvarotske/tauri-multi-window-runtime.git", rev = "$sdkRevision" }
shared-runtime-tauri = { git = "https://github.com/kreeengvarotske/tauri-multi-window-runtime.git", rev = "$sdkRevision" }
"@
```

Put the printed entries under `[dependencies]` in the Cargo manifest that builds
your Tauri backend. Both must use the same full SHA. Keep the application's Tauri
v2 dependency and build configuration. Commit its resolved `Cargo.lock`, check
that the runtime Git sources resolve to the reviewed SHA, and use
`cargo build --locked` for subsequent builds. The first fetch needs repository
access. Uncommitted checkout changes are not included in a Git revision.

The [release review](../../docs/stable-release-qualification.md) records verification
requirements. Evidence for one SHA does not cover a newer commit. No crates.io
or npm registry publication is required for this Git source release.

### Optional frontend command client

The demo already includes a distributed copy of the optional client, so it needs
no npm install or frontend bundler. In your own frontend, install the private
package directory from the same reviewed checkout, for example:

```powershell
npm install 'C:/path/to/reviewed-checkout/packages/runtime-client'
```

A tarball created with `npm pack` in that directory is another local installation
form. The package is private; these instructions do not assume registry
publication. Keep your frontend lockfile and the reviewed checkout revision.

```ts
import { invoke } from '@tauri-apps/api/core';
import { createCommand } from 'tmwr-runtime-client';

interface PageRequest { offset: number; limit: number }
interface Page { total: number; items: { id: number; name: string }[] }

const catalogPage = createCommand<PageRequest, Page>(invoke, 'demo_catalog_page');
const page = await catalogPage({ offset: 0, limit: 10 });
console.log(page.items);
```

`createCommand` sends a plain JSON object, which works through custom-protocol
IPC and the desktop `postMessage` fallback, and decodes the JSON-byte response.
Your Rust app must register and grant the named command. TypeScript interfaces
are application declarations; there is no generated binding or runtime response
schema validation. See the [client guide](../../packages/runtime-client/README.md)
for stable error handling and no-body commands.

### External consumer check

To reproduce the external consumer check from the repository root, run the script below in a Windows desktop session. It extracts the tracked demo from the current Git HEAD, generates an independent lockfile, builds in a fresh directory, and leaves the native self-test report there. If your temporary directory is deeply nested, pass an existing short path via `-OutputParent` to avoid MSVC path length limits.

```powershell
& ./examples/runtime-adapter-demo/Test-GitConsumer.ps1 -Revision (git rev-parse HEAD) -RequireMatchingRevision
```

`-RequireMatchingRevision` requires the tracked demo and dependency SHA to match
and checks the runtime Git sources plus native catalog, queue, lifecycle, and
shutdown assertions. Retain the emitted consumer directory. The script's
functional self-test is separate from owned-job process cleanup evidence. Once
a release tag is published, check out its qualified commit and verify the tag
installation with:

```powershell
& ./examples/runtime-adapter-demo/Test-GitConsumer.ps1 -Revision (git rev-parse HEAD) -Tag v0.1.0 -RequireMatchingRevision
```

The script checks that the remote tag resolves to the expected commit and that
all three runtime Git packages in the consumer lockfile use that tag and SHA.

These checks cover integration behavior, including IPC and window lifecycle.
They do not set a whole-application OS RAM cap or establish RAM/CPU savings.
Types and commands are manually declared. WebView process deduplication,
cross-application sharing, and generated bindings are outside this release.
