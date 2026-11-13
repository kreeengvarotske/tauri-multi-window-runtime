# Display text cache: idle-machine diagnostic plan

Not launched. This is an exploratory within-arm comparison, not the frozen pilot or a confirmatory plan. Review the exact source/build/environment before execution. Run only when the machine is free of gaming, builds and other competing workloads.

Build one normal arm C executable from a clean candidate checkout, with no `postmessage-ipc` feature. Record Git SHA, executable and Cargo.lock SHA-256, build command, OS/WebView2, power plan and renderer source. Use the same executable for both modes. Keep all inputs and outputs separate from the frozen pilot.

`scripts/TextCacheDiagnostic.mjs` prepares the fixed schedule and audits application report modes without starting any process. From `benchmarks/catalog`, after a real build, use:

```text
node scripts/TextCacheDiagnostic.mjs prepare --scenario-revision <full-lowercase-SHA> --executable-sha256 <lowercase-SHA256> --out <new-plan.json>
node scripts/TextCacheDiagnostic.mjs audit --plan <plan.json> --plan-sha256 <recorded-plan-SHA256> --reports-directory <reports> --out <new-audit.json>
```

The prepare command prints the plan hash. Save exactly one application report named `<run.name>.json` per scheduled position in the reports directory. The audit rejects changed plans, missing/extra reports, wrong cache modes and workload mismatches, retains failed application flags, and never overwrites output files. It does not launch a runner or independently verify executable bytes, machine state, checksum computations, monitor validity, RAM or CPU. This tool does not authorize a measurement or replace the native validity checks.

For each of N2D16 and N4D64, use seed 1, 500 ms cadence and 20/30/120/30 s phases. Create a fresh process/profile for every run, retain the existing Job Object and RAM-monitor checks, and pause 30 s between runs. Prewrite these six pairs in this order:

| Pair | Cell | First | Second |
|---|---|---|---|
| 1 | N2D16 | off | on |
| 2 | N4D64 | on | off |
| 3 | N2D16 | on | off |
| 4 | N4D64 | off | on |
| 5 | N2D16 | off | on |
| 6 | N4D64 | on | off |

Pass `--text-cache off` or `--text-cache on` explicitly and verify `config.textCache` in every report. The ordinary triplet runner does not pass this flag: do not relabel its default runs as cache-enabled. Any diagnostic runner extension must record mode and schedule before launch and must not bypass its provenance/validity checks.

Retain every attempt, including invalids, without replacement. Report paired on-minus-off differences in whole-tree load Private Bytes and whole-run Job CPU, plus both raw values, validity reasons, latency, startup, checksum failures, completed steps and overruns. Do not equate the cache's UTF-16 payload estimate with OS RAM. Keep profiler-enabled runs separate from the primary diagnostic comparison.

If the cache raises either co-primary cost or harms correctness/latency, retain that result and reconsider enabling it. With three pairs per cell, report observations and spread only; do not claim equivalence or general savings. Even a favorable result does not approve a new pilot/confirmatory freeze or a product release.
