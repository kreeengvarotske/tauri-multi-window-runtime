# Native MemoryInfra qualification, 14 November 2026

**The two-snapshot collector passed, and the profile names layout objects as
a substantial allocation source.** This is subsystem attribution, not an
uninstrumented memory-saving result or a proof of a leak. No runtime
optimization has been accepted from this profile.

## Execution and failures

The app was the preserved baseline C executable from scenario `594f403`
and SDK `2dac921`, SHA-256
`7256d879ed8b3a860c04cd4541d60c5d0c5de3e243bbb7b3a3325ef2d89af5da`.
It used N2D16, seed 1, 500 ms cadence, 5/5/40/15 second phases and a fresh
WebView2 profile. The machine was free of CS2/builds. Collector and app ran
in separate kill-on-close jobs; the collector's CPU is not app CPU.

All paths below are local to `.codex-worktrees/catalog-memory-investigation/target/`:

| Attempt | Result |
|---|---|
| `memoryinfra-native-f6207ee4` | Wrapper rejected ownership using a stale PID snapshot; no trace accepted. |
| `memoryinfra-native-fed6d0e4` | Current-handle job membership and profile ownership passed. Ten-dump collection filled its buffer after five requests; data loss was reported and the attempt failed. |
| `memoryinfra-native-a98f04b4` | Two detailed load snapshots passed, without increasing buffer/file limits. |

The wrapper now verifies the listener's current process handle with
`IsProcessInJob`, rather than requiring it in an earlier PID snapshot. Its
saved observation demonstrates the race: the snapshot contained only the
host, while the later browser listener belonged to the same job. It also
requires the loopback address, WebView2 executable and fresh profile path.

The accepted collector was `24a3606` on WebView2 `157.0.4341.46`, CDP 1.3.
It requested the same 8 MiB buffer and 32 MiB output cap. The native trace
file is 10,193,284 bytes: trace buffer storage and serialized JSON size are
different measures. The summary records two successful requests, 402 trace
events, 30 memory-dump events, no lost data and no near-full-buffer flag.
The app passed 160/160 steps with no failure, mismatch or overrun. App and
collector exited with code 0; the app job reported no timeout, forced
termination or leftovers, and the collector job had no active processes.

## Allocation evidence

The complete collection occurred inside the recorded load phase
(`22:00:28.335Z` through `22:01:08.335Z`), so its dump events belong to
load without inferring a wall-clock mapping from trace timestamps.
The API returned GUIDs `0x1`, `0x2`, while serialized trace dump IDs were
`0x0`, `0x1`. They are preserved separately; no equality or offset rule is
assumed. The following groups are identified by their serialized IDs.

Renderer PIDs were verified as members of this app's job. Their individual
window labels were not established. Sizes below are MiB reported by the
corresponding allocator paths, not OS Private Bytes.

| Renderer | Trace dump | `blink_gc/size` | `blink_objects/.../LogicalLineItems` size | LogicalLineItems object count |
|---|---|---:|---:|---:|
| 2872 | `0x0` | 34.69 | 16.79 | 9,017 |
| 15184 | `0x0` | 37.44 | 18.35 | 9,859 |
| 2872 | `0x1` | 58.44 | 29.64 | 15,922 |
| 15184 | `0x1` | 61.56 | 31.42 | 16,878 |

`ConstraintSpace::RareData` and `LayoutResult` were also prominent. These
are layout-related allocation types. A dump's object count is not a
reachability proof: allocated objects may include garbage awaiting collection.
The `blink_gc` and `blink_objects` paths overlap; adding them would double
count ownership. V8 roots were about 3.2-4.7 MiB in these renderer records.

The [Chromium LogicalLineItems declaration](https://chromium.googlesource.com/chromium/src/+/eb59c72731d60b8f7d2e13189246a7fd2bbe0e26/third_party/blink/renderer/core/layout/inline/logical_line_item.h)
identifies a garbage-collected container for line layout items. This supports
investigating layout churn rather than treating all growth as copied JSON
or leaked DOM nodes. It does not establish why arm A and C differ, or which
application change will reduce whole-process memory.

## Next controlled hypothesis

The benchmark table currently uses automatic, content-dependent layout.
Changing text can require repeated intrinsic sizing and line layout.
A fixed-layout candidate can test that contribution while retaining all
requests, checksums, rows and literal text. Its text wrapping and column
geometry may change, and must remain usable without clipping data.

Before accepting such a candidate, compare it without tracing against the
same baseline, preserve unfavorable results and CPU/latency, and then
compare A/B/C with the same renderer. It remains possible that collection
policy or other layout work dominates instead. No forced GC or reduced
workload is an acceptable substitute.

## Retained records

The successful directory includes app report, runner/job records, verified
port owner, PID creation times and roles, raw trace JSONL and its summary.
The two failures remain alongside it. The derived
`target/memoryinfra-attribution-20261114.json` records allocator roots, top
object types, the phase check, trace SHA-256 and the GUID caveat. The
wrapper source is `target/Run-MemoryInfraNative.ps1`. Local copies must be
included when transferring the investigation to another machine.
