import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { vi } from "vitest";
import type { Bridge } from "./bridge";
import { type Invoke, type RunnerDeps, type SeriesRequest, type SeriesResult, distribution, runScenario, runSeries } from "./runner";
import type { BenchConfig, BenchStats, Build, ScenarioId } from "./scenarios";

const OPERATION_MS = 200;

/**
 * A fake backend with the semantics of each build: plain runs every request;
 * runtime coalesces concurrent requests per key and, with a TTL, serves
 * later ones from its cache.
 */
function fakeBackend(build: Build, options: { ttl?: boolean; coalesce?: boolean; checksum?: (key: string) => string } = {}) {
  const stats: BenchStats = { requestsReceived: 0, operationsExecuted: 0, coalescedRequests: 0, cacheHits: 0, failedRequests: 0 };
  const inFlight = new Map<string, Promise<string>>();
  const cache = new Map<string, string>();
  const checksum = options.checksum ?? ((key: string) => `sum-${key}`);
  const coalesce = options.coalesce ?? build === "runtime";
  const execute = (key: string) => new Promise<string>((resolve) => setTimeout(() => resolve(checksum(key)), OPERATION_MS));
  const invoke = (async (command: string, args?: Record<string, unknown>) => {
    const key = String(args?.key ?? "");
    if (command === "bench_stats") return { ...stats };
    if (command === "bench_expected") return `sum-${key}`;
    if (command !== "bench_run") throw new Error(`unexpected command ${command}`);
    stats.requestsReceived += 1;
    if (build === "runtime" && options.ttl && cache.has(key)) {
      stats.cacheHits += 1;
      return { checksum: cache.get(key), kind: "cacheHit" };
    }
    const shared = coalesce ? inFlight.get(key) : undefined;
    if (shared) {
      const value = await shared;
      stats.coalescedRequests += 1;
      return { checksum: value, kind: "coalesced" };
    }
    const running = execute(key);
    if (coalesce) inFlight.set(key, running);
    const value = await running;
    inFlight.delete(key);
    if (build === "runtime" && options.ttl) cache.set(key, value);
    stats.operationsExecuted += 1;
    return { checksum: value, kind: "executed" };
  }) as Invoke;
  return { invoke, stats };
}

/** The secondary runs its series in the same backend, after `ackDelayMs`. */
function fakeBridge(invoke: Invoke, behaviour: { failAtRequest?: number; ackDelayMs?: number } = {}) {
  let requests = 0;
  const bridge: Bridge<SeriesRequest, SeriesResult> = {
    async request(request) {
      requests += 1;
      if (behaviour.failAtRequest !== undefined && requests >= behaviour.failAtRequest) {
        throw new Error("The secondary window is not open.");
      }
      const completed = runSeries(invoke, request, () => Date.now()).then((result) => ({ ok: true, result }));
      await new Promise((resolve) => setTimeout(resolve, behaviour.ackDelayMs ?? 1));
      return { requestId: `r${requests}`, completed };
    },
    serve: async () => () => {},
  };
  return { bridge, requests: () => requests };
}

function configFor(build: Build, scenario: ScenarioId, overrides: Partial<BenchConfig> = {}): BenchConfig {
  return {
    build,
    scenario,
    policy: build === "plain" ? "none" : scenario === "S4" ? "ttl:3600000" : "noStore",
    work: { bufferMb: 4, iterations: 100 },
    requestsPerWindow: scenario === "S1" ? 1 : 10,
    durationSeconds: 5,
    roundIntervalMs: 500,
    idleBeforeSeconds: 1,
    idleAfterSeconds: 1,
    potentialConcurrentBufferMb: 80,
    automated: false,
    ...overrides,
  };
}

function depsFor(invoke: Invoke, bridge: Bridge<SeriesRequest, SeriesResult>): RunnerDeps {
  return {
    invoke,
    bridge,
    now: () => Date.now(),
    wallClock: () => new Date().toISOString(),
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  };
}

async function run(config: BenchConfig, deps: RunnerDeps) {
  const report = runScenario(config, deps);
  await vi.advanceTimersByTimeAsync(60_000);
  return report;
}

beforeEach(() => {
  vi.useFakeTimers();
});
afterEach(() => {
  vi.useRealTimers();
});

describe("runScenario", () => {
  it.each(["S1", "S2", "S3", "S4"] as const)("plain %s: every request runs the operation", async (scenario) => {
    const backend = fakeBackend("plain");
    const report = await run(configFor("plain", scenario), depsFor(backend.invoke, fakeBridge(backend.invoke).bridge));
    expect(report.passed).toBe(true);
    expect(report.totals.operationsExecuted).toBe(report.totals.requestsReceived);
    expect(report.totals.coalescedRequests + report.totals.cacheHits).toBe(0);
  });

  it("runtime S2: one execution per round, the rest coalesced", async () => {
    const backend = fakeBackend("runtime");
    const report = await run(configFor("runtime", "S2"), depsFor(backend.invoke, fakeBridge(backend.invoke).bridge));
    expect(report.passed).toBe(true);
    expect(report.rounds.every((r) => r.delta.operationsExecuted === 1 && r.delta.coalescedRequests === 19)).toBe(true);
  });

  it("runtime S3: distinct keys are never coalesced", async () => {
    const backend = fakeBackend("runtime");
    const report = await run(configFor("runtime", "S3"), depsFor(backend.invoke, fakeBridge(backend.invoke).bridge));
    expect(report.passed).toBe(true);
    expect(report.totals.coalescedRequests).toBe(0);
  });

  it("runtime S4: the first round executes once, later rounds are cache hits", async () => {
    const backend = fakeBackend("runtime", { ttl: true });
    const report = await run(configFor("runtime", "S4"), depsFor(backend.invoke, fakeBridge(backend.invoke).bridge));
    expect(report.passed).toBe(true);
    expect(report.rounds[0].delta).toMatchObject({ operationsExecuted: 1, coalescedRequests: 19, cacheHits: 0 });
    expect(report.rounds.slice(1).every((r) => r.delta.cacheHits === 20 && r.delta.operationsExecuted === 0)).toBe(true);
    expect(report.totals.operationsExecuted).toBe(1);
  });

  it("does not pass a runtime build whose requests were not coalesced", async () => {
    const backend = fakeBackend("runtime", { coalesce: false });
    const report = await run(configFor("runtime", "S2"), depsFor(backend.invoke, fakeBridge(backend.invoke).bridge));
    expect(report.passed).toBe(false);
    expect(report.rounds[0].reasons).toContain("operationsExecuted: expected 1, got 20");
  });

  it("does not pass when a response has the wrong checksum", async () => {
    const backend = fakeBackend("plain", { checksum: () => "wrong" });
    const report = await run(configFor("plain", "S2"), depsFor(backend.invoke, fakeBridge(backend.invoke).bridge));
    expect(report.passed).toBe(false);
    expect(report.rounds[0].mismatches).toBe(20);
  });

  it("starts rounds at a fixed cadence, so both builds get the same offered load", async () => {
    const plain = fakeBackend("plain");
    const runtime = fakeBackend("runtime", { ttl: true });
    const a = await run(configFor("plain", "S4"), depsFor(plain.invoke, fakeBridge(plain.invoke).bridge));
    const b = await run(configFor("runtime", "S4"), depsFor(runtime.invoke, fakeBridge(runtime.invoke).bridge));
    expect(a.rounds.map((r) => r.scheduledAtMs)).toEqual([0, 500, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 4500]);
    expect(b.rounds.length).toBe(a.rounds.length);
    expect(a.totals.requestsReceived).toBe(b.totals.requestsReceived);
    expect(a.rounds.every((r) => !r.overrun)).toBe(true);
  });

  it("marks a round that takes longer than the interval as an overrun", async () => {
    const backend = fakeBackend("plain");
    const report = await run(configFor("plain", "S2", { roundIntervalMs: 100 }), depsFor(backend.invoke, fakeBridge(backend.invoke).bridge));
    expect(report.rounds[0].overrun).toBe(true);
    expect(report.summary.overruns).toBe(report.rounds.length);
  });

  it("stops the load and drains when the secondary fails, without a false pass", async () => {
    const backend = fakeBackend("plain");
    // Request 1 is the readiness ping; the third round fails.
    const { bridge } = fakeBridge(backend.invoke, { failAtRequest: 4 });
    const report = await run(configFor("plain", "S2"), depsFor(backend.invoke, bridge));
    expect(report.passed).toBe(false);
    expect(report.rounds).toHaveLength(2);
    expect(report.abort).toMatchObject({ cleanup: "clean", inFlightAfterDrain: 0 });
    // Nothing from the aborted round is counted as a completed round.
    expect(report.totals.requestsReceived).toBe(40);
  });

  it("reports a dirty drain when requests are still running at the deadline", async () => {
    const backend = fakeBackend("plain");
    const stuck = (async (command: string, args?: Record<string, unknown>) => {
      if (command === "bench_stats") return { ...backend.stats, requestsReceived: backend.stats.requestsReceived + 3 };
      return backend.invoke(command, args);
    }) as Invoke;
    const { bridge } = fakeBridge(stuck, { failAtRequest: 2 });
    const report = await run(configFor("plain", "S2"), { ...depsFor(stuck, bridge), drainTimeoutMs: 1_000 });
    expect(report.abort).toMatchObject({ cleanup: "dirty", inFlightAfterDrain: 3 });
    expect(report.passed).toBe(false);
  });

  it("waits for a slow secondary when main fails fast, before reading counters or starting a round", async () => {
    const secondaryBackend = fakeBackend("plain");
    const log: { at: number; what: string }[] = [];
    // Main's own requests fail at once; the secondary's take 2 s.
    const mainInvoke = (async (command: string, args?: Record<string, unknown>) => {
      if (command === "bench_run") {
        log.push({ at: Date.now(), what: "main-failed" });
        throw new Error("main side broke");
      }
      if (command === "bench_stats") log.push({ at: Date.now(), what: "stats" });
      return secondaryBackend.invoke(command, args);
    }) as Invoke;
    const slowSecondary = (async (command: string, args?: Record<string, unknown>) => {
      if (command === "bench_run") await new Promise((resolve) => setTimeout(resolve, 2_000));
      const result = await secondaryBackend.invoke(command, args);
      return result;
    }) as Invoke;
    let requests = 0;
    const bridge: Bridge<SeriesRequest, SeriesResult> = {
      async request(request) {
        requests += 1;
        const completed = runSeries(slowSecondary, request, () => Date.now()).then((result) => {
          if (request.keys.length > 0) log.push({ at: Date.now(), what: "secondary-done" });
          return { ok: true, result };
        });
        return { requestId: `r${requests}`, completed };
      },
      serve: async () => () => {},
    };
    const report = await run(configFor("plain", "S2", { durationSeconds: 3 }), depsFor(mainInvoke, bridge));

    const firstFailure = log.find((e) => e.what === "main-failed")!.at;
    const secondaryDone = log.find((e) => e.what === "secondary-done")!.at;
    expect(secondaryDone - firstFailure).toBeGreaterThanOrEqual(2_000);
    // No counter read and no new round while the secondary's half was still running.
    expect(log.filter((e) => e.what === "stats" && e.at > firstFailure && e.at < secondaryDone)).toHaveLength(0);
    expect(report.rounds[0].durationMs).toBeGreaterThanOrEqual(2_000);
    expect(report.rounds[0].passed).toBe(false);
    expect(report.rounds[0].failures).toBe(10);
    // The round's counters include all of the secondary's requests, and nothing is left running.
    expect(report.rounds[0].delta.requestsReceived).toBe(10);
    expect(report.totals.requestsReceived).toBe(report.rounds.length * 10);
    expect(report.passed).toBe(false);
  });

  it("finishes main's half before aborting when the secondary fails fast", async () => {
    const backend = fakeBackend("plain");
    const log: string[] = [];
    const logged = (async (command: string, args?: Record<string, unknown>) => {
      const result = await backend.invoke(command, args);
      if (command === "bench_run") log.push("main-request-done");
      if (command === "bench_stats") log.push("stats");
      return result;
    }) as Invoke;
    let requests = 0;
    const bridge: Bridge<SeriesRequest, SeriesResult> = {
      async request() {
        requests += 1;
        // The readiness ping succeeds; the first round's secondary half fails at once.
        if (requests === 1) return { requestId: "ping", completed: Promise.resolve({ ok: true }) };
        log.push("secondary-failed");
        return { requestId: `r${requests}`, completed: Promise.resolve({ ok: false, error: "secondary broke" }) };
      },
      serve: async () => () => {},
    };
    const report = await run(configFor("plain", "S2"), depsFor(logged, bridge));

    expect(report.rounds).toHaveLength(0);
    expect(report.abort).toMatchObject({ error: "secondary: secondary broke", cleanup: "clean", inFlightAfterDrain: 0 });
    // All 10 of main's requests completed before the drain read the counters.
    const failedAt = log.indexOf("secondary-failed");
    const firstStatsAfter = log.indexOf("stats", failedAt);
    expect(log.slice(failedAt, firstStatsAfter).filter((e) => e === "main-request-done")).toHaveLength(10);
    expect(report.passed).toBe(false);
  });

  it("waits at startup for a secondary that Tauri does not find yet", async () => {
    const backend = fakeBackend("plain");
    const inner = fakeBridge(backend.invoke).bridge;
    const visibleAt = Date.now() + 1_500;
    let refused = 0;
    const bridge: Bridge<SeriesRequest, SeriesResult> = {
      async request(request) {
        if (Date.now() < visibleAt) {
          refused += 1;
          throw new Error("The secondary window is not open.");
        }
        return inner.request(request);
      },
      serve: inner.serve,
    };
    const report = await run(configFor("plain", "S2"), depsFor(backend.invoke, bridge));
    expect(refused).toBeGreaterThan(1);
    expect(report.passed).toBe(true);
  });

  it("fails clearly when the secondary never becomes ready, before any load", async () => {
    const backend = fakeBackend("plain");
    const bridge: Bridge<SeriesRequest, SeriesResult> = {
      request: async () => {
        throw new Error("The secondary window is not open.");
      },
      serve: async () => () => {},
    };
    const outcome = runScenario(configFor("plain", "S2"), { ...depsFor(backend.invoke, bridge), readinessTimeoutMs: 3_000 }).then(
      () => "resolved",
      (error: Error) => error.message,
    );
    await vi.advanceTimersByTimeAsync(5_000);
    expect(await outcome).toMatch(/never became ready within 3000 ms/);
    expect(backend.stats.requestsReceived).toBe(0);
  });

  it("S1 sends one request per round and uses the secondary only to check it is ready", async () => {
    const backend = fakeBackend("runtime");
    const bridge = fakeBridge(backend.invoke);
    const report = await run(configFor("runtime", "S1"), depsFor(backend.invoke, bridge.bridge));
    expect(report.passed).toBe(true);
    expect(bridge.requests()).toBe(1);
    expect(report.rounds.every((r) => r.delta.requestsReceived === 1 && r.secondaryMs === null)).toBe(true);
  });

  it("computes the expected checksums before the load, outside the counters", async () => {
    const backend = fakeBackend("plain");
    const report = await run(configFor("plain", "S3"), depsFor(backend.invoke, fakeBridge(backend.invoke).bridge));
    expect(Object.keys(report.expectedChecksums)).toHaveLength(20);
    expect(report.totals.requestsReceived).toBe(report.rounds.length * 20);
  });
});

describe("distribution", () => {
  it("uses nearest-rank percentiles", () => {
    expect(distribution([])).toBeNull();
    expect(distribution([5, 1, 3, 2, 4])).toEqual({ p50: 3, p95: 5, max: 5 });
  });
});
