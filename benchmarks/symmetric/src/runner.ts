// The round loop, identical for both builds. Rounds start at a fixed cadence,
// so both builds get the same offered load; a round that takes longer than
// the interval delays the next one and is marked as an overrun.

import type { Bridge } from "./bridge";
import {
  type BenchConfig,
  type BenchStats,
  expectedDelta,
  inFlight,
  keysFor,
  statsDelta,
  windowsFor,
} from "./scenarios";

export type Invoke = <T>(command: string, args?: Record<string, unknown>) => Promise<T>;

export interface SeriesRequest {
  keys: string[];
  expected: Record<string, string>;
}

export interface SeriesResult {
  successes: number;
  failures: number;
  /** Responses whose checksum differs from the expected one. */
  mismatches: number;
  durationMs: number;
  firstError: string | null;
}

export interface RunnerDeps {
  invoke: Invoke;
  bridge: Bridge<SeriesRequest, SeriesResult>;
  now(): number;
  wallClock(): string;
  sleep(milliseconds: number): Promise<void>;
  onProgress?(text: string): void;
  /** How many 5 s handshake attempts to wait for the secondary page at startup. */
  readinessAttempts?: number;
  drainTimeoutMs?: number;
}

export interface RoundResult {
  round: number;
  scheduledAtMs: number;
  startedAtMs: number;
  durationMs: number;
  mainMs: number;
  secondaryMs: number | null;
  overrun: boolean;
  expected: BenchStats;
  delta: BenchStats;
  successes: number;
  failures: number;
  mismatches: number;
  passed: boolean;
  reasons: string[];
}

export interface Distribution {
  p50: number;
  p95: number;
  max: number;
}

export interface BenchReport {
  schemaVersion: 1;
  config: BenchConfig;
  phases: Record<string, string>;
  /** The expected checksum of every key, computed before the load. */
  expectedChecksums: Record<string, string>;
  rounds: RoundResult[];
  totals: BenchStats;
  summary: {
    rounds: number;
    passedRounds: number;
    overruns: number;
    loadDurationMs: number;
    requestsPerSecond: number;
    roundMs: Distribution | null;
    mainMs: Distribution | null;
    secondaryMs: Distribution | null;
  };
  abort: null | { error: string; cleanup: "clean" | "dirty"; inFlightAfterDrain: number };
  passed: boolean;
}

/** Sends one window's requests at once and checks every checksum. */
export async function runSeries(invoke: Invoke, request: SeriesRequest, now: () => number): Promise<SeriesResult> {
  const started = now();
  const settled = await Promise.allSettled(
    request.keys.map((key) => invoke<{ checksum: string }>("bench_run", { key })),
  );
  let successes = 0;
  let mismatches = 0;
  let firstError: string | null = null;
  settled.forEach((outcome, index) => {
    if (outcome.status === "fulfilled") {
      successes += 1;
      if (outcome.value.checksum !== request.expected[request.keys[index]]) mismatches += 1;
    } else {
      firstError ??= String(outcome.reason);
    }
  });
  return { successes, failures: settled.length - successes, mismatches, durationMs: round2(now() - started), firstError };
}

export async function runScenario(config: BenchConfig, deps: RunnerDeps): Promise<BenchReport> {
  const { invoke, bridge } = deps;
  const phases: Record<string, string> = { startedAt: deps.wallClock() };
  const perWindow = config.requestsPerWindow;
  const mainKeys = keysFor(config.scenario, "main", perWindow);
  const secondaryKeys = keysFor(config.scenario, "secondary", perWindow);
  const twoWindows = windowsFor(config.scenario) === 2;
  const progress = (text: string) => deps.onProgress?.(text);

  // Both builds always run two windows; wait until the secondary page serves.
  progress("Waiting for the secondary window…");
  await waitForSecondary(bridge, deps.readinessAttempts ?? 6);
  phases.secondaryReadyAt = deps.wallClock();

  progress("Computing expected checksums…");
  const expected: Record<string, string> = {};
  for (const key of new Set([...mainKeys, ...secondaryKeys])) {
    expected[key] = await invoke<string>("bench_expected", { key });
  }
  phases.expectedReadyAt = deps.wallClock();

  progress(`Idle for ${config.idleBeforeSeconds} s…`);
  await deps.sleep(config.idleBeforeSeconds * 1000);

  const before = await invoke<BenchStats>("bench_stats");
  phases.loadStartedAt = deps.wallClock();
  const loadStarted = deps.now();
  const loadEnds = loadStarted + config.durationSeconds * 1000;
  const rounds: RoundResult[] = [];
  let abort: BenchReport["abort"] = null;

  while (deps.now() < loadEnds) {
    const round = rounds.length + 1;
    const scheduledAtMs = (round - 1) * config.roundIntervalMs;
    const wait = loadStarted + scheduledAtMs - deps.now();
    if (wait > 0) await deps.sleep(wait);
    if (deps.now() >= loadEnds) break;
    progress(`Round ${round}…`);
    try {
      rounds.push(await runRound(config, deps, round, scheduledAtMs, loadStarted, mainKeys, twoWindows ? secondaryKeys : null, expected));
    } catch (error) {
      abort = await drain(deps, error);
      break;
    }
  }
  const loadDurationMs = round2(deps.now() - loadStarted);
  phases.loadEndedAt = deps.wallClock();
  const after = await invoke<BenchStats>("bench_stats");

  progress(`Idle for ${config.idleAfterSeconds} s…`);
  await deps.sleep(config.idleAfterSeconds * 1000);
  phases.endedAt = deps.wallClock();

  const totals = statsDelta(before, after);
  const expectedTotals = rounds.reduce<BenchStats>(
    (sum, r) => ({
      requestsReceived: sum.requestsReceived + r.expected.requestsReceived,
      operationsExecuted: sum.operationsExecuted + r.expected.operationsExecuted,
      coalescedRequests: sum.coalescedRequests + r.expected.coalescedRequests,
      cacheHits: sum.cacheHits + r.expected.cacheHits,
      failedRequests: 0,
    }),
    { requestsReceived: 0, operationsExecuted: 0, coalescedRequests: 0, cacheHits: 0, failedRequests: 0 },
  );
  const passedRounds = rounds.filter((r) => r.passed).length;
  return {
    schemaVersion: 1,
    config,
    phases,
    expectedChecksums: expected,
    rounds,
    totals,
    summary: {
      rounds: rounds.length,
      passedRounds,
      overruns: rounds.filter((r) => r.overrun).length,
      loadDurationMs,
      requestsPerSecond: loadDurationMs > 0 ? round2(totals.requestsReceived / (loadDurationMs / 1000)) : 0,
      roundMs: distribution(rounds.map((r) => r.durationMs)),
      mainMs: distribution(rounds.map((r) => r.mainMs)),
      secondaryMs: distribution(rounds.flatMap((r) => (r.secondaryMs === null ? [] : [r.secondaryMs]))),
    },
    abort,
    passed:
      abort === null &&
      rounds.length > 0 &&
      passedRounds === rounds.length &&
      sameStats(totals, expectedTotals),
  };
}

async function runRound(
  config: BenchConfig,
  deps: RunnerDeps,
  round: number,
  scheduledAtMs: number,
  loadStarted: number,
  mainKeys: string[],
  secondaryKeys: string[] | null,
  expected: Record<string, string>,
): Promise<RoundResult> {
  const before = await deps.invoke<BenchStats>("bench_stats");
  const started = deps.now();
  // The secondary starts first: it confirms only after it has sent its
  // requests, so main's requests overlap them.
  const secondary = secondaryKeys ? await deps.bridge.request({ keys: secondaryKeys, expected }) : null;
  const [main, secondaryDone] = await Promise.all([
    runSeries(deps.invoke, { keys: mainKeys, expected }, deps.now),
    secondary?.completed ?? Promise.resolve(null),
  ]);
  if (secondaryDone && !secondaryDone.ok) throw new Error(`secondary: ${secondaryDone.error}`);
  const durationMs = round2(deps.now() - started);
  // Every request has returned, so the counters are final for this round.
  const after = await deps.invoke<BenchStats>("bench_stats");
  const delta = statsDelta(before, after);
  const want = expectedDelta(config.build, config.scenario, round, config.requestsPerWindow);
  const secondaryResult = secondaryDone?.result ?? null;
  const successes = main.successes + (secondaryResult?.successes ?? 0);
  const failures = main.failures + (secondaryResult?.failures ?? 0);
  const mismatches = main.mismatches + (secondaryResult?.mismatches ?? 0);

  const reasons: string[] = [];
  for (const name of Object.keys(want) as (keyof BenchStats)[]) {
    if (delta[name] !== want[name]) reasons.push(`${name}: expected ${want[name]}, got ${delta[name]}`);
  }
  if (failures > 0) reasons.push(`${failures} request(s) failed: ${main.firstError ?? secondaryResult?.firstError}`);
  if (mismatches > 0) reasons.push(`${mismatches} response(s) had a wrong checksum`);
  const nextScheduled = loadStarted + round * config.roundIntervalMs;
  return {
    round,
    scheduledAtMs,
    startedAtMs: round2(started - loadStarted),
    durationMs,
    mainMs: main.durationMs,
    secondaryMs: secondaryResult?.durationMs ?? null,
    overrun: deps.now() > nextScheduled,
    expected: want,
    delta,
    successes,
    failures,
    mismatches,
    passed: reasons.length === 0,
    reasons,
  };
}

async function waitForSecondary(bridge: RunnerDeps["bridge"], attempts: number): Promise<void> {
  let lastError: unknown = null;
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    try {
      const ping = await bridge.request({ keys: [], expected: {} });
      const done = await ping.completed;
      if (done.ok) return;
      lastError = new Error(done.error);
    } catch (error) {
      lastError = error;
    }
  }
  throw new Error(`The secondary window never became ready: ${String(lastError)}`);
}

/** After a failure, waits until requests already sent have finished, so none is left running. */
async function drain(deps: RunnerDeps, error: unknown): Promise<NonNullable<BenchReport["abort"]>> {
  const timeoutMs = deps.drainTimeoutMs ?? 10_000;
  const deadline = deps.now() + timeoutMs;
  let quiet = 0;
  let pending = Number.NaN;
  while (deps.now() < deadline) {
    pending = inFlight(await deps.invoke<BenchStats>("bench_stats"));
    quiet = pending === 0 ? quiet + 1 : 0;
    if (quiet >= 3) break;
    await deps.sleep(50);
  }
  return {
    error: error instanceof Error ? error.message : String(error),
    cleanup: quiet >= 3 ? "clean" : "dirty",
    inFlightAfterDrain: pending,
  };
}

export function distribution(values: number[]): Distribution | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const rank = (p: number) => sorted[Math.min(sorted.length - 1, Math.ceil(p * sorted.length) - 1)];
  return { p50: rank(0.5), p95: rank(0.95), max: sorted[sorted.length - 1] };
}

function sameStats(a: BenchStats, b: BenchStats): boolean {
  return (Object.keys(a) as (keyof BenchStats)[]).every((name) => a[name] === b[name]);
}

function round2(value: number): number {
  return Math.round(value * 100) / 100;
}
