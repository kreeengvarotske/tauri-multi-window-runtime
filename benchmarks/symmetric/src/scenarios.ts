// What each scenario sends and which counter deltas a round must produce.
// The expectations check correctness (coalescing and caching happen exactly
// where they should); they are not evidence of lower RAM or CPU use.

export type Build = "plain" | "runtime";
export type ScenarioId = "S1" | "S2" | "S3" | "S4";

export interface WorkParams {
  bufferMb: number;
  iterations: number;
}

/** Mirrors `BenchConfig` in Rust. */
export interface BenchConfig {
  build: Build;
  scenario: ScenarioId;
  policy: string;
  work: WorkParams;
  requestsPerWindow: number;
  durationSeconds: number;
  roundIntervalMs: number;
  idleBeforeSeconds: number;
  idleAfterSeconds: number;
  automated: boolean;
}

/** Mirrors `BenchStats` in Rust. */
export interface BenchStats {
  requestsReceived: number;
  operationsExecuted: number;
  coalescedRequests: number;
  cacheHits: number;
  failedRequests: number;
}

const SHARED_KEY = "shared";

/** S1 uses one window; the secondary still exists, so both builds have the same windows. */
export function windowsFor(scenario: ScenarioId): 1 | 2 {
  return scenario === "S1" ? 1 : 2;
}

export function keysFor(scenario: ScenarioId, window: "main" | "secondary", perWindow: number): string[] {
  if (window === "secondary" && windowsFor(scenario) === 1) return [];
  if (scenario !== "S3") return Array.from({ length: perWindow }, () => SHARED_KEY);
  const offset = window === "main" ? 0 : perWindow;
  return Array.from({ length: perWindow }, (_, i) => `key-${offset + i}`);
}

/** The counter deltas a correct round produces. `round` counts from 1. */
export function expectedDelta(build: Build, scenario: ScenarioId, round: number, perWindow: number): BenchStats {
  const total = windowsFor(scenario) * perWindow;
  const delta = (executed: number, coalesced: number, hits: number): BenchStats => ({
    requestsReceived: total,
    operationsExecuted: executed,
    coalescedRequests: coalesced,
    cacheHits: hits,
    failedRequests: 0,
  });
  if (build === "plain") return delta(total, 0, 0);
  switch (scenario) {
    case "S1":
    case "S2":
      return delta(1, total - 1, 0);
    case "S3":
      return delta(total, 0, 0);
    case "S4":
      return round === 1 ? delta(1, total - 1, 0) : delta(0, 0, total);
  }
}

export function statsDelta(before: BenchStats, after: BenchStats): BenchStats {
  return {
    requestsReceived: after.requestsReceived - before.requestsReceived,
    operationsExecuted: after.operationsExecuted - before.operationsExecuted,
    coalescedRequests: after.coalescedRequests - before.coalescedRequests,
    cacheHits: after.cacheHits - before.cacheHits,
    failedRequests: after.failedRequests - before.failedRequests,
  };
}

/** Requests that entered but have not completed. */
export function inFlight(stats: BenchStats): number {
  return stats.requestsReceived - (stats.operationsExecuted + stats.coalescedRequests + stats.cacheHits);
}
