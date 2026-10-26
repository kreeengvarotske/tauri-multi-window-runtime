import { describe, expect, it } from "vitest";
import { buildRunReport } from "./report";
import type { CatalogConfig, Plan, WindowReport } from "./window";

const config = { windows: 2 } as CatalogConfig;
const plan: Plan = { idleBeforeAtMs: 0, warmupAtMs: 1000, loadAtMs: 2000, loadEndMs: 4000, idleAfterEndMs: 5000 };

function window(label: string, overrides: Partial<WindowReport["load"]> = {}, passed = true): WindowReport {
  return {
    label, windowIndex: 0, arm: "B",
    setup: { timeToFirstPageMs: 10, loadMs: null, indexMs: null, records: null },
    load: { scheduledSteps: 4, completedSteps: 4, failures: 0, mismatches: 0, overruns: 0, latencyMs: { p50: 1, p95: 3, max: 4 }, latencyByKindMs: {}, ...overrides },
    warmup: { completedSteps: 2, failures: 0, mismatches: 0 },
    heap: { samples: [], loadAvgBytes: 100, supported: true },
    firstError: null,
    passed,
  };
}

describe("buildRunReport", () => {
  it("passes when every window passed and sums the totals", () => {
    const report = buildRunReport(config, plan, { main: window("main"), w1: window("w1") });
    expect(report.passed).toBe(true);
    expect(report.phases.loadStartedAt).toBe("1970-01-01T00:00:02.000Z");
    expect(report.totals).toMatchObject({ scheduledSteps: 8, completedSteps: 8, maxP95LatencyMs: 3, loadJsHeapAvgBytes: 200 });
  });

  it("fails on a failed, missing or unfinished window", () => {
    expect(buildRunReport(config, plan, { main: window("main"), w1: window("w1", { failures: 1 }, false) }).passed).toBe(false);
    const missing = buildRunReport(config, plan, { main: window("main") });
    expect(missing.problems).toEqual(["expected 2 window reports, got 1"]);
    const unfinished = buildRunReport(config, plan, { main: window("main"), w1: { label: "w1", error: "closed", passed: false } });
    expect(unfinished.passed).toBe(false);
    expect(unfinished.problems[0]).toContain("w1: did not finish: closed");
    expect(unfinished.totals.completedSteps).toBe(4);
  });
});
