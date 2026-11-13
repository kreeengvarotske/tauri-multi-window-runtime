# Catalog memory investigation, 13 November 2026

**Exploratory diagnosis: a renderer Private Bytes plateau was observed with both original and bounded DOM renderers.** Node counts were bounded in the latter, while both implementations reached approximately 90 MiB Private per renderer. These four short native checks are separate from the frozen [72-run pilot, PR #64](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/64). They neither replace pilot results nor establish a population effect, equivalence, a library defect, or a successful RAM fix.

**Environment warning:** after these daytime diagnostics, the operator reported concurrently playing Counter-Strike. The overlap start is unknown. Treat every daytime diagnostic here as collected under uncontrolled competing RAM/CPU/GPU load. The app's correctness results and observed process/heap records remain available, but the numbers cannot establish a comparative performance effect or rule out one. Repeat comparisons on an idle machine before accepting or rejecting an optimization. The operator's statement concerns the daytime investigation; it is not evidence that the separate overnight pilot had the same conditions.

## Inputs and scope

The checks used arm C, D16, N2 on the pilot's Windows 11 build 26200 machine with WebView2 `157.0.4341.46`. Each used a fresh app process and WebView2 profile, with 5 s idle-before, 5 s warmup, 40 s load, 15 s idle-after, and the existing 500 ms cadence. Each window completed 80 scheduled load steps, giving 160 per check. The payloads, checksums, command limits, and logical workload were preserved.

The original arm source is `9e705738acf0c9e0e6cef2d3d929fcc9c7d6e1a1`. Bounded DOM reuse is `ac97554c35d7ef71cca572e577d913525e7f3933`, which retains at most 100 rows and updates existing cells and text nodes. Both use framework revision `2dac921fcccde1bbadd86da16dbb3136d00341da` and Cargo.lock SHA-256 `45b16b045635048ecd4b87ae797cc49764128b5cf787a20109afe67e88603638`.

| Arm C executable | SHA-256 |
|---|---|
| Original, same bytes as the pilot | `1fae9c6c3b880032753fbc3736303e06a19236851ffb80c71b2374141628a1fa` |
| Bounded DOM reuse | `a8f715d45ac7b1da11fda2623f81fecfd53b8977d421e25287253a00900f04ab` |

Original executable: `.codex-worktrees/pilot-freeze-preflight/target/native-qualification-9e70573/build/bin/arm-C.exe`, relative to the collection repository root. Reuse executable and build provenance: `target/renderer-reuse-build/bin/arm-C.exe` and `target/renderer-reuse-build/build-record.json`, relative to the investigation worktree. Its build record names the exact reuse and framework revisions above. Later probe directories also contain `probe-inputs.json` with the binary hash and launch variant.

## Native role and phase evidence

`roles.csv` records process command lines and Windows PrivateMemorySize64. The growing children are explicitly `--type=renderer`; browser, GPU, network service, storage service, and crash handler are separate processes. In the original uninstrumented check, browser and GPU load means were 42.3 and 113.8 MiB, while renderer load means were 91.1 and 90.3 MiB. The renderer footprint falls again after activity stops. This verifies process roles in these reproductions; the older pilot CSV did not preserve command-line roles.

| Check directory under `target/` | CDP | Mean load Private per renderer, MiB | Load checks |
|---|---|---:|---:|
| `roles-original-b444b9fb` | No | 90.69 | 160/160 |
| `roles-reuse-d7a33384` | No | 92.12 | 160/160 |
| `roles-original-cdp-a668b01b` | Yes | 90.06 | 160/160 |
| `roles-reuse-cdp-94b543ae` | Yes | 90.44 | 160/160 |

Every check reports `passed: true`, zero failures, checksum mismatches, and overruns. Every runner result has exit code 0, no timeout, no terminated job, and zero leftover processes. One observation per variant and instrumentation condition cannot estimate an optimization effect; the recorded checks give no evidence that DOM reuse removed the RAM plateau.

An earlier sandboxed instrumentation attempt is preserved separately in `target/roles-original-5786a516`. Its CIM role collection failed because of access restrictions, so it supplies no role comparison. The successful original check above used the required native access. The failed instrumentation files were not deleted or substituted into the pilot.

The original pilot also shows the phase pattern. Across its six C N2D16 runs, summed inferred-renderer Private medians were 51.0 / 162.0 / 179.0 / 89.4 MiB for idle-before / warmup / load / idle-after. A's corresponding values were 139.8 / 133.9 / 125.2 / 124.2 MiB. This is derived diagnostic context, not a replacement for the pilot's whole-tree primary measure. In pilot run `N2D16-t01-p1-C`, the two growing PIDs fell from approximately 89/90 MiB to 32/30 MiB about seven seconds after load ended; see its raw diagnostics lines 1368, 1369, 1433, and 1442.

## Read-only CDP observations

The two instrumented checks enabled an isolated app-owned loopback DevTools port. The Node 24 sampler sent only `Runtime.getHeapUsage` and `Memory.getDOMCounters` at approximately 2 s intervals. It did not evaluate JavaScript, request GC, purge memory, or modify the app. Each produced 70 page-target samples with no field errors. The report timestamps define phases; each page has 2/3/20/7 samples in the four phases. Instrumentation can still affect scheduling, so its values are diagnostic.

All memory columns below are MiB. Each value is the mean of the two per-renderer phase means; DOM maxima are the largest sampled count in either page. CDP page IDs are not mapped individually to OS PIDs. The role and page aggregates cover the same two-window run.

| Variant | Phase | Private | JS used | JS allocated | Embedder GC used | Backing storage | DOM nodes, mean / max |
|---|---|---:|---:|---:|---:|---:|---:|
| Original | Idle-before | 26.05 | 1.30 | 2.25 | 4.37 | 0.05 | 1143 / 1143 |
| Original | Warmup | 42.63 | 1.53 | 2.71 | 20.20 | 0.15 | 7743 / 12143 |
| Original | Load | 90.06 | 1.16 | 2.59 | 11.87 | 0.09 | 5501 / 23587 |
| Original | Idle-after | 56.07 | 0.93 | 2.18 | 3.06 | 0.04 | 1273 / 3775 |
| Reuse | Idle-before | 27.96 | 1.34 | 2.25 | 4.36 | 0.05 | 1143 / 1143 |
| Reuse | Warmup | 40.37 | 1.56 | 2.58 | 16.58 | 0.20 | 1143 / 1143 |
| Reuse | Load | 90.44 | 1.31 | 2.87 | 14.75 | 0.15 | 1133 / 1143 |
| Reuse | Idle-after | 61.28 | 0.99 | 2.21 | 3.44 | 0.05 | 1130 / 1131 |

`usedSize` and `totalSize` describe used and allocated JS heap; `embedderHeapUsedSize` describes the embedder's garbage-collected heap; `backingStorageSize` covers array-buffer and external-string backing storage. They are not a complete decomposition of process Private Bytes and should not be subtracted as an exact accounting identity. See the primary [CDP Runtime protocol](https://chromedevtools.github.io/devtools-protocol/tot/Runtime/#method-getHeapUsage).

The key distinction is between phase means and allocation peaks. Original embedder GC samples peaked at 57.6 and 58.5 MiB per page; reuse peaked at 60.1 and 57.8 MiB, despite its maximum of 1143 DOM nodes. In reuse `cdp.jsonl:26`, the main page reports 60.102 MiB embedder heap at `14:01:56.149Z`, with 1143 nodes. At `14:02:24.237Z`, line 55 reports 4.103 MiB and 1130 nodes, still during load. Nearby role samples remain approximately 95.9/94.3 MiB Private for the two renderers (`roles.csv:328` and `:329`). Thus committed Private memory can remain high after the reported embedder heap falls.

These observations locate substantial transient allocation in the embedder GC heap and subsequent Private-page retention. They do not identify the concrete allocation stack, prove a leak, or establish which IPC or rendering component owns the peak. Bounded node reuse removes one source of DOM churn, but does not remove the other allocation pressure in this reproduction.

## Remaining diagnosis

Pinned Tauri 2.12.5 uses a custom-protocol POST followed by `response.json()` (`scripts/ipc-protocol.js:37` and `:48`). Its callback registry explicitly unregisters successful/error callbacks (`scripts/core.js:84-90`). Wry 0.57.1 passes nonempty responses through `SHCreateMemStream` and `CreateWebResourceResponse` (`src/webview2/mod.rs:1226-1229`). This makes the fetch/body lifecycle a concrete candidate, but host-side response buffers alone cannot explain the renderer-local footprint.

A transport isolation must account for Tauri's Channel response path, which can fetch data again unless `customProtocolIpcBlocked` is true. Additional diagnostic isolations are recorded below. A general transport rewrite, artificial idle/GC, or a changed primary measurement window is not justified by these checks.

## Additional diagnostic isolations

The separate JSON postMessage/eval reproducer and its two successful 160-step checks are preserved in [PR #65](https://github.com/kreeengvarotske/tauri-multi-window-runtime/pull/65). Its observed native-memory plateau also persisted. These uncontrolled daytime observations do not establish equivalence or exclude a transport effect.

`target/roles-reuse-native-profile-b8dbb681` adds native allocation sampling (`Memory.startSampling` at a 32,768-byte interval and `Memory.getSamplingProfile`) to the bounded-renderer executable. It completed 160/160 data checks without failures, mismatches or overruns. Full sample stacks and module metadata are retained in `cdp.jsonl`. The returned stacks contain raw addresses rather than useful function symbols; this profile has not identified the owner of the large embedder allocation. Profiling overhead and competing game activity prevent performance conclusions.

`target/roles-reuse-no-text-b3721391` is an explicit display-isolation probe. On its app-owned DevTools targets, `target/sample-no-text-cdp.mjs` temporarily replaces only the `Text.prototype.data` setter with a no-op while preserving its getter. Requests and checksum validation continue, but table field updates are intentionally disabled. Its 160/160 data checks passed; this is **not** a valid implementation of the displayed workload or a memory optimization. It is a lead for investigating repeated JS-to-DOM text conversion, which still requires an idle-machine reproduction. No GC or memory-pressure command was issued.

Any bounded text canonicalization candidate must retain the same visible text and request/checksum workload, cap both entry count and estimated string payload, and be measured separately on a free machine before a RAM claim. Native diagnostic processes have ended; no additional heavy runs are scheduled while the operator is gaming.

## Unit-tested candidate and remaining gates

The current source offers an opt-in per-renderer LRU of displayed strings, limited to 8192 entries and a 1 MiB UTF-16 payload estimate. Oversized strings bypass retention. This estimate excludes engine/Map overhead, retained backing storage, DOM and OS memory; it is not a process RAM cap. The cache adds retention and lookup work, so it may also cost RAM or CPU. All 30 frontend tests (including both cache modes) and TypeScript checks pass, including eviction, exact budget boundaries, oversized strings, Unicode and unchanged displayed contents. The cache is off by default; `--text-cache on` enables it and `config.textCache` records the choice in each report. Three tests of the real Rust config module also pass independently in each arm feature configuration, without linking Tauri. This does not replace a full application build. No native executable containing this text cache has been built or measured yet. The earlier native binaries remain tied to their exact revisions above.

Hosted CI is also blocked independently of code execution. Runs `43439842541` / `43439842514` on `678a3b7` and `43441113567` / `43441113785` on `e53357a` ended before any job steps ran. GitHub's check annotations report an account payment or spending-limit problem. Local passing checks are not a substitute for hosted CI; do not mark these PRs green or merge-ready until account access is restored and the required jobs run. No repeated workflow dispatches are scheduled while that condition remains.

## Preserved diagnostic evidence

All paths below are local and relative to `.codex-worktrees/catalog-memory-investigation/`. They are ignored diagnostic artifacts, not uploaded pilot replacements:

- Each of the four `target/roles-*` directories listed above retains `report.json`, `roles.csv`, `result.json`, `job.csv`, and `messages.csv`; CDP variants also retain `cdp.jsonl`, sampler stdout/stderr, and the stop marker.
- `target/probe-original.ps1` records the serial app/profile launch procedure. `target/sample-cdp.mjs` records the read-only protocol allowlist, loopback-port restriction, retry behavior, and marker/120 s stop.
- `target/cdp-memory-profile/profile.json` contains the derived phase statistics used here.
- `target/baseline-memory-profile/profile.json` and `summary.md` contain the separate 72-run pilot phase derivation, role-inference limits, and timestamp references.
- The pilot source remains untouched at `.codex-worktrees/pilot-freeze-preflight/target/pilot-approved-179f3661/pilot-native`, relative to the collection repository root. Its whole-tree RAM and whole-run CPU outcomes remain those reported in PR #64.
