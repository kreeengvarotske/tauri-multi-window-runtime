# Owned-process memory diagnostic, version 2

This diagnostic repairs the temporary long-run sampler's exit/read ambiguity.
It does not change the frozen A/B/C protocol, reclassify previous failures, or
establish a product memory claim. It measures N2D16/C with text caching off.

The old sampler rejected two load rows when short-lived WebView2 processes
exited between enumeration and reading. Its bare catch retained no read-error
identity. The failed `memory-long-off-1b9f98ea` remains invalid. Job messages
correlate the missing samples with roughly 51 ms and 282 ms process lifetimes;
correlation cannot recover a missing read or its exception.

## Reader and ownership

`Read-OwnedMemory.ps1` pins a process handle, verifies current job membership
through that handle, reads Private Bytes, rechecks exit state and disposes the
Process object. It distinguishes `Read`, `ExitedBeforeOpen`, `ExitedAfterOpen`,
`ExitedDuringRead` and `Unavailable`. A known exited process contributes zero
at the end of its read. An inaccessible live process, failed/unknown property
getter, or foreign/recycled PID is unavailable and invalidates a load row.
PowerShell may silently return null from a throwing property getter; explicit
handle, exit-state and byte-value checks prevent accepting that as zero.

Frames are sequential observations, not atomic snapshots. Processes born and
exited wholly between samples may be absent from RAM readings. Whole-run CPU
comes from Job Object accounting, with the existing completeness, membership,
clock and phase-coverage checks. Sampling cannot establish a process's maximum
short-lived RAM or identify an individual WebView window from a renderer PID.

## Execution and retained evidence

Run `scripts/Test-OwnedMemory.ps1 -Native` in PowerShell 7 and Windows
PowerShell 5.1 first. Ten deterministic cases cover live/disposed objects,
three exit phases, unavailable/foreign reads, negative memory and failed initial
or final exit checks. Three native checks cover an owned live process, a
foreign process and a pinned exited process, with no surviving fixture child.

`Measure-CatalogMemoryDiagnostic.ps1` requires an executable, its build-record
JSON and a new output directory. The record must contain `scenarioRevision`,
`frameworkRevision`, `cargoLockSha256` and `executableSha256`. These preserve
declared application provenance; retained build logs must substantiate it.
The collector verifies the executable hash before and after, records its own
separate revision, uses a fresh profile and accepts only clean app/job results
with complete workload/configuration assertions. It records every process
read's PID, creation time when available, status, error and frame timestamp.
Unknown identities remain explicit; no name or role is guessed.

Default phases are 20/30/120/30 seconds, with a 500 ms application step cadence.
`-LoadSeconds 10 -IdleBeforeSeconds 2 -WarmupSeconds 2 -IdleAfterSeconds 2`
is a short collector qualification, not an optimization comparison. Never
combine it with the old sampler's rows. Do not run a game or concurrent build
during collection. Start/end guards are an aid; the operator must keep the
machine idle throughout. Failed attempts and their result files are retained.

The first qualified application binaries may still contain framework `2dac921`.
Their results must not be described as measurements of SDK PRs #66–#68 or later
fixes. A new SDK baseline requires separately recorded, matched A/B/C inputs.
