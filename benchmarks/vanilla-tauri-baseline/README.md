# Vanilla Tauri Baseline

This standalone Tauri v2 application is the non-optimized reference implementation for the Runtime Lab performance experiments. It deliberately does not implement task coalescing, a shared in-flight operation map, or a metadata cache.

## What it measures

The frontend supports 1, 10, 20, or 50 concurrent requests for the same project ID. It uses `Promise.allSettled`, displays the success/error counts and wall-clock duration, keeps the latest 20 runs in window-local memory, and refreshes backend counters only when requested.

Every valid IPC invocation starts its own 400 ms asynchronous provider operation. The two Tauri windows share one process-level stats state, but requests are never merged and results are never cached. The stats command reports zeros for coalesced requests, cache hits, and cached entries by design.

The demo project IDs are `project-42`, `demo`, `alpha`, and `beta`. The ID `flaky` simulates provider errors. Other IDs return a not-found error.

## Requirements

- Windows 11 with the WebView2 runtime
- Node.js compatible with Vite 8 (Node.js 20.19+ or 22.12+)
- Rust stable toolchain and the Windows build prerequisites for Tauri v2
- npm

The npm dependency versions are pinned by the committed `package-lock.json`. Direct Rust dependencies are pinned in `src-tauri/Cargo.toml`, and transitive versions by the committed `src-tauri/Cargo.lock`. That lockfile was seeded from the Runtime Lab root `Cargo.lock`, so both apps build with the same versions of every shared crate (the only difference is `tokio-macros`, which only Runtime Lab uses). Build with `--locked` so a build fails instead of silently changing them. `src-tauri/Cargo.toml` uses the same `[profile.release]` as the Runtime Lab workspace root.

## Install and run in development

From the repository root:

```powershell
cd .\benchmarks\vanilla-tauri-baseline
npm ci
npm.cmd run tauri dev
```

The Vite dev server uses port 1430 to avoid colliding with Runtime Lab's port 1420. Open the secondary window with the button in the main window.

The source icon is `src-tauri/icons/vanilla-baseline.svg`. The npm `dev` and `build` scripts generate Tauri's platform-specific icons (including the Windows `icon.ico`) into `src-tauri/icons` before starting Vite or building the frontend. This avoids depending on generated binary assets being present in a fresh checkout.

## Build a release executable

```powershell
cd .\benchmarks\vanilla-tauri-baseline
npm ci
npm.cmd run tauri -- build -- --locked
```

Bundling is disabled in this benchmark app so the executable can be measured without creating an installer. The exact output path should be taken from the build log; it is normally under the nested Rust target directory.

## Automated 60-second paired load

Build and launch the Release executable, then open the secondary window from the main window. The main window now has a **Run paired load (60 seconds)** button. It starts 50 independent metadata requests in each window per round and repeats paired rounds until at least 60 seconds have elapsed and the final round completes. It downloads a JSON report containing request outcomes and Rust Core counter deltas.

Each round's request carries the run id and round number. `main` re-sends it every 100 ms until `secondary` confirms that exact round (`baseline://paired-load-ack`), for at most 5 seconds; otherwise the run stops with an error saying the round was not started. `secondary` runs a round once however often the request arrives. Tauri events are not buffered, so a request sent while the secondary page is still loading would otherwise be lost.

For a resource sample, start the root process monitor from the repository root before clicking the button:

```powershell
$results = Join-Path $env:USERPROFILE "Documents\tauri-benchmark-results\baseline"
New-Item -ItemType Directory -Force -Path $results | Out-Null
$app = Get-Process -Name "vanilla-tauri-baseline" -ErrorAction Stop | Select-Object -First 1
.\benchmarks\windows\Measure-ProcessTree.ps1 -RootPid $app.Id -DurationSeconds 75 -SampleIntervalSeconds 1 -OutputPath (Join-Path $results "vanilla-automated-load-01.csv")
```

When the sampler begins, switch to the app and click **Run paired load (60 seconds)**. Keep both windows open and do not run other request series while it is active. The JSON report should show `requestsReceived = operationsExecuted`, with zero coalesced requests, cache hits, and errors. Save the JSON and CSV together for each run.

Run the same 60-second paired scenario on Runtime Lab with 50 requests in each window and the same project ID. The exact number of rounds may vary slightly between applications; record actual requests per second alongside memory and CPU rather than assuming the round count is identical. To strengthen conclusions, repeat each variant at least five times, alternate which variant runs first, and compare medians and ranges.

## Recommended benchmark procedure

1. Record Windows build, CPU model, logical processor count, RAM, Node.js, npm, Rust, and WebView2 versions.
2. Use Release builds for measured runs. Do not compare a development build against a Release build.
3. Start the app and use the same window count, project ID, request count, warm-up period, and sampling interval for each variant.
4. For the cross-window test, clear the Runtime Lab cache before the test, start the 50-request series in `main`, and immediately start another 50-request series in `secondary`. Compare counter deltas only after both series complete.
5. Run each scenario at least five times. Save each PowerShell monitor CSV under a unique name.
6. Keep statistics polling consistent. For an initial resource measurement, do not refresh stats repeatedly during the timed interval.
7. Inspect the monitor's `ProcessTree` column to verify which processes were included. Some WebView2 helper processes may not be parented under the app process and could need separate grouping.
8. Do not claim this baseline is faster or slower until the same scenarios are run and repeated on all variants.

## Important interpretation

This app intentionally performs more provider operations than the Runtime Lab runtime during concurrent same-key calls. That is its purpose as a baseline. The artificial `sleep(400 ms)` provides a controlled latency/coalescing comparison but does not create meaningful CPU-bound work, so it cannot by itself establish CPU savings.

This baseline has a simpler dashboard than Runtime Lab, so UI startup and idle memory comparisons are only approximate until the frontend feature sets are made equivalent. Request latency and backend execution counters are the primary first measurements.
