# Tauri shared runtime preview

This example shows two Tauri windows reading from one Rust catalog. Each window requests a bounded page over IPC. The runtime keeps the catalog in Rust, and each window receives only its requested page. The example also exercises per-window state and cleanup when a window closes.

## Build and run on Windows

Use a Windows desktop session with the Tauri v2 Windows build prerequisites, including the MSVC C++ build tools and WebView2 Runtime. The adapter stack was tested with Rust and Cargo 1.99.1. Run these commands from the repository root on a checkout containing the adapter and its demo.

```powershell
cargo build --release --locked -p runtime-adapter-demo
if ($LASTEXITCODE -ne 0) { throw 'Demo build failed' }
$demo = Join-Path $PWD 'target\release\runtime-adapter-demo.exe'
& $demo
```

Close the demo before running its self-test. Two real WebViews request different pages over IPC. The report records one catalog execution and one cached catalog entry, and checks window-specific access, cleanup, and shutdown. Use a new report path for each attempt.

```powershell
$report = Join-Path ([IO.Path]::GetTempPath()) "runtime-adapter-demo-$([guid]::NewGuid()).json"
$run = Start-Process -FilePath $demo -ArgumentList @('--self-test', ('"{0}"' -f $report)) -PassThru -WindowStyle Hidden
if (-not $run.WaitForExit(120000)) { Stop-Process -Id $run.Id -ErrorAction SilentlyContinue; throw 'Self-test timed out' }
if ($run.ExitCode -ne 0) { throw "Self-test exited with code $($run.ExitCode). Report path: $report" }
if (-not (Get-Content -LiteralPath $report -Raw | ConvertFrom-Json).passed) { throw "Self-test failed. Report path: $report" }
$report
```

## Integrate the pattern

1. Build one shared runtime at application startup and register the Rust operations and bounded views that your app needs.
2. Install the adapter plugin on your Tauri builder. Expose each view through a typed command and grant it only to the appropriate windows in your Tauri capabilities.
3. Derive caller identity from the injected window. Charge the response budget before copying each item into the page and decode the bounded response in the frontend.

See the [adapter guide](../../crates/shared-runtime-tauri/README.md), the [Rust integration](src/lib.rs), and the [frontend example](ui/main.js).

### Use the preview from another project

Add both crates to the Cargo manifest that builds your Tauri backend. Pin both to the same release tag. Cargo records the tag's commit SHA in your `Cargo.lock`. Check it against the SHA in the [release notes](../../docs/windows-preview-release-notes.md).

```toml
[dependencies]
shared-runtime = { git = "https://github.com/kreeengvarotske/tauri-multi-window-runtime.git", tag = "v0.1.0-preview.1" }
shared-runtime-tauri = { git = "https://github.com/kreeengvarotske/tauri-multi-window-runtime.git", tag = "v0.1.0-preview.1" }
```

Both crates require Rust 1.88 or later. With the dependency versions in this repository's `Cargo.lock`, Tauri 2.12 needs Rust 1.90 or later. These minimums were found by building, not set as a supported MSRV.

Keep your application's Tauri v2 dependency and build configuration. Commit the application's `Cargo.lock` and use `cargo build --locked` for subsequent builds. Cargo fetches the Git revision on first use, so the build environment needs read access to the repository. This is a Git-based preview dependency.

To reproduce the external consumer check from the repository root, run the script below in a Windows desktop session. It extracts the tracked demo from the current Git HEAD, generates an independent lockfile, builds in a fresh directory, and leaves the native self-test report there. If your temporary directory is deeply nested, pass an existing short path via `-OutputParent` to avoid MSVC path length limits.

```powershell
& ./examples/runtime-adapter-demo/Test-GitConsumer.ps1 -Revision (git rev-parse HEAD)
```

For release verification, check out the release tag, pass its full commit SHA as `-Revision` and add `-RequireMatchingRevision`. The script checks the Git sources of all three runtime packages in the lockfile and requires the native catalog and shutdown evidence in this mode.

The self-test checks integration behavior, including IPC and window lifecycle. Use a workload benchmark to measure memory savings. Sharing resources across separate applications is outside this example's scope.
