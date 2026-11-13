// One window's run, identical in every arm except for where data comes from:
// set up the source, report ready, wait for the plan, run the workload at a
// fixed cadence through warm-up and load, sample the JS heap, report.

import {
  type CatalogRecord,
  type CatalogSource,
  type Invoke,
  LocalCatalog,
  type Response,
  type Workload,
  checksum,
  ipcSource,
  runStep,
} from "./catalog";

export interface Plan {
  idleBeforeAtMs: number;
  warmupAtMs: number;
  loadAtMs: number;
  loadEndMs: number;
  idleAfterEndMs: number;
}

export interface CatalogConfig {
  scenario: "M";
  arm: "A" | "B" | "C";
  armName: string;
  dataMib: number;
  seed: number;
  windows: number;
  stepIntervalMs: number;
  idleBeforeSeconds: number;
  warmupSeconds: number;
  loadSeconds: number;
  idleAfterSeconds: number;
  records: number;
  rustDataBytes: number;
  automated: boolean;
  textCache: boolean;
}

export interface WindowDeps {
  invoke: Invoke;
  label: string;
  /** Monotonic milliseconds (performance.now). */
  now(): number;
  /** Wall-clock Unix milliseconds (Date.now); the plan uses this clock. */
  unixNow(): number;
  sleep(milliseconds: number): Promise<void>;
  /** Used JS heap in bytes, or null where the WebView does not report it. */
  jsHeapBytes(): number | null;
  render?(response: Response): void;
  onProgress?(text: string): void;
  planPollMs?: number;
  heapSampleMs?: number;
  /** Gives up waiting for the plan after this long. */
  planTimeoutMs?: number;
}

export interface Distribution {
  p50: number;
  p95: number;
  max: number;
}

export interface HeapSample {
  atMs: number;
  usedBytes: number;
}

export interface WindowReport {
  label: string;
  windowIndex: number;
  arm: string;
  setup: {
    /** From page start until the first page was shown, setup included. */
    timeToFirstPageMs: number;
    /** Arm A only: catalog_load, parsing included. */
    loadMs: number | null;
    /** Arm A only: building the window's indexes. */
    indexMs: number | null;
    records: number | null;
  };
  load: {
    scheduledSteps: number;
    completedSteps: number;
    failures: number;
    mismatches: number;
    overruns: number;
    latencyMs: Distribution | null;
    latencyByKindMs: Record<string, Distribution | null>;
  };
  warmup: { completedSteps: number; failures: number; mismatches: number };
  heap: { samples: HeapSample[]; loadAvgBytes: number | null; supported: boolean };
  firstError: string | null;
  passed: boolean;
}

/** Arm A builds a local catalog; B and C read through IPC. */
export async function setupSource(
  config: CatalogConfig,
  deps: WindowDeps,
  startedAt: number,
): Promise<{ source: CatalogSource; setup: WindowReport["setup"] }> {
  if (config.arm === "A") {
    const loadStarted = deps.now();
    const records = await deps.invoke<CatalogRecord[]>("catalog_load");
    const loadMs = round2(deps.now() - loadStarted);
    const indexStarted = deps.now();
    const local = new LocalCatalog(records);
    const indexMs = round2(deps.now() - indexStarted);
    const first = await local.page({ sort: "name", category: null, offset: 0, limit: 100 });
    deps.render?.({ kind: "page", page: first });
    return { source: local, setup: { timeToFirstPageMs: round2(deps.now() - startedAt), loadMs, indexMs, records: local.size } };
  }
  const source = ipcSource(deps.invoke);
  const first = await source.page({ sort: "name", category: null, offset: 0, limit: 100 });
  deps.render?.({ kind: "page", page: first });
  return { source, setup: { timeToFirstPageMs: round2(deps.now() - startedAt), loadMs: null, indexMs: null, records: null } };
}

export async function waitForPlan(deps: WindowDeps): Promise<Plan> {
  const deadline = deps.now() + (deps.planTimeoutMs ?? 600_000);
  for (;;) {
    const plan = await deps.invoke<Plan | null>("catalog_plan");
    if (plan) return plan;
    if (deps.now() >= deadline) throw new Error("no plan arrived");
    await deps.sleep(deps.planPollMs ?? 200);
  }
}

/** Sleeps until the wall-clock time `atMs`. */
async function sleepUntil(deps: WindowDeps, atMs: number): Promise<void> {
  const wait = atMs - deps.unixNow();
  if (wait > 0) await deps.sleep(wait);
}

interface StepRecord {
  kind: string;
  latencyMs: number;
  ok: boolean;
  mismatch: boolean;
}

/**
 * Runs the workload from `plan.warmupAtMs` to `plan.loadEndMs`: step `i` is
 * due at `warmupAtMs + i × interval`, one at a time; a step that ends after
 * the next one was due is an overrun, and the next one starts at once.
 */
export async function runWorkload(
  source: CatalogSource,
  workload: Workload,
  plan: Plan,
  intervalMs: number,
  deps: WindowDeps,
): Promise<{ warmup: StepRecord[]; load: StepRecord[]; overruns: number; firstError: string | null }> {
  const warmup: StepRecord[] = [];
  const load: StepRecord[] = [];
  let overruns = 0;
  let firstError: string | null = null;
  for (let i = 0; ; i += 1) {
    const dueAt = plan.warmupAtMs + i * intervalMs;
    if (dueAt >= plan.loadEndMs) break;
    await sleepUntil(deps, dueAt);
    const index = i % workload.steps.length;
    const step = workload.steps[index];
    const started = deps.now();
    let ok = true;
    let mismatch = false;
    try {
      const response = await runStep(source, step);
      mismatch = checksum(response) !== workload.expected[index];
      deps.render?.(response);
    } catch (error) {
      ok = false;
      firstError ??= error instanceof Error ? error.message : String(error);
    }
    const record = { kind: step.kind, latencyMs: round2(deps.now() - started), ok, mismatch };
    (dueAt >= plan.loadAtMs ? load : warmup).push(record);
    if (deps.unixNow() > dueAt + intervalMs) overruns += 1;
  }
  return { warmup, load, overruns, firstError };
}

/** Samples the JS heap every `heapSampleMs` until `untilMs`. */
export async function sampleHeap(deps: WindowDeps, untilMs: number): Promise<HeapSample[]> {
  const samples: HeapSample[] = [];
  const every = deps.heapSampleMs ?? 1000;
  while (deps.unixNow() < untilMs) {
    const used = deps.jsHeapBytes();
    if (used !== null) samples.push({ atMs: deps.unixNow(), usedBytes: used });
    await deps.sleep(Math.min(every, Math.max(1, untilMs - deps.unixNow())));
  }
  return samples;
}

export async function runWindow(config: CatalogConfig, deps: WindowDeps, startedAt: number): Promise<WindowReport> {
  const progress = (text: string) => deps.onProgress?.(text);
  progress(config.arm === "A" ? "Loading this window's copy of the catalog…" : "Reading the first page…");
  const { source, setup } = await setupSource(config, deps, startedAt);
  await deps.invoke<string[]>("catalog_ready");
  progress("Ready; waiting for the plan…");
  const plan = await waitForPlan(deps);
  const workload = await deps.invoke<Workload>("catalog_workload");
  const heap = sampleHeap(deps, plan.idleAfterEndMs);
  progress("Idle…");
  const result = await runWorkload(source, workload, plan, config.stepIntervalMs, deps);
  progress("Idle after load…");
  await sleepUntil(deps, plan.idleAfterEndMs);
  const samples = await heap;
  return buildReport(config, deps.label, workload.windowIndex, setup, plan, result, samples);
}

export function buildReport(
  config: CatalogConfig,
  label: string,
  windowIndex: number,
  setup: WindowReport["setup"],
  plan: Plan,
  result: Awaited<ReturnType<typeof runWorkload>>,
  samples: HeapSample[],
): WindowReport {
  const scheduledSteps = Math.ceil((plan.loadEndMs - plan.loadAtMs) / config.stepIntervalMs);
  const failures = result.load.filter((s) => !s.ok).length;
  const mismatches = result.load.filter((s) => s.mismatch).length;
  const completed = result.load.filter((s) => s.ok).length;
  const kinds = [...new Set(result.load.map((s) => s.kind))];
  const loadHeap = samples.filter((s) => s.atMs >= plan.loadAtMs && s.atMs < plan.loadEndMs);
  const warmupFailures = result.warmup.filter((s) => !s.ok).length;
  const warmupMismatches = result.warmup.filter((s) => s.mismatch).length;
  return {
    label,
    windowIndex,
    arm: config.arm,
    setup,
    load: {
      scheduledSteps,
      completedSteps: completed,
      failures,
      mismatches,
      overruns: result.overruns,
      latencyMs: distribution(result.load.map((s) => s.latencyMs)),
      latencyByKindMs: Object.fromEntries(
        kinds.map((kind) => [kind, distribution(result.load.filter((s) => s.kind === kind).map((s) => s.latencyMs))]),
      ),
    },
    warmup: { completedSteps: result.warmup.filter((s) => s.ok).length, failures: warmupFailures, mismatches: warmupMismatches },
    heap: {
      samples,
      loadAvgBytes: loadHeap.length > 0 ? Math.round(loadHeap.reduce((sum, s) => sum + s.usedBytes, 0) / loadHeap.length) : null,
      supported: samples.length > 0,
    },
    firstError: result.firstError,
    passed:
      failures === 0 &&
      mismatches === 0 &&
      warmupFailures === 0 &&
      warmupMismatches === 0 &&
      completed === scheduledSteps,
  };
}

export function distribution(values: number[]): Distribution | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const rank = (p: number) => sorted[Math.min(sorted.length - 1, Math.ceil(p * sorted.length) - 1)];
  return { p50: rank(0.5), p95: rank(0.95), max: sorted[sorted.length - 1] };
}

export function round2(value: number): number {
  return Math.round(value * 100) / 100;
}
