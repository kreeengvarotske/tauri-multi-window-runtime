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

The npm dependency versions are pinned by the committed `package-lock.json`. Direct Rust dependencies are pinned in `src-tauri/Cargo.toml`; first build generates a Cargo lockfile, which should be kept with experiment results for exact transitive dependency versions.

## Install and run in development

From the repository root:

```powershell
cd .\benchmarks\vanilla-tauri-baseline
npm ci
npm.cmd run tauri dev
```

The Vite dev server uses port 1430 to avoid colliding with Runtime Lab's port 1420. Open the secondary window with the button in the main window.

## Build a release executable

```powershell
cd .\benchmarks\vanilla-tauri-baseline
npm ci
npm.cmd run tauri build
```

Bundling is disabled in this benchmark app so the executable can be measured without creating an installer. The exact output path should be taken from the build log; it is normally under the nested Rust target directory.

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
