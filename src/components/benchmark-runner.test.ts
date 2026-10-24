import { describe, expect, it, vi } from "vitest";
import type { RuntimeClient, RuntimeDebugStats } from "../lib/runtime";
import type { WindowBridge } from "../lib/windows";
import { runPairedBenchmarkSuite } from "./benchmark-runner";

function createHarness(options: { simulateCacheHits?: boolean } = {}) {
  const counters = {
    requestsReceived: 0,
    operationsExecuted: 0,
    coalescedRequests: 0,
    cacheHits: 0,
    failedRequests: 0,
    cachedEntries: 0,
  };
  const clear = vi.fn(async () => {
    counters.cachedEntries = 0;
  });
  const getStats = vi.fn(async (): Promise<RuntimeDebugStats> => ({
    ...counters,
    cachePolicy: { kind: "ttl", ttlMs: 30_000 },
  }));
  const runtime = {
    cache: { clear },
    diagnostics: { getStats },
  } as unknown as Pick<RuntimeClient, "cache" | "diagnostics">;

  const requestSeriesInSecondary = vi.fn(async ({ size }: { projectId: string; size: number }) => {
    counters.requestsReceived += size;
    counters.operationsExecuted += 1;
    counters.coalescedRequests += size - 1;
    counters.cachedEntries = 1;
  });
  const bridge = { requestSeriesInSecondary } as unknown as Pick<WindowBridge, "requestSeriesInSecondary">;

  const runLocalSeries = vi.fn(async (_projectId: string, size: number) => {
    counters.requestsReceived += size;
    if (options.simulateCacheHits) {
      counters.cacheHits += size;
    } else {
      counters.coalescedRequests += size;
    }
  });

  return { runtime, bridge, runLocalSeries, clear, getStats, requestSeriesInSecondary, counters };
}

describe("runPairedBenchmarkSuite", () => {
  it("clears the cache and verifies each concurrent pair using Core counter deltas", async () => {
    const harness = createHarness();
    const report = await runPairedBenchmarkSuite({
      ...harness,
      rounds: 5,
      size: 50,
      now: (() => {
        let clock = 0;
        return () => (clock += 25);
      })(),
    });

    expect(harness.clear).toHaveBeenCalledTimes(5);
    expect(harness.requestSeriesInSecondary).toHaveBeenCalledTimes(5);
    expect(harness.runLocalSeries).toHaveBeenCalledTimes(5);
    expect(report.requestsExpected).toBe(500);
    expect(report.totals).toEqual({
      requestsReceived: 500,
      operationsExecuted: 5,
      coalescedRequests: 495,
      cacheHits: 0,
      failedRequests: 0,
    });
    expect(report.rounds.every((round) => round.passed)).toBe(true);
    expect(report.passed).toBe(true);
  });

  it("fails the round when the second window is served from cache", async () => {
    const harness = createHarness({ simulateCacheHits: true });
    const report = await runPairedBenchmarkSuite({
      ...harness,
      rounds: 1,
      size: 50,
    });

    expect(report.totals.cacheHits).toBe(50);
    expect(report.rounds[0].passed).toBe(false);
    expect(report.passed).toBe(false);
  });

  it("supports a timed load until the requested interval elapses", async () => {
    const harness = createHarness();
    const report = await runPairedBenchmarkSuite({
      ...harness,
      durationSeconds: 5,
      size: 50,
      now: (() => {
        let clock = 0;
        return () => (clock += 500);
      })(),
    });

    expect(report.runType).toBe("timed-load");
    expect(report.roundsRequested).toBeNull();
    expect(report.roundsCompleted).toBeGreaterThan(0);
    expect(report.requestsExpected).toBe(report.roundsCompleted * 100);
    expect(report.passed).toBe(true);
  });

  it("rejects an invalid number of rounds before clearing cache", async () => {
    const harness = createHarness();
    await expect(
      runPairedBenchmarkSuite({ ...harness, rounds: 0 }),
    ).rejects.toThrow("Количество раундов");
    expect(harness.clear).not.toHaveBeenCalled();
  });
});
