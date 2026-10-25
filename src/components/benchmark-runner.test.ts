import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { RuntimeClient, RuntimeDebugStats } from "../lib/runtime";
import type { WindowBridge } from "../lib/windows";
import { BenchmarkAbortedError, createBenchmarkRunner, runPairedBenchmarkSuite } from "./benchmark-runner";

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
    return { requestId: `secondary-${requestSeriesInSecondary.mock.calls.length}`, completed: Promise.resolve({ ok: true }) };
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

/**
 * A Core stand-in with time: a series is counted as received when it starts
 * and classified when it ends, like real requests in flight. The first series
 * after a clear executes once, everything else joins it.
 */
function createTimedCore() {
  const counters = {
    requestsReceived: 0,
    operationsExecuted: 0,
    coalescedRequests: 0,
    cacheHits: 0,
    failedRequests: 0,
    cachedEntries: 0,
  };
  let executedSinceClear = false;
  const clear = vi.fn(async () => {
    counters.cachedEntries = 0;
    executedSinceClear = false;
  });
  const getStats = vi.fn(async (): Promise<RuntimeDebugStats> => ({
    ...counters,
    cachePolicy: { kind: "ttl", ttlMs: 30_000 },
  }));
  const runtime = { cache: { clear }, diagnostics: { getStats } } as unknown as Pick<
    RuntimeClient,
    "cache" | "diagnostics"
  >;

  function series(size: number, durationMs: number): Promise<void> {
    counters.requestsReceived += size;
    return new Promise((resolve) =>
      setTimeout(() => {
        if (executedSinceClear) {
          counters.coalescedRequests += size;
        } else {
          executedSinceClear = true;
          counters.operationsExecuted += 1;
          counters.coalescedRequests += size - 1;
          counters.cachedEntries = 1;
        }
        resolve();
      }, durationMs),
    );
  }

  /** Durations of the secondary series, one per request; the last one repeats. */
  const secondaryDurations: number[] = [20];
  const requestSeriesInSecondary = vi.fn(async ({ size }: { projectId: string; size: number }) => {
    const index = requestSeriesInSecondary.mock.calls.length - 1;
    const duration = secondaryDurations[Math.min(index, secondaryDurations.length - 1)];
    const completed = series(size, duration).then(() => ({ ok: true }));
    return { requestId: `secondary-${index + 1}`, completed };
  });
  const bridge = { requestSeriesInSecondary } as unknown as Pick<WindowBridge, "requestSeriesInSecondary">;
  const localDuration = { ms: 20 };
  const runLocalSeries = vi.fn((_projectId: string, size: number) => series(size, localDuration.ms));

  const snapshot = () => ({
    counters: { ...counters },
    getStats: getStats.mock.calls.length,
    clear: clear.mock.calls.length,
    secondary: requestSeriesInSecondary.mock.calls.length,
    local: runLocalSeries.mock.calls.length,
  });

  return { runtime, bridge, runLocalSeries, counters, clear, getStats, requestSeriesInSecondary, secondaryDurations, localDuration, series, snapshot };
}

const now = () => Date.now();

/** Settles `promise` while fake time runs; returns its outcome. */
async function outcome<T>(promise: Promise<T>, advanceMs: number) {
  const result = promise.then(
    (value) => ({ ok: true as const, value }),
    (error: unknown) => ({ ok: false as const, error }),
  );
  await vi.advanceTimersByTimeAsync(advanceMs);
  return result;
}

describe("runPairedBenchmarkSuite round termination", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it("waits for the secondary when the local series fails fast, and stops touching Core afterwards", async () => {
    const core = createTimedCore();
    core.secondaryDurations[0] = 2_000;
    core.runLocalSeries.mockImplementationOnce(async () => {
      throw new Error("local broke");
    });
    const started = Date.now();
    let settledAt = 0;
    const run = runPairedBenchmarkSuite({ ...core, rounds: 3, size: 50, now }).finally(() => (settledAt = Date.now()));

    const result = await outcome(run, 3_000);
    expect(result.ok).toBe(false);
    const error = (result as { error: BenchmarkAbortedError }).error;
    expect(error).toBeInstanceOf(BenchmarkAbortedError);
    expect(error.message).toMatch(/local broke/);
    expect(error.cleanup).toBe("clean");
    expect(error.roundsCompleted).toBe(0);
    // It did not give up while the secondary series was still running.
    expect(settledAt - started).toBeGreaterThanOrEqual(2_000);
    expect(core.counters.requestsReceived).toBe(50);
    expect(core.counters.operationsExecuted + core.counters.coalescedRequests).toBe(50);

    const frozen = core.snapshot();
    await vi.advanceTimersByTimeAsync(60_000);
    expect(core.snapshot()).toEqual(frozen);
  });

  it("reports a still-running secondary as dirty when it outlives the drain window", async () => {
    const core = createTimedCore();
    core.secondaryDurations[0] = 30_000;
    core.runLocalSeries.mockImplementationOnce(async () => {
      throw new Error("local broke");
    });
    const run = runPairedBenchmarkSuite({ ...core, rounds: 1, size: 50, now, drainTimeoutMs: 1_000 });

    const result = await outcome(run, 2_000);
    const error = (result as { error: BenchmarkAbortedError }).error;
    expect(error.cleanup).toBe("dirty");
    expect(error.outstanding.join()).toMatch(/secondary-1/);

    let settled = false;
    void error.settled.then(() => (settled = true));
    await vi.advanceTimersByTimeAsync(20_000);
    expect(settled).toBe(false);
    await vi.advanceTimersByTimeAsync(10_000);
    expect(settled).toBe(true);
  });

  it("times out a round whose local series arrives late, without a report or a false pass", async () => {
    const core = createTimedCore();
    core.localDuration.ms = 20_000;
    const run = runPairedBenchmarkSuite({ ...core, rounds: 2, size: 50, now, timeoutMs: 15_000 });

    const result = await outcome(run, 30_000);
    expect(result.ok).toBe(false);
    const error = (result as { error: BenchmarkAbortedError }).error;
    expect(error.message).toMatch(/не завершился за 15000 мс/);
    // The drain waited for the late local series, so nothing is left running.
    expect(error.cleanup).toBe("clean");
    expect(core.counters.requestsReceived).toBe(100);
    expect(core.requestSeriesInSecondary).toHaveBeenCalledTimes(1);

    const frozen = core.snapshot();
    await vi.advanceTimersByTimeAsync(60_000);
    expect(core.snapshot()).toEqual(frozen);
  });

  it("does not start a new run until the tail of a stopped one has left Core", async () => {
    const core = createTimedCore();
    // The stopped run's tail: a series still in flight in Core.
    const tail = core.series(50, 3_000);
    let tailEnded = 0;
    void tail.then(() => (tailEnded = Date.now()));

    const clearTimes: number[] = [];
    const clearCache = core.clear.getMockImplementation()!;
    core.clear.mockImplementation(async () => {
      clearTimes.push(Date.now());
      await clearCache();
    });
    const run = runPairedBenchmarkSuite({ ...core, rounds: 2, size: 50, now });
    const result = await outcome(run, 10_000);

    expect(result).toMatchObject({ ok: true });
    const report = (result as { value: Awaited<typeof run> }).value;
    expect(clearTimes[0]).toBeGreaterThanOrEqual(tailEnded);
    expect(report.passed).toBe(true);
    expect(report.totals.requestsReceived).toBe(200);
    expect(report.rounds.map((r) => r.secondaryRequestId)).toEqual(["secondary-1", "secondary-2"]);
  });

  it("gives up starting when Core never becomes idle", async () => {
    const core = createTimedCore();
    void core.series(50, 600_000);
    const run = runPairedBenchmarkSuite({ ...core, rounds: 1, size: 50, now, drainTimeoutMs: 2_000 });
    const result = await outcome(run, 3_000);
    const error = (result as { error: BenchmarkAbortedError }).error;
    expect(error.cleanup).toBe("dirty");
    expect(error.message).toMatch(/не начат/);
    expect(core.clear).not.toHaveBeenCalled();
    expect(core.requestSeriesInSecondary).not.toHaveBeenCalled();
  });

  it("fails the round instead of passing when a late response from earlier lands in it", async () => {
    const core = createTimedCore();
    core.secondaryDurations.splice(0, 1, 20, 500);
    // Once round 2 is under way, 50 requests nobody in this round sent arrive.
    const original = core.requestSeriesInSecondary.getMockImplementation()!;
    core.requestSeriesInSecondary.mockImplementation(async (request) => {
      const handle = await original(request);
      if (core.requestSeriesInSecondary.mock.calls.length === 2) {
        setTimeout(() => void core.series(50, 10), 100);
      }
      return handle;
    });
    const run = runPairedBenchmarkSuite({ ...core, rounds: 3, size: 50, now });
    const result = await outcome(run, 15_000);

    expect(result.ok).toBe(false);
    const error = (result as { error: BenchmarkAbortedError }).error;
    expect(error.message).toMatch(/Раунд 2: Core получил больше запросов/);
    expect(error.roundsCompleted).toBe(1);
    expect(error.cleanup).toBe("clean");
    expect(core.requestSeriesInSecondary).toHaveBeenCalledTimes(2);

    const frozen = core.snapshot();
    await vi.advanceTimersByTimeAsync(60_000);
    expect(core.snapshot()).toEqual(frozen);
  });

  it("drains when the secondary does not confirm, so a late start is not counted later", async () => {
    const core = createTimedCore();
    core.requestSeriesInSecondary.mockImplementationOnce(async () => {
      // The request reached the window just as main gave up waiting.
      void core.series(50, 1_000);
      throw new Error("Окно «secondary» не подтвердило запуск серии за 5000 мс.");
    });
    const run = runPairedBenchmarkSuite({ ...core, rounds: 1, size: 50, now });
    const result = await outcome(run, 5_000);
    const error = (result as { error: BenchmarkAbortedError }).error;
    expect(error.message).toMatch(/не подтвердило/);
    expect(error.cleanup).toBe("clean");
    expect(core.counters.requestsReceived).toBe(core.counters.operationsExecuted + core.counters.coalescedRequests);
    expect(core.runLocalSeries).not.toHaveBeenCalled();
  });
});

describe("createBenchmarkRunner", () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date", "performance"] });
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  function mount(core: ReturnType<typeof createTimedCore>) {
    const element = createBenchmarkRunner({
      runtime: core.runtime as unknown as RuntimeClient,
      bridge: core.bridge as unknown as WindowBridge,
      runLocalSeries: core.runLocalSeries,
    });
    const button = (action: string) => element.querySelector<HTMLButtonElement>(`[data-action="${action}"]`)!;
    const status = () => element.querySelector("[data-benchmark-status]")!.textContent ?? "";
    return { fixed: button("run-automated-benchmark"), timed: button("run-timed-benchmark"), status };
  }

  it("ignores repeated clicks while a run is in progress", async () => {
    const core = createTimedCore();
    const ui = mount(core);
    ui.fixed.click();
    ui.fixed.click();
    ui.timed.click();
    ui.fixed.click();
    await vi.advanceTimersByTimeAsync(10_000);

    expect(ui.status()).toMatch(/Автотест пройден/);
    expect(core.requestSeriesInSecondary).toHaveBeenCalledTimes(5);
    expect(core.runLocalSeries).toHaveBeenCalledTimes(5);
    expect(core.counters.requestsReceived).toBe(500);
  });

  it("keeps the run locked until the tail of a stopped round has ended", async () => {
    const core = createTimedCore();
    core.secondaryDurations[0] = 40_000;
    core.secondaryDurations.push(20);
    const ui = mount(core);
    ui.fixed.click();

    // Round timeout (15 s) plus the drain window (10 s): the secondary series
    // is still running, so the runner reports it and stays locked.
    await vi.advanceTimersByTimeAsync(26_000);
    expect(ui.status()).toMatch(/ещё выполняется/);
    expect(ui.fixed.disabled).toBe(true);
    expect(ui.timed.disabled).toBe(true);
    ui.fixed.click();
    ui.timed.click();
    await vi.advanceTimersByTimeAsync(5_000);
    expect(core.requestSeriesInSecondary).toHaveBeenCalledTimes(1);
    const beforeTailEnds = core.snapshot().counters;

    await vi.advanceTimersByTimeAsync(15_000);
    expect(ui.status()).toMatch(/можно запускать снова/);
    expect(ui.fixed.disabled).toBe(false);
    // Only the tail itself changed the counters; nothing new was started.
    expect(core.counters.requestsReceived).toBe(beforeTailEnds.requestsReceived);
    expect(core.requestSeriesInSecondary).toHaveBeenCalledTimes(1);
    expect(core.counters.requestsReceived).toBe(core.counters.operationsExecuted + core.counters.coalescedRequests);
  });
});
