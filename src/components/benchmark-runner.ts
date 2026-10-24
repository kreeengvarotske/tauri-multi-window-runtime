import type { RuntimeClient, RuntimeDebugStats } from "../lib/runtime";
import type { WindowBridge } from "../lib/windows";
import { errorMessage, h, panel } from "./dom";

export interface BenchmarkRoundResult {
  round: number;
  requestsExpected: number;
  durationMs: number;
  requestsReceived: number;
  operationsExecuted: number;
  coalescedRequests: number;
  cacheHits: number;
  failedRequests: number;
  cachedEntriesAtEnd: number;
  passed: boolean;
}

export interface BenchmarkSuiteReport {
  schemaVersion: 1;
  startedAt: string;
  completedAt: string;
  mode: "tauri";
  runType: "fixed-rounds" | "timed-load";
  durationRequestedSeconds: number | null;
  projectId: string;
  requestsPerWindow: number;
  roundsRequested: number | null;
  requestsExpected: number;
  roundsCompleted: number;
  durationMs: number;
  totals: Omit<BenchmarkRoundResult, "round" | "durationMs" | "cachedEntriesAtEnd" | "passed">;
  rounds: BenchmarkRoundResult[];
  passed: boolean;
}

export interface RunPairedBenchmarkOptions {
  runtime: Pick<RuntimeClient, "cache" | "diagnostics">;
  bridge: Pick<WindowBridge, "requestSeriesInSecondary">;
  runLocalSeries(projectId: string, size: number): Promise<unknown>;
  rounds?: number;
  durationSeconds?: number;
  projectId?: string;
  size?: number;
  pollIntervalMs?: number;
  timeoutMs?: number;
  now?: () => number;
  sleep?: (milliseconds: number) => Promise<void>;
  onRound?(result: BenchmarkRoundResult, roundsRequested: number | null): void;
}

/**
 * Repeats cache-cold paired runs without relying on manual window switching.
 * Each round clears the shared Core cache, starts 50 same-key requests in each
 * window, then waits until Core has classified every request before continuing.
 * The timed mode sustains this workload for a specified interval.
 */
export async function runPairedBenchmarkSuite({
  runtime,
  bridge,
  runLocalSeries,
  rounds = 5,
  durationSeconds,
  projectId = "project-42",
  size = 50,
  pollIntervalMs = 50,
  timeoutMs = 15_000,
  now = () => performance.now(),
  sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
  onRound,
}: RunPairedBenchmarkOptions): Promise<BenchmarkSuiteReport> {
  const timed = durationSeconds !== undefined;
  if (timed) {
    if (!Number.isInteger(durationSeconds) || durationSeconds < 5 || durationSeconds > 600) {
      throw new Error("Продолжительность нагрузки должна быть целым числом от 5 до 600 секунд.");
    }
  } else if (!Number.isInteger(rounds) || rounds < 1 || rounds > 100) {
    throw new Error("Количество раундов должно быть целым числом от 1 до 100.");
  }
  if (!Number.isInteger(size) || size < 1 || size > 50) {
    throw new Error("Размер серии должен быть целым числом от 1 до 50.");
  }

  const startedAt = new Date().toISOString();
  const suiteStarted = now();
  const deadline = timed ? suiteStarted + durationSeconds * 1000 : null;
  const roundsRequested = timed ? null : rounds;
  const results: BenchmarkRoundResult[] = [];

  while (true) {
    if (deadline === null && results.length >= rounds) break;
    if (deadline !== null && results.length > 0 && now() >= deadline) break;
    // A generous safety cap protects against a faulty injected clock in tests.
    if (results.length >= 1000) throw new Error("Автотест превысил предел в 1000 раундов.");

    await runtime.cache.clear();
    const before = await runtime.diagnostics.getStats();
    const started = now();

    // The secondary is signalled first; the main starts immediately after the
    // event is dispatched. Core counters verify that both sets really overlap.
    await bridge.requestSeriesInSecondary({ projectId, size });
    const localRun = runLocalSeries(projectId, size);
    const settledStats = waitForRoundClassification({
      runtime,
      before,
      expectedRequests: size * 2,
      pollIntervalMs,
      timeoutMs,
      sleep,
    });

    await Promise.all([localRun, settledStats]);
    const after = await runtime.diagnostics.getStats();
    const deltas = statsDelta(before, after);
    const expectedPerRound = size * 2;
    const durationMs = Math.round((now() - started) * 100) / 100;
    const result: BenchmarkRoundResult = {
      round: results.length + 1,
      requestsExpected: expectedPerRound,
      durationMs,
      requestsReceived: deltas.requestsReceived,
      operationsExecuted: deltas.operationsExecuted,
      coalescedRequests: deltas.coalescedRequests,
      cacheHits: deltas.cacheHits,
      failedRequests: deltas.failedRequests,
      cachedEntriesAtEnd: after.cachedEntries,
      passed:
        deltas.requestsReceived === expectedPerRound &&
        deltas.operationsExecuted === 1 &&
        deltas.coalescedRequests === expectedPerRound - 1 &&
        deltas.cacheHits === 0 &&
        deltas.failedRequests === 0,
    };
    results.push(result);
    onRound?.(result, roundsRequested);

    if (deadline !== null && now() >= deadline) break;
  }

  const totals = results.reduce(
    (sum, result) => ({
      requestsReceived: sum.requestsReceived + result.requestsReceived,
      operationsExecuted: sum.operationsExecuted + result.operationsExecuted,
      coalescedRequests: sum.coalescedRequests + result.coalescedRequests,
      cacheHits: sum.cacheHits + result.cacheHits,
      failedRequests: sum.failedRequests + result.failedRequests,
    }),
    {
      requestsReceived: 0,
      operationsExecuted: 0,
      coalescedRequests: 0,
      cacheHits: 0,
      failedRequests: 0,
    },
  );
  const requestsExpected = results.reduce((sum, result) => sum + result.requestsExpected, 0);
  const expectedExecutions = results.length;
  const durationMs = Math.round((now() - suiteStarted) * 100) / 100;

  return {
    schemaVersion: 1,
    startedAt,
    completedAt: new Date().toISOString(),
    mode: "tauri",
    runType: timed ? "timed-load" : "fixed-rounds",
    durationRequestedSeconds: durationSeconds ?? null,
    projectId,
    requestsPerWindow: size,
    roundsRequested,
    requestsExpected,
    roundsCompleted: results.length,
    durationMs,
    totals,
    rounds: results,
    passed:
      results.length > 0 &&
      (roundsRequested === null || results.length === roundsRequested) &&
      results.every((result) => result.passed) &&
      totals.requestsReceived === requestsExpected &&
      totals.operationsExecuted === expectedExecutions &&
      totals.coalescedRequests === requestsExpected - expectedExecutions &&
      totals.cacheHits === 0 &&
      totals.failedRequests === 0,
  };
}

async function waitForRoundClassification({
  runtime,
  before,
  expectedRequests,
  pollIntervalMs,
  timeoutMs,
  sleep,
}: {
  runtime: Pick<RuntimeClient, "diagnostics">;
  before: RuntimeDebugStats;
  expectedRequests: number;
  pollIntervalMs: number;
  timeoutMs: number;
  sleep(milliseconds: number): Promise<void>;
}): Promise<void> {
  const maxAttempts = Math.max(1, Math.ceil(timeoutMs / pollIntervalMs));

  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    const current = await runtime.diagnostics.getStats();
    const delta = statsDelta(before, current);
    const classified = delta.operationsExecuted + delta.coalescedRequests + delta.cacheHits;

    if (delta.requestsReceived >= expectedRequests && classified >= expectedRequests) {
      return;
    }
    if (attempt + 1 < maxAttempts) await sleep(pollIntervalMs);
  }

  throw new Error(
    `Core не классифицировал все ${expectedRequests} запросов за ${timeoutMs} мс. ` +
      "Проверь, что окно secondary открыто и обе серии завершились.",
  );
}

function statsDelta(before: RuntimeDebugStats, after: RuntimeDebugStats) {
  return {
    requestsReceived: after.requestsReceived - before.requestsReceived,
    operationsExecuted: after.operationsExecuted - before.operationsExecuted,
    coalescedRequests: after.coalescedRequests - before.coalescedRequests,
    cacheHits: after.cacheHits - before.cacheHits,
    failedRequests: after.failedRequests - before.failedRequests,
  };
}

export function createBenchmarkRunner({
  runtime,
  bridge,
  runLocalSeries,
}: {
  runtime: RuntimeClient;
  bridge: WindowBridge;
  runLocalSeries(projectId: string, size: number): Promise<unknown>;
}): HTMLElement {
  const fixedButton = h("button", {
    class: "btn",
    text: "Проверка: 5 пар / 500 запросов",
    attrs: { type: "button", "data-action": "run-automated-benchmark" },
  });
  const timedButton = h("button", {
    class: "btn btn-secondary",
    text: "Нагрузка 60 секунд",
    attrs: { type: "button", "data-action": "run-timed-benchmark" },
  });
  const downloadButton = h("button", {
    class: "btn btn-secondary",
    text: "Скачать отчёт JSON",
    attrs: { type: "button", "data-action": "download-benchmark-report" },
  });
  downloadButton.hidden = true;
  const status = h("p", {
    class: "hint",
    text: "Проверка запускает 5 пар: по 50 запросов в каждом окне. Непрерывная нагрузка повторяет такие пары 60 секунд. Перед каждой парой кэш очищается автоматически.",
    attrs: { "aria-live": "polite", "data-benchmark-status": "" },
  });
  const output = h("pre", {
    class: "code",
    text: "Результаты появятся после запуска автотеста.",
    attrs: { "data-benchmark-report": "" },
  });

  let report: BenchmarkSuiteReport | null = null;
  let running = false;

  async function execute(kind: "fixed-rounds" | "timed-load"): Promise<void> {
    if (running) return;
    running = true;
    fixedButton.disabled = true;
    timedButton.disabled = true;
    downloadButton.disabled = true;
    downloadButton.hidden = true;
    status.className = "hint";
    status.textContent =
      kind === "fixed-rounds"
        ? "Проверка запускается… не закрывай окна и не запускай другие серии."
        : "Идёт непрерывная нагрузка 60 секунд. Не закрывай окна и не запускай другие серии.";
    output.textContent = "Выполняются раунды…";

    try {
      report = await runPairedBenchmarkSuite({
        runtime,
        bridge,
        runLocalSeries,
        ...(kind === "fixed-rounds" ? { rounds: 5 } : { durationSeconds: 60 }),
        projectId: "project-42",
        size: 50,
        onRound(result, requested) {
          status.className = result.passed ? "hint text-ok" : "hint text-error";
          const progress = requested === null ? `раунд ${result.round}, 60 секунд` : `раунд ${result.round}/${requested}`;
          status.textContent =
            `${progress}: ${result.durationMs} мс; запросы ${result.requestsReceived}, ` +
            `выполнений ${result.operationsExecuted}, присоединений ${result.coalescedRequests}, ` +
            `cache hits ${result.cacheHits}.`;
        },
      });
      output.textContent = JSON.stringify(report, null, 2);
      status.className = report.passed ? "hint text-ok" : "hint text-error";
      status.textContent = report.passed
        ? `Автотест пройден: ${report.requestsExpected} запросов, ${report.totals.operationsExecuted} выполнений, ${report.totals.coalescedRequests} присоединений, 0 cache hits и 0 ошибок.`
        : "Автотест завершился, но один или несколько раундов не соответствуют ожиданиям. Проверь отчёт JSON.";
      downloadButton.hidden = false;
      downloadButton.disabled = false;
    } catch (error) {
      report = null;
      output.textContent = errorMessage(error);
      status.className = "hint text-error";
      status.textContent = "Автотест прерван. Подробности приведены ниже.";
    } finally {
      running = false;
      fixedButton.disabled = false;
      timedButton.disabled = false;
    }
  }

  fixedButton.addEventListener("click", () => void execute("fixed-rounds"));
  timedButton.addEventListener("click", () => void execute("timed-load"));

  downloadButton.addEventListener("click", () => {
    if (!report) return;
    const json = JSON.stringify(report, null, 2);
    const stamp = new Date().toISOString().replace(/[:.]/g, "-");
    const url = URL.createObjectURL(new Blob([json], { type: "application/json" }));
    const link = h("a", {
      attrs: {
        href: url,
        download: `runtime-benchmark-${stamp}.json`,
      },
    });
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 0);
  });

  return panel(
    "Автоматическая проверка Task Coalescing",
    status,
    h("div", { class: "row" }, fixedButton, timedButton, downloadButton),
    output,
  );
}
