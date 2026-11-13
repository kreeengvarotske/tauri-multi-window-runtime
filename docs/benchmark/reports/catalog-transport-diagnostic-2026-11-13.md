# Catalog IPC transport diagnostic, 13 November 2026

**Exploratory negative result:** the JSON postMessage/eval transport did not remove the renderer Private Bytes plateau. This is a diagnostic build, not a production transport proposal or a confirmatory experiment.

The opt-in `postmessage-ipc` feature at `1a4967e9be7da2f49bdaf07053f752c9a888f87b` uses the public Tauri 2.12.5 `Builder::invoke_system` hook. It changes request delivery and response serialization/delivery together. Existing backend integrity and capability checks remain in force. Binary inputs, channels and custom serializers are outside its scope. Normal arm builds do not enable it.

The executable SHA-256 is `43e65ed7c6c140e342720747d25c8bb9b19cd4ca1d1a9991fd6f543725723543`. It was built with `tauri/custom-protocol,framework,postmessage-ipc`, the same Cargo.lock as the frozen pilot (`45b16b045635048ecd4b87ae797cc49764128b5cf787a20109afe67e88603638`), and the same bounded-renderer frontend as `ac97554`. Frontend bundle SHA-256: `fa2a90e3536832cb42721bd83272c21263054be86ed541635eac571388177bc0`.

Two arm C, N2D16 checks on Windows build 26200 / WebView2 `157.0.4341.46` used fresh processes and profiles, 5 s idle-before, 5 s warmup, 40 s load, 15 s idle-after and 500 ms steps. Both completed all 160 scheduled steps with zero failures, mismatches or overruns; exit code was 0, with no timeout or leftover job processes.

| Variant | Instrumentation | Mean load Private per renderer, MiB |
|---|---|---:|
| Bounded renderer, default fetch IPC | Roles only | 92.12 |
| Bounded renderer, default fetch IPC | Roles + read-only CDP | 90.44 |
| Bounded renderer, postMessage/eval | Roles only | 91.29 |
| Bounded renderer, postMessage/eval | Roles + read-only CDP | 91.42 |

The instrumented postMessage check still reached 59.63 MiB embedder GC heap in a page, versus 60.10 MiB with fetch; the load means were 14.63 and 14.75 MiB respectively. Its mean used JS heap was 2.43 MiB per page, versus 1.31 MiB with fetch. These checks provide no support for a fetch-only explanation of the large native/committed footprint. They do not establish transport equivalence or a latency/CPU improvement; each variant has only one check per instrumentation condition.

Unit verification: 19 frontend tests and five JSON-envelope tests passed; TypeScript/Vite build, rustfmt and diff checks passed. The new tests are included in `npm test`. A separate source review checked the pinned Tauri hook, closure-held key, forced non-Channel response flag and unchanged default feature path.

Local evidence is under `.codex-worktrees/catalog-memory-investigation/target/roles-postmessage-cdp-b28f2f33` and `roles-postmessage-6c576319`; the native executable, build record and build log remain in `.codex-worktrees/catalog-ipc-diagnostic/target/transport-diagnostic` and `target-postmessage-build.log`. The unchanged default-transport checks and method limits are documented in `catalog-memory-investigation-2026-11-13.md` on PR #63. The original 72-run pilot remains unchanged in PR #64.
