import { invoke } from "@tauri-apps/api/core";
import { emitTo, listen } from "@tauri-apps/api/event";
import { WebviewWindow } from "@tauri-apps/api/webviewWindow";

interface ProjectMetadata {
  projectId: string;
  name: string;
  revision: number;
  computedAtMs: number;
}

interface DebugStats {
  requestsReceived: number;
  operationsExecuted: number;
  coalescedRequests: number;
  cacheHits: number;
  failedRequests: number;
  cachedEntries: number;
  cachePolicy: { kind: string };
}

export interface PairedLoadRound {
  round: number;
  requestsExpected: number;
  requestsAttempted: number;
  successes: number;
  failures: number;
  durationMs: number;
  mainSuccesses: number;
  secondarySuccesses: number;
  mainFailures: number;
  secondaryFailures: number;
  passed: boolean;
}

export interface PairedLoadReport {
  schemaVersion: 1;
  implementation: "vanilla-tauri-baseline";
  runType: "timed-load";
  startedAt: string;
  completedAt: string;
  durationRequestedSeconds: number;
  durationMs: number;
  projectId: string;
  requestsPerWindow: number;
  roundsCompleted: number;
  requestsExpected: number;
  totals: {
    requestsReceived: number;
    operationsExecuted: number;
    coalescedRequests: number;
    cacheHits: number;
    failedRequests: number;
    mainSuccesses: number;
    secondarySuccesses: number;
    mainFailures: number;
    secondaryFailures: number;
  };
  rounds: PairedLoadRound[];
  passed: boolean;
}

interface PairedLoadRequest {
  runId: string;
  round: number;
  projectId: string;
  size: number;
}

interface BatchResult {
  successes: number;
  failures: number;
  durationMs: number;
  firstError: string | null;
}

interface PairedLoadResponse extends PairedLoadRequest, BatchResult {}

const requestEvent = "baseline://paired-load-request";
const responseEvent = "baseline://paired-load-response";
const readyEvent = "baseline://paired-load-ready";

let secondaryReady = false;
const readyWaiters = new Set<() => void>();

/** Installs the event bridge used only by the manual, paired-window benchmark. */
export function installPairedLoadBridge(windowLabel: string, tauri: boolean): void {
  if (!tauri) return;

  if (windowLabel === "main") {
    void listen(readyEvent, () => {
      secondaryReady = true;
      for (const resolve of readyWaiters) resolve();
      readyWaiters.clear();
    }).catch((error: unknown) => {
      console.error("Could not listen for the secondary benchmark window:", error);
    });
    return;
  }

  if (windowLabel !== "secondary") return;

  void listen<PairedLoadRequest>(requestEvent, async (event) => {
    const request = event.payload;
    const result = await runIndependentBatch(request.projectId, request.size);
    const response: PairedLoadResponse = { ...request, ...result };
    await emitTo("main", responseEvent, response);
  }).then(() => emitTo("main", readyEvent, { windowLabel: "secondary" }))
    .catch((error: unknown) => {
      console.error("Could not install the secondary benchmark listener:", error);
    });
}

/** Runs the same number of independent metadata invocations as the runtime variant. */
export async function runTimedPairedLoad(options?: {
  durationSeconds?: number;
  requestsPerWindow?: number;
  projectId?: string;
  onRound?: (round: PairedLoadRound, roundsCompleted: number) => void;
}): Promise<PairedLoadReport> {
  const durationSeconds = options?.durationSeconds ?? 60;
  const requestsPerWindow = options?.requestsPerWindow ?? 50;
  const projectId = options?.projectId ?? "project-42";

  if (!Number.isInteger(durationSeconds) || durationSeconds < 5 || durationSeconds > 600) {
    throw new Error("Duration must be an integer between 5 and 600 seconds.");
  }
  if (!Number.isInteger(requestsPerWindow) || requestsPerWindow < 1 || requestsPerWindow > 50) {
    throw new Error("Requests per window must be an integer between 1 and 50.");
  }
  if (projectId.length < 1 || projectId.length > 128) {
    throw new Error("Project ID must contain between 1 and 128 characters.");
  }

  const secondary = await WebviewWindow.getByLabel("secondary");
  if (!secondary) {
    throw new Error("Open the secondary window before starting the paired load.");
  }
  await waitForSecondaryReady();

  const startedAt = new Date().toISOString();
  const suiteStarted = performance.now();
  const deadline = suiteStarted + durationSeconds * 1000;
  const runId = createRunId();
  const before = await invoke<DebugStats>("baseline_get_debug_stats");
  const rounds: PairedLoadRound[] = [];

  while (rounds.length === 0 || performance.now() < deadline) {
    if (rounds.length >= 1000) {
      throw new Error("Safety limit reached: more than 1000 benchmark rounds.");
    }

    const round = rounds.length + 1;
    const roundStarted = performance.now();
    const request: PairedLoadRequest = { runId, round, projectId, size: requestsPerWindow };
    const secondaryResult = await prepareSecondaryResultWaiter(runId, round);

    try {
      await emitTo("secondary", requestEvent, request);
      const [main, secondaryBatch] = await Promise.all([
        runIndependentBatch(projectId, requestsPerWindow),
        secondaryResult.promise,
      ]);

      const mainAttempted = main.successes + main.failures;
      const secondaryAttempted = secondaryBatch.successes + secondaryBatch.failures;
      const successes = main.successes + secondaryBatch.successes;
      const failures = main.failures + secondaryBatch.failures;
      const requestsAttempted = mainAttempted + secondaryAttempted;
      const roundResult: PairedLoadRound = {
        round,
        requestsExpected: requestsPerWindow * 2,
        requestsAttempted,
        successes,
        failures,
        durationMs: Math.round((performance.now() - roundStarted) * 100) / 100,
        mainSuccesses: main.successes,
        secondarySuccesses: secondaryBatch.successes,
        mainFailures: main.failures,
        secondaryFailures: secondaryBatch.failures,
        passed:
          requestsAttempted === requestsPerWindow * 2 &&
          successes === requestsPerWindow * 2 &&
          failures === 0,
      };
      rounds.push(roundResult);
      options?.onRound?.(roundResult, rounds.length);
    } catch (error) {
      secondaryResult.cancel();
      throw error;
    }
  }

  const after = await invoke<DebugStats>("baseline_get_debug_stats");
  const deltas = statsDelta(before, after);
  const mainSuccesses = rounds.reduce((sum, round) => sum + round.mainSuccesses, 0);
  const secondarySuccesses = rounds.reduce((sum, round) => sum + round.secondarySuccesses, 0);
  const mainFailures = rounds.reduce((sum, round) => sum + round.mainFailures, 0);
  const secondaryFailures = rounds.reduce((sum, round) => sum + round.secondaryFailures, 0);
  const requestsExpected = rounds.length * requestsPerWindow * 2;
  const durationMs = Math.round((performance.now() - suiteStarted) * 100) / 100;

  const totals = {
    requestsReceived: deltas.requestsReceived,
    operationsExecuted: deltas.operationsExecuted,
    coalescedRequests: deltas.coalescedRequests,
    cacheHits: deltas.cacheHits,
    failedRequests: deltas.failedRequests,
    mainSuccesses,
    secondarySuccesses,
    mainFailures,
    secondaryFailures,
  };

  return {
    schemaVersion: 1,
    implementation: "vanilla-tauri-baseline",
    runType: "timed-load",
    startedAt,
    completedAt: new Date().toISOString(),
    durationRequestedSeconds: durationSeconds,
    durationMs,
    projectId,
    requestsPerWindow,
    roundsCompleted: rounds.length,
    requestsExpected,
    totals,
    rounds,
    passed:
      rounds.length > 0 &&
      rounds.every((round) => round.passed) &&
      totals.requestsReceived === requestsExpected &&
      totals.operationsExecuted === requestsExpected &&
      totals.coalescedRequests === 0 &&
      totals.cacheHits === 0 &&
      totals.failedRequests === 0 &&
      mainFailures === 0 &&
      secondaryFailures === 0,
  };
}

async function runIndependentBatch(projectId: string, size: number): Promise<BatchResult> {
  const started = performance.now();
  const settled = await Promise.allSettled(
    Array.from({ length: size }, () =>
      invoke<ProjectMetadata>("baseline_get_project_metadata", { projectId }),
    ),
  );
  const successes = settled.filter((result) => result.status === "fulfilled").length;
  const rejected = settled.filter(
    (result): result is PromiseRejectedResult => result.status === "rejected",
  );

  return {
    successes,
    failures: rejected.length,
    durationMs: Math.round((performance.now() - started) * 100) / 100,
    firstError: rejected.length > 0 ? String(rejected[0].reason) : null,
  };
}

async function waitForSecondaryReady(timeoutMs = 15_000): Promise<void> {
  if (secondaryReady) return;

  await new Promise<void>((resolve, reject) => {
    let timer = 0;
    const onReady = () => {
      window.clearTimeout(timer);
      readyWaiters.delete(onReady);
      resolve();
    };
    timer = window.setTimeout(() => {
      readyWaiters.delete(onReady);
      reject(new Error("The secondary window did not register its benchmark listener within 15 seconds."));
    }, timeoutMs);
    readyWaiters.add(onReady);
  });
}

async function prepareSecondaryResultWaiter(
  runId: string,
  round: number,
  timeoutMs = 15_000,
): Promise<{ promise: Promise<PairedLoadResponse>; cancel: () => void }> {
  let unlisten: (() => void) | undefined;
  let timer = 0;
  let resolveResponse!: (response: PairedLoadResponse) => void;
  let rejectResponse!: (reason: Error) => void;

  const promise = new Promise<PairedLoadResponse>((resolve, reject) => {
    resolveResponse = resolve;
    rejectResponse = reject;
  });

  unlisten = await listen<PairedLoadResponse>(responseEvent, (event) => {
    const response = event.payload;
    if (response.runId !== runId || response.round !== round) return;
    window.clearTimeout(timer);
    unlisten?.();
    resolveResponse(response);
  });

  timer = window.setTimeout(() => {
    unlisten?.();
    rejectResponse(new Error("The secondary window did not finish benchmark round " + round + " within 15 seconds."));
  }, timeoutMs);

  return {
    promise,
    cancel: () => {
      window.clearTimeout(timer);
      unlisten?.();
    },
  };
}

function statsDelta(before: DebugStats, after: DebugStats) {
  return {
    requestsReceived: after.requestsReceived - before.requestsReceived,
    operationsExecuted: after.operationsExecuted - before.operationsExecuted,
    coalescedRequests: after.coalescedRequests - before.coalescedRequests,
    cacheHits: after.cacheHits - before.cacheHits,
    failedRequests: after.failedRequests - before.failedRequests,
  };
}

function createRunId(): string {
  if (typeof crypto.randomUUID === "function") return crypto.randomUUID();
  return "baseline-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2);
}
