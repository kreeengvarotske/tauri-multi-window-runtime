# PrivatePageCount unit check, Windows 10, 2026-10-25

Question (review thread r4370911812 on PR #9): is `Win32_Process.PrivatePageCount`, which `Measure-ProcessTree.ps1` sums as bytes, really in bytes, or in pages as its name and the documentation suggest?

**Answer on this system: bytes.** For every process and both phases, the median of `PrivatePageCount / Get-Process PrivateMemorySize64` is 1.000000. The two values are byte-equal in 80 of 90 rows. `PrivatePageCount == PageFileUsage × 1024` holds exactly in all 90 rows. The "pages" hypothesis (`× 4096`) gives a median of 4096.

## Environment

- Windows 10 Home 22H2, version 10.0.19045, build 19045 (`Win32_OperatingSystem`); `[Environment]::OSVersion` 10.0.19045.0. **Not Windows 11.**
- Windows PowerShell 5.1.19041.6456 (Desktop edition, CLR 4.0.30319.42000). PowerShell 7 is not installed, so there was no pwsh run.
- `[Environment]::SystemPageSize` = 4096.
- WebView2 Runtime 155.0.4283.62. AMD Ryzen 7 9800X3D (16 logical CPUs), 31 GB RAM.
- Runtime Lab Release build with the automated benchmark panel (PR #11), with the `secondary` window open.

## Processes

| PID | Name | Role |
|---|---|---|
| 18316 | tauri-multi-window-runtime.exe | app exe |
| 14000 | msedgewebview2.exe | WebView2 browser |
| 8800 | msedgewebview2.exe | GPU process |
| 10328 | msedgewebview2.exe | renderer A |
| 12184 | msedgewebview2.exe | renderer B |
| 9304 | msedgewebview2.exe | utility (network) |
| 8664 | explorer.exe | unrelated control |
| 344 | svchost.exe | unrelated control |
| 2836 | powershell.exe | the sampler itself |

## Method

Each round read, for each PID and back to back, each with its own stopwatch timestamp (`t_*_ms`):

- (a) `Get-CimInstance Win32_Process` (`PrivatePageCount`, `PageFileUsage`, `WorkingSetSize`);
- (b) `Get-Process` (`PrivateMemorySize64`, `PagedMemorySize64`, `WorkingSet64`);
- (c) `Win32_PerfRawData_PerfProc_Process` (`PrivateBytes`, `WorkingSetPrivate`, `WorkingSet`).

The gap from (a) to (b) is about 20–25 ms, and from (b) to (c) about 2 ms.

A fourth source, (d), was one batched `Get-Counter '\Process(<instance>)\Private Bytes'` per round. Instances were mapped via `ID Process` from the same sample; the mapping was correct in 90 of 90 rows. (d) is up to about 450 ms later than (c), so it is the least synchronous source.

There were 5 snapshots about 2 s apart while idle. Then "Нагрузка 60 секунд" was started at 15:20:06.000, and 5 more snapshots were taken within its first 9 s.

Ratios: `r1 = PPC / PrivateMemorySize64`, `r2 = PPC / PerfRaw PrivateBytes`, `r3 = PageFileUsage × 1024 / PrivateMemorySize64`, `r4 = PPC × 4096 / PrivateMemorySize64`, `r5 = PPC / Get-Counter Private Bytes`. Columns `d*` are the matching differences in bytes.

## Results

- r1: median 1.000000 for every PID in both phases. It is exactly 0 in 43 of 45 idle rows and 37 of 45 load rows. The range is 0.925–1.199, with |d1| ≤ 1,486,848 bytes. Every non-zero row is a process whose memory changed in the ~22 ms between reads (app exe and utility process under load, and the sampler itself).
- r2: median 1.000000. PerfRaw `PrivateBytes` equals `PrivateMemorySize64` in 87 of 90 rows.
- r3 equals r1 in all 90 rows, that is, `PrivatePageCount == PageFileUsage × 1024` exactly.
- r4: median 4096.
- r5: 1.0 while idle; medians 0.954–1.0 under load, because of the delayed batched read.

## Files

- `units-raw.csv`: all 90 rows (9 PIDs × 5 snapshots × 2 phases).
- `units-summary.csv`: per phase and PID, the median, minimum and maximum of r1–r5 and of the differences.

The sampling scripts (`sample.ps1`, `summarize.ps1`) and the original files are kept on the test machine. These CSVs are copies of that output.

## Not checked

Windows 11 and PowerShell 7. `Measure-ProcessTree.ps1` now repeats the r1 check at startup and stops if the median is outside 0.9–1.1, so a different result on another system cannot go unnoticed.
