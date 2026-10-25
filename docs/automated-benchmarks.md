# Automated Runtime Benchmarks

This guide describes the repeatable Runtime Lab checks available in the Tauri application. The suite uses real Rust Core counters and does not infer coalescing from response payloads alone.

## Automated checks in CI

The GitHub Actions workflow runs:

- `npm ci`
- `npm run typecheck`
- `npm test`
- `npm run build`
- `cargo fmt --all --check`
- `cargo clippy --workspace --all-targets --locked -- -D warnings`
- `cargo test --workspace --locked`

A successful CI run verifies those checks on the commit that CI tested. A local Windows Release build and native two-window exercise are still needed for Windows-specific validation.

## Run the fixed coalescing suite

1. Build a Release version:

   ```powershell
   npm.cmd ci
   npm.cmd run tauri build
   ```

2. Launch the generated executable from the repository root:

   ```powershell
   $app = Start-Process -FilePath ".\target\release\tauri-multi-window-runtime.exe" -PassThru
   $app | Select-Object Id, ProcessName
   ```

3. Open the `secondary` window from `main`. In the main window, use **Автоматическая проверка Task Coalescing** and click **Проверка: 5 пар / 500 запросов**.

The runner repeats five rounds. Before each round it waits until Core is idle (every received request classified, counters unchanged for three polls), clears the shared cache, asks `secondary` to issue 50 concurrent requests for `project-42`, and starts 50 requests in `main`. A round ends when both windows have reported that their series finished and Core has classified exactly 100 requests. Manual window switching is not required.

`main` and `secondary` exchange frontend events only (`lab://run-series`, `lab://run-series-ack`, `lab://run-series-done`); no Rust command is involved. Each request carries an id: `main` re-sends it until `secondary` confirms that id (5 s limit), `secondary` starts the series once per id, and its completion report is matched by the same id. These events are not authenticated: any window may emit them, so they are a test harness channel, not a trusted one.

A successful report is expected to contain:

- 500 requests received;
- 5 actual operation executions;
- 495 coalesced requests;
- 0 cache hits;
- 0 failed requests.

The report checks the per-round counter deltas and can be downloaded as JSON. Each round records the id of the secondary series it counted (`secondaryRequestId`).

When a round fails (the secondary does not confirm, either series fails, Core receives more requests than the round sent, or the round takes longer than 15 s), the run stops and no report is produced. The runner first waits up to 10 s for both series to end and Core to become idle, so the next run cannot count the tail of this one:

- if everything ended, the error says so and the buttons are enabled again;
- if something is still running, the status names it and both buttons stay disabled until it ends and Core is idle. Closing the `secondary` window ends its series for this purpose.

## Run a 60-second resource workload

Use this mode when sampling process resources. Start the process monitor in a separate PowerShell window first, then click **Нагрузка 60 секунд** in Runtime Lab. Keep both app windows open and do not interact with other series while the runner is active.

From the repository root, start the monitor with the main app PID printed by `Start-Process`:

```powershell
$results = Join-Path $env:USERPROFILE "Documents\tauri-benchmark-results\runtime"
New-Item -ItemType Directory -Force -Path $results | Out-Null

.\benchmarks\windows\Measure-ProcessTree.ps1 `
    -RootPid 12345 `
    -DurationSeconds 60 `
    -SampleIntervalSeconds 1 `
    -OutputPath (Join-Path $results "runtime-timed-load.csv")
```

Replace `12345` with the PID of `tauri-multi-window-runtime.exe`. While this script is sampling, start the timed workload in the app. Each round clears the cache and runs a paired 50-request series in each window. The run continues until at least 60 seconds have elapsed and the final pair has completed. The resulting JSON report records each round and its counter deltas; the PowerShell CSV records resource samples.

## Interpretation

- Compare Release builds, not Debug builds.
- Use the same app window count, request count per window, project ID, monitor interval, and workload duration for the baseline and Runtime variants.
- Inspect `ProcessTree` in every CSV. The monitor sums the root process and discovered descendants; some WebView2 helpers can be outside the parent/child tree.
- Working Set and Private Bytes describe different memory properties. Report both.
- CPU is normalized to the total capacity of all logical processors.
- The demo provider waits asynchronously for 400 ms. It is useful for request concurrency and latency tests, but it is not a CPU-intensive workload. Do not use this demo alone to claim CPU savings on compute-heavy production workloads.
- Run at least five fixed-suite repetitions before making latency claims. For resource comparisons, save separate CSVs for each run and report the median/range, not just the best run.
- Keep the downloaded JSON report and raw CSV together with the commit SHA and machine details.
