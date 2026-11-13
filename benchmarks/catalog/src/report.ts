// The run report written by the main window: configuration, plan, phase
// times for splitting monitor samples, and every window's report.

import { scheduledLoadSteps, type CatalogConfig, type Plan, type WindowReport } from "./window";

export interface RunReport {
  schemaVersion: 1;
  scenario: "M";
  config: CatalogConfig;
  plan: Plan;
  /** ISO times, the names the summarizer splits monitor samples by. */
  phases: {
    idleBeforeStartedAt: string;
    warmupStartedAt: string;
    loadStartedAt: string;
    loadEndedAt: string;
    endedAt: string;
  };
  windows: Record<string, WindowReport | WindowFailure>;
  totals: {
    scheduledSteps: number;
    completedSteps: number;
    failures: number;
    mismatches: number;
    overruns: number;
    maxP95LatencyMs: number | null;
    maxTimeToFirstPageMs: number | null;
    loadJsHeapAvgBytes: number | null;
  };
  problems: string[];
  passed: boolean;
}

/** What a window sends when it could not finish its run. */
export interface WindowFailure {
  label: string;
  error: string;
  passed: false;
}

const isComplete = (report: WindowReport | WindowFailure): report is WindowReport => "load" in report;

export function buildRunReport(
  config: CatalogConfig,
  plan: Plan,
  windows: Record<string, WindowReport | WindowFailure>,
): RunReport {
  const iso = (ms: number) => new Date(ms).toISOString();
  const problems: string[] = [];
  const received = Object.values(windows);
  if (received.length !== config.windows) problems.push(`expected ${config.windows} window reports, got ${received.length}`);
  const labels = ["main", ...Array.from({ length: config.windows - 1 }, (_, index) => `w${index + 1}`)];
  for (const [label, report] of Object.entries(windows)) {
    if (!labels.includes(label) || report.label !== label
      || (isComplete(report) && (report.windowIndex !== labels.indexOf(label) || report.arm !== config.arm))) {
      problems.push(`${label}: window identity or arm mismatch`);
    }
  }
  for (const failure of received.filter((w) => !isComplete(w))) {
    problems.push(`${failure.label}: did not finish: ${(failure as WindowFailure).error}`);
  }
  const all = received.filter(isComplete);
  const expectedSteps = scheduledLoadSteps(plan, config.stepIntervalMs);
  if (!Number.isSafeInteger(expectedSteps) || expectedSteps <= 0) problems.push("no valid load steps scheduled");
  for (const w of all) {
    const counters = [w.load.scheduledSteps, w.load.completedSteps, w.load.failures, w.load.mismatches,
      w.warmup.completedSteps, w.warmup.failures, w.warmup.mismatches];
    const consistent = counters.every((value) => Number.isSafeInteger(value) && value >= 0)
      && w.load.completedSteps === w.load.scheduledSteps
      && w.load.scheduledSteps === expectedSteps
      && w.load.failures === 0 && w.load.mismatches === 0
      && w.warmup.failures === 0 && w.warmup.mismatches === 0 && w.firstError === null;
    if (!w.passed || !consistent) {
      problems.push(
        `${w.label}: completed ${w.load.completedSteps}/${w.load.scheduledSteps}, failures ${w.load.failures + w.warmup.failures}, ` +
          `mismatches ${w.load.mismatches + w.warmup.mismatches}${w.firstError ? `, first error: ${w.firstError}` : ""}`,
      );
    }
  }
  const sum = (pick: (w: WindowReport) => number) => all.reduce((total, w) => total + pick(w), 0);
  const max = (values: (number | null)[]) => {
    const known = values.filter((v): v is number => v !== null);
    return known.length > 0 ? Math.max(...known) : null;
  };
  const heaps = all.map((w) => w.heap.loadAvgBytes);
  return {
    schemaVersion: 1,
    scenario: "M",
    config,
    plan,
    phases: {
      idleBeforeStartedAt: iso(plan.idleBeforeAtMs),
      warmupStartedAt: iso(plan.warmupAtMs),
      loadStartedAt: iso(plan.loadAtMs),
      loadEndedAt: iso(plan.loadEndMs),
      endedAt: iso(plan.idleAfterEndMs),
    },
    windows,
    totals: {
      scheduledSteps: sum((w) => w.load.scheduledSteps),
      completedSteps: sum((w) => w.load.completedSteps),
      failures: sum((w) => w.load.failures + w.warmup.failures),
      mismatches: sum((w) => w.load.mismatches + w.warmup.mismatches),
      overruns: sum((w) => w.load.overruns),
      maxP95LatencyMs: max(all.map((w) => w.load.latencyMs?.p95 ?? null)),
      maxTimeToFirstPageMs: max(all.map((w) => w.setup.timeToFirstPageMs)),
      loadJsHeapAvgBytes: heaps.every((h) => h !== null) && heaps.length > 0 ? sum((w) => w.heap.loadAvgBytes ?? 0) : null,
    },
    problems,
    passed: problems.length === 0,
  };
}
