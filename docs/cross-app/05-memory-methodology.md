# 05. Methodology: does a shared service save memory, and from how many clients?

**Status: design only. No measurement was run, and none may run until the gates in §7 pass.** This complements the in-app symmetric benchmark (#20 → #23 → #25). It does not replace it or change it.

## 1. What can and cannot be saved

The total memory of N independent apps is split into three parts, and they are reported separately:

| Part | What it is | Can a shared service reduce it? |
|---|---|---|
| **UI** | WebView2 browser, GPU, renderer and utility processes (Chromium/V8) | **No.** Each app keeps its own. Never attributed to the service |
| **Host** | The app's own Rust process: Tauri, its runtime, and in the plain arm the Core library | Only the part that moves to the broker (cache, working buffers, indexes) |
| **Broker** | The broker process (shared arm only) | It is the *cost* side |

A saving claim may only use **Host + Broker**. UI is measured to prove the arms are symmetric (an equivalence check), not to claim a benefit.

## 2. Model and break-even

Per-app quantities (time-averaged under the same load, Private bytes):

- `D`: resident data the operation keeps (cache, decoded dataset)
- `W`: average transient working memory of executions (buffers during compute)
- `T`: what the client must retain or copy per result in the shared arm (deserialised result, frame buffers)
- `ΔH`: host baseline difference between plain and shared (Core + tokio pool vs SDK client only), possibly ≈ 0
- `B0`: broker baseline; `c`: per-connection broker overhead; `W_b`: broker working memory (≈ `W` with coalescing)

```
Plain(N)  = N·(UI + H  + D + W)
Shared(N) = N·(UI + H' + T)     + (B0 + D + W_b + c·N)

Saving(N) = N·(D + W + ΔH − T − c) − (B0 + D + W_b)
N*        = (B0 + D + W_b) / (D + W + ΔH − T − c)        if the denominator > 0, else no break-even
```

Consequences:

- If each client keeps a full copy of the result (`T ≈ D`), the saving per extra client is only `W + ΔH − c`. Sharing a cache then pays off only through working memory.
- If clients keep a projection (summary, page or index lookup; `T ≪ D`), the saving grows by about `D` per client.
- Coalescing reduces `W` in the plain arm only when the apps compute **at the same time**, so load timing (§3 factor L) changes the answer.

*Illustrative arithmetic only, not data.* With `B0 = 6 MiB` (assumed), `D = W = 16 MiB`, `ΔH = 0`, `c ≈ 0`: projection (`T = 0.1 MiB`) ⇒ `N* ≈ 38/31.9 ≈ 1.2`, so shared wins from 2 clients. Full copy (`T = 16 MiB`) ⇒ `N* ≈ 38/16 ≈ 2.4`, so from 3 clients. The Stage 4 demo operation (`D ≈ 0`, `W ≈ 0`) ⇒ no break-even. That matches Stage 4: Core added nothing measurable.

## 3. Experiment design

**E1: data path (primary).** Headless client processes, so there is no WebView noise. The *same* client executable runs with `--mode plain` (in-process `CachedService`) or `--mode shared` (broker). This mirrors #20's "same binary, one switch" symmetry. **E2: with UI (secondary).** Tauri apps embedding the same client. WebView processes are measured, reported as UI and checked for equality between arms.

| Factor | Levels (pre-registered before the pilot) |
|---|---|
| N clients | 1, 2, 4, 8 |
| Arm | plain, shared |
| Dataset `D` | 0 (control), 4 MiB, 16 MiB (synthetic, `fixture.checksum`-like generator) |
| Retention | full result, projection (a fixed-size summary) |
| Load L | synchronised bursts (all clients request together), staggered (offset by one execution time) |
| Phase | idle after start, under load (fixed number of calls per client), idle after load |

The control cell `D = 0` estimates `B0`, `c` and `ΔH` directly. The cells with `D > 0` give the slopes.

**Run procedure** (reuses the #20/#25 discipline):

1. Release builds. Byte-identical client/broker executables in both arms, with hashes recorded.
2. Clean machine state: no other user apps, fixed power plan. Record OS build, WebView2 version (E2), monitor SHA and PowerShell version.
3. Warm-up run discarded. Then **paired runs with alternating order** (plain→shared, shared→plain, …) for each cell.
4. The broker is started fresh per run, so the cache starts cold. Every run waits for all clients to report "ready" before the load phase. That is a handshake, not a sleep.
5. Failed or incomplete runs are kept and reported, never replaced.
6. Pilot: 5 pairs per cell, descriptive only. Confirmatory N is fixed after the pilot, before the first confirmatory pair.

## 4. What is measured

| Metric | Windows (primary) | Linux (secondary) |
|---|---|---|
| Private (commit) bytes per process | `PrivatePageCount` via the #18/#24 monitor (unit-checked, fail-closed) | `Private_Clean + Private_Dirty` from `smaps_rollup` |
| Private working set | `WorkingSetPrivate` | USS |
| Shared pages | counted **once** (not summed across processes) | PSS sum |
| Statistics | idle median, load average, **maximum sample** (not a true peak) | same |
| Copy cost | per-call frame bytes in and out, deserialised bytes, from counters in a measurement build of the spike | same |
| CPU-seconds | **co-primary with memory**: RAM and CPU are equal confirmatory metrics (decision recorded 2026-10-26, Q8). Both are analysed with the same rules, in one multiplicity family | same |
| Latency p50/p95, throughput, errors, sample quality | reported for every run, descriptive | same |

**Process selection.** The broker is *not* a child of the apps, so a process-tree monitor rooted at one app misses it. The measurement needs an explicit PID set: all client roots, their descendants, and the broker. That is a monitor extension, i.e. a separate future PR on top of #24, not part of this package.

## 5. Analysis

- Unit of analysis: one pair (plain run, shared run) in the same cell. The outcome is `Δ = (Host+Broker)_plain − (Host+Broker)_shared` (positive = saving).
- Per cell: the median of Δ with a distribution-free CI (sign-test-based, ties kept in n, as in #25). One pre-registered family with Holm correction over the confirmatory cells.
- Break-even: fit `Total_arm(N) = a_arm + b_arm·N` on the paired medians. Then `N* = (a_shared − a_plain)/(b_plain − b_shared)`, with a bootstrap CI over pairs. If the CI upper bound exceeds 8, report "no break-even shown for N ≤ 8".
- UI equivalence (E2): |median UI_plain − UI_shared| within a pre-registered margin. If it fails, E2 cannot support any claim.
- Report everything: per-process tables, raw CSV, failed runs, and copy-cost counters next to memory.

## 6. Threats to validity

- Working memory is short-lived. A 0.2 s sampler can miss it; the #24 interval statistics must be reported and the lifetime per `D` documented.
- Allocator retention: freed buffers may stay committed. Record both private bytes and working set, and run an idle phase after load.
- Code pages of the same executable are shared by the OS. Never sum them N times.
- Coalescing needs overlap. Staggered and synchronised load can disagree, and both are reported.
- WebView2 shares a browser process only between WebViews with the same user-data folder *inside one app*. Arms must use identical WebView settings.

## 7. Gates before any run

| Gate | Condition |
|---|---|
| G-X1 | ADR [02](02-architecture-adr.md) accepted by Group 1, including Q3 (data classes) |
| G-X2 | Measurement build (plain/shared switch + copy counters) reviewed; CI green on its exact head |
| G-X3 | Monitor supports an explicit multi-root PID set; native smoke on Windows 10 (and Windows 11 if claimed) |
| G-X4 | Pilot passes the #25-style quality thresholds (sample coverage, interval distribution, monitor overhead) |
| G-X5 | Group 1 approves the protocol, outcome roles (Q8) and the time budget. The current symmetric-benchmark gates (#25) are not affected |
