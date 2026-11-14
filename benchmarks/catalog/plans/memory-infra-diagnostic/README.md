# MemoryInfra subsystem diagnosis

Prepared, not run natively. This is a locating probe after the failed
text-cache and DOM-getter candidates, not a replacement pilot, confirmation
or a claim of memory savings. The collector's protocol lifecycle has mock
tests; compatibility with the pinned native WebView2 still needs validation.

## Scope and next execution

Use only a fresh benchmark process/profile in its own kill-on-close Job
Object on an idle machine. Retain the source revision, executable/lock
hashes, OS/WebView2 version, command and every attempt. Start with the
recorded baseline executable, arm C, N2D16, seed 1, 500 ms cadence and
5/5/40/15-second phases. No other build or game may run concurrently.

The native runner must establish that the DevTools listening PID belongs
to that job before supplying the port. A loopback URL alone does not prove
ownership. Never attach to the user's browser, Codex or an unrelated app.
The sampler itself does not verify Windows PID ownership, launch a process,
validate application checksums or manage the app's Job Object.

After the runner has established ownership, from `benchmarks/catalog`:

```text
node scripts/MemoryInfraDiagnostic.mjs --port <owned-port> --out <new.jsonl> --stop-file <new-stop-marker>
```

The collector discovers `/json/version` without redirects, accepts only a
browser WebSocket on the same loopback port and sends three CDP methods:
`Tracing.start`, `Tracing.requestMemoryDump` and `Tracing.end`. It requests
memory-only Chrome tracing with an 8 MiB buffer, no automatic dump triggers,
and two manual detailed dumps approximately five seconds apart. Output is
capped at 32 MiB. Existing output and summary files are never overwritten.
Native support for the requested trace configuration must be checked, not
inferred from mocked protocol tests.

The original ten-dump native attempt filled the buffer and reported data
loss after five requests. It remains a failed attempt. The narrower probe
retains the same limits and must be scheduled inside the app's load phase;
it does not provide a complete multi-phase profile.

Every dump explicitly uses `deterministic: false`. There is no forced GC,
evaluation, heap snapshot, OS trace, memory-pressure notification or app
modification. A rejected tracing start does not authorize ending somebody
else's trace. A successful start owns the matching end/flush operation.
The flush has a timeout; data loss, a nearly full buffer, failed dump or
writer failure prevents a successful result. The stop marker ends sampling
between requests and during its inter-request wait. A partially collected
profile records `requestedSamples`, actual dumps and `stoppedEarly`.

The wrapper must stop/await this collector before closing the app and must
still require app correctness and a clean Job Object exit. The summary's
`success` describes trace collection only. On collector error, keep partial
files and fail the diagnostic; do not continue by silently disabling tracing
or increasing memory limits. Then remove the DevTools argument for future
ordinary runs. No system-wide tracing or browser settings are changed.

## Required analysis

- Preserve raw `trace-events` batches. Join memory dumps by dump GUID and
  keep their request/ack UTC brackets. Only assign an app phase when the
  bracket fits within its recorded phase; trace timestamps alone are not a
  wall-clock mapping.
- Join trace process IDs to the runner's owned PID/creation-time records.
  Report host, browser, GPU and each renderer separately, as well as the
  whole-app Private Bytes outcome from the uninstrumented collector.
  Individual window attribution needs a verified frame/window-to-PID map.
  If windows share a process, do not charge its entire footprint repeatedly.
- Inspect Blink GC, PartitionAlloc, V8, malloc and compositor/cache paths.
  Raw allocator sizes can overlap. Report the exact path and metric; do not
  add parent/child sizes or subtract sampled native estimates from the
  embedder GC heap as though they were disjoint accounts.
- Check whether a subsystem grows with DOM writes and retains committed
  pages after its live allocation estimate falls. Symbolicate only when
  the concrete owner still cannot be located from subsystem accounting.
- If the trace locates a candidate change, preserve visible content,
  cadence, checksums and source identity. Test it separately without tracing
  before accepting any RAM/CPU improvement. A same-revision A/C comparison
  remains necessary for a product claim.

## Primary references

- [Chromium MemoryInfra](https://chromium.googlesource.com/chromium/src/+/main/docs/memory-infra/README.md)
  describes subsystem accounting and overlapping size/effective-size values.
- [CDP Tracing schema](https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/pdl/domains/Tracing.pdl)
  documents `deterministic` forcing GC when enabled. The collector disables it.
- [CDP Runtime](https://chromedevtools.github.io/devtools-protocol/tot/Runtime/#method-getHeapUsage)
  describes the separate embedder GC heap measure. Live protocol/version
  compatibility still belongs in the native diagnostic record.
