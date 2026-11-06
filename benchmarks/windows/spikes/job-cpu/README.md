# Spike: final CPU of short-lived processes from Job Object accounting

Status: spike for the #36 decision (comment 6691611439). Not part of the
benchmark protocol; the smoke, pilot and confirmatory runs are unchanged.

## Problem

The monitor (#43) reads CPU through a handle opened when a process is first
seen. A WebView2 child that lives a few tens of milliseconds can exit before
`OpenProcess`, so its CPU is lost (`ExitedUnread`) and the run is invalid
under §7. A held handle cannot help when the process is never seen.

## Source under test

A Windows Job Object. The app is created suspended, assigned to a new job and
only then resumed, so it and every descendant are in the job from the first
instruction (the job does not allow breakaway). `QueryInformationJobObject`
(`JobObjectBasicAccountingInformation`) returns the user and kernel time of
all processes of the job, active and terminated, plus process counts. These
are kernel counters, not events: nothing can be lost or dropped, and no
elevation or tracing session is needed.

What it does not give: CPU per process after exit. The total is for the whole
tree. Per-process attribution stays with the monitor.

## Files

- `JobCpuAccounting.psm1`: native helpers (create job, start suspended in the
  job, accounting, job PID list, CPU through a held handle).
- `Test-JobCpuAccounting.ps1`: checks on real processes, no elevation.
  1. Accuracy: N short processes that exit before any sampler could read them,
     with handles held from creation as the independent reference. Job CPU must
     equal the sum of `GetProcessTimes` of the held handles (within 1e-7 s per
     process) and the job must count every process.
  2. Tree: a root that starts its own short children (only the root's handle
     held). Every process seen by the `ParentProcessId` tree walk must be in the
     job; reports how many processes 0.5 s sampling never saw.
  3. Overhead: cost of one accounting query.
- `Measure-JobCpuWebView2.ps1`: short check on the real WebView2 tree of
  scenario M (default N4D64). Starts an arm executable in a job, runs the
  monitor next to it, reads the job every second and writes
  `<name>.compare.json` (job vs monitor CPU, never-seen processes, job PIDs vs
  the monitor's tree, monitor CPU reasons). Needs the target machine and
  separate permission; it is not a smoke run.

## Commands

```powershell
# Hosted CI and locally (Windows PowerShell 5.1 and PowerShell 7):
.\benchmarks\windows\spikes\job-cpu\Test-JobCpuAccounting.ps1 -OutputPath job-cpu.json

# Target machine, with permission, separate from the smoke:
powershell -NoProfile -ExecutionPolicy Bypass -File .\benchmarks\windows\spikes\job-cpu\Measure-JobCpuWebView2.ps1 `
  -Executable <results>\bin\arm-A.exe, <results>\bin\arm-B.exe, <results>\bin\arm-C.exe `
  -MonitorScript .\benchmarks\windows\Measure-ProcessTree.ps1 -OutputDirectory <new directory>
```

## Open questions for the WebView2 check

- Does Chromium/WebView2 stay inside the job? Since Windows 8 jobs nest, and
  the browser process may create its own job for its children; the check
  compares the job PID list with the monitor's tree.
- Does any WebView2 process escape through breakaway or a broker (for example
  a process started by a service)? Such a process would be in the tree but not
  in the job (`treeNotInJob`).
- Is the gap job minus monitor CPU the size of the missed short processes?
