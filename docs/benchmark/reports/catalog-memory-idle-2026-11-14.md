# Catalog memory diagnosis on an idle machine, 14 November 2026

**Neither tested candidate established useful memory savings.** The opt-in
string cache remains off. The renderer-owned last-value experiment stays on
its separate local branch; it is not included in this change. This report
does not establish that the framework cannot save memory.

These short diagnostics are separate from the frozen 72-run pilot and from
the latest SDK correctness candidate in PR #68. No pilot, confirmatory run,
release or merge was performed.

## Measured scope

Each run used arm C, N2D16, seed 1, 500 ms cadence and 5/5/40/15 second
idle-before/warmup/load/idle-after phases. A new process and WebView2 profile
were used each time. CS2 and Cargo/Rust builds were excluded at launch and
at the end of every completed collection. This does not prove the operating
system was otherwise perfectly idle.

The machine was Windows 11 build 26200, WebView2 `157.0.4341.46`, with the
Balanced power plan. About 20 GiB of system memory was free at preflight.
System free memory was an environment check, not the performance outcome.

Private Bytes were sampled from the processes in the app's own Job Object.
The table reports the arithmetic mean of those whole-job samples within
the app's load timestamps, and a separate summed renderer mean. RAM was
sampled roughly every 0.3 seconds; it is not an instantaneous peak, a live
object count, Working Set or a limit on physical RAM. Short-lived processes
can be absent between samples. Renderer PIDs were classified from process
roles; individual PIDs were not verified against window labels.

CPU is the final whole-job user plus kernel time, including shutdown. This
differs from the frozen pilot's boundary rule as well as its longer phases;
do not compare these CPU values directly with pilot values. The collector's
own work is outside the measured job. This collector is not the frozen
protocol's monitor or validity analysis.

## Provenance

| Variant | Scenario revision | Executable SHA-256 |
|---|---|---|
| Baseline; text cache off/on | `594f4036a0603cc0cf1067cfd32f8f4b89898c61` | `7256d879ed8b3a860c04cd4541d60c5d0c5de3e243bbb7b3a3325ef2d89af5da` |
| JS last-written-value comparison; cache off | `5ed69e5de890b43a904c12727f7d9fa62b5f6cc2` | `308be2b790a569864d0093afb36f0f02e98f4201af1e6034579e204e53f382c8` |

Both used SDK `2dac921fcccde1bbadd86da16dbb3136d00341da` and Cargo.lock
SHA-256 `45b16b045635048ecd4b87ae797cc49764128b5cf787a20109afe67e88603638`.
They were ordinary Release builds with `tauri/custom-protocol,framework`.
No forced GC, pressure notification, working-set trim or display suppression
was used in these native comparisons. Both source variants passed 36
frontend tests, 6 offline diagnostic-plan tests and TypeScript/build checks.

## Observations and decisions

Each three-run row below gives medians; brackets give observed minima and
maxima, not confidence intervals. The original control is one observation.

| Variant | Whole-job load Private MiB | Summed renderer MiB | Whole-job CPU seconds | Maximum window p95 latency, ms |
|---|---:|---:|---:|---:|
| Baseline, off | 385.84 [384.42, 387.41] | 181.80 | 6.781 [6.609, 7.031] | 7.0 |
| Text cache, on | 388.18 [386.85, 396.01] | 182.43 | 7.719 [5.875, 8.516] | 8.0 |
| JS value comparison, off | 383.42 [380.83, 383.60] | 175.90 | 7.781 [7.563, 8.234] | 11.5 |
| Original-binary control between JS-comparison runs | 384.07 | 178.33 | 8.797 | 10.0 |

The diagnostic decision rule was more than 5% RAM improvement with no CPU
regression beyond 10%; it did not change the frozen statistical protocol.
The string cache changed median RAM by +2.35 MiB (+0.61%). Avoiding the DOM
getter changed it by -2.42 MiB (-0.63%). Neither reached the RAM threshold.
The multi-objective decision helper also rejected the CPU median comparisons.
However, CPU rose in the later original-binary control too. The sequential
ordering and this drift prevent attributing that rise to either candidate.

All ten completed collections passed 160/160 workload checks, with no
checksum failures, overruns, timeouts, terminated jobs or leftover processes.
A separate initial collection completed the app and retained memory/job
records but failed when serializing numeric PID dictionary keys. That
collector error was corrected; the partial attempt is preserved and is not
silently substituted into the three baseline observations.

The getter variant used one last-written string per renderer-owned cell and
cleared it when hiding the cell. It preserved displayed fields in the tests,
but did not remove the native-memory plateau. There is no accepted source
optimization to merge from this investigation.

## What remains unexplained

The old display-disabled probe had about 34.46 MiB Private per renderer,
versus 90.44 MiB for bounded DOM rendering. Its peak reported embedder GC
heap was 10.54 versus 60.10 MiB. This is only a locating lead: it changed
display semantics and had uncontrolled competing game load.

Reanalysis of all 70 records in the earlier native sampling profile found
estimated native samples below 6 MiB while reported embedder GC peaked near
60 MiB. The two accounting domains do not form an additive decomposition;
neither subtract them nor claim the sampling stacks explain the missing
cost. The allocating component is still unknown.

The pilot already showed that arm B's hand-written sharing had a similar
N2D16 penalty to arm C, while C-B was small in that sample. This guides the
investigation toward the common data/renderer path; it is not an equivalence
proof or evidence that runtime overhead is zero.

The next locating measurement is per-process MemoryInfra subsystem
accounting on an idle machine. It must retain dump GUIDs, request time
brackets, the owned PID mapping and app/Job Object reports. Do not sum
overlapping allocator paths, infer window labels from PID order, or accept
profiler-enabled numbers as the RAM outcome. See the
[MemoryInfra diagnostic plan](../../../benchmarks/catalog/plans/memory-infra-diagnostic/README.md).

## Preserved local evidence

Paths are relative to `.codex-worktrees/catalog-memory-investigation/`:

- `target/memory-diagnostics-20261114-evidence.zip`: 764,786 bytes, 112 payload
  files plus a manifest. SHA-256
  `c0ef2c1139a6a12b008d9f8bd84a05179334098b7d3299bdc6e2ac5d1f543b71`.
  Every packaged payload was re-read and hash-checked. All eleven native
  attempts, including the collector failure, are represented. Profiles and
  executables are retained separately and excluded from this compact ZIP.
- `target/memory-baseline-build/` and `target/memory-getter-build/`: exact
  executables and build records.
- `.context/compound-engineering/ce-optimize/catalog-memory/`: spec, native
  collector, offline derivation, schedule, decision inputs/results and log.
- `target/memory-reanalysis-20261114.json` and
  `target/native-sampling-reanalysis-20261114.json`: derived prior-profile
  observations. The former also hashes its source records.

No further native measurements were started after the user freed the machine
for gaming. The project still needs comparative evidence on the selected
release SDK before making a product memory-saving claim.
