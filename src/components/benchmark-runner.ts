import type { RuntimeClient, RuntimeDebugStats } from "../lib/runtime";
import type { SecondarySeries, WindowBridge } from "../lib/windows";
import { errorMessage, h, panel } from "./dom";

export interface BenchmarkRoundResult {
  round: number;
  /** Id of the series the secondary window confirmed for this round. */
  secondaryRequestId: string;
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

export interface BenchmarkCounterTotals {
  requestsReceived: number;
  operationsExecuted: number;
  coalescedRequests: number;
  cacheHits: number;
  failedRequests: number;
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
  totals: BenchmarkCounterTotals;
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
  /** Time a round may take before it is stopped. */
  timeoutMs?: number;
  /** Time to wait for the tail of a stopped round before reporting it as still running. */
  drainTimeoutMs?: number;
  /** Consecutive identical polls with nothing in flight that count as "Core is idle". */
  quietPolls?: number;
  now?: () => number;
  sleep?: (milliseconds: number) => Promise<void>;
  onRound?(result: BenchmarkRoundResult, roundsRequested: number | null): void;
}

/** Whether anything a stopped run started may still change Core counters. */
export type BenchmarkCleanup = "clean" | "dirty";

/**
 * A run that stopped before finishing. No report is produced, so a partial run
 * is never shown as passed.
 */
export class BenchmarkAbortedError extends Error {
  readonly roundsCompleted: number;
  /**
   * "clean": everything the run started has finished and Core is idle.
   * "dirty": something may still be running; do not start a new run until
   * `settled` resolves and Core is idle again.
   */
  readonly cleanup: BenchmarkCleanup;
  /** What was still running when the run gave up waiting. */
  readonly outstanding: string[];
  /** Resolves once both series of the stopped round have ended. */
  readonly settled: Promise<void>;

  constructor(
    message: string,
    details: { roundsCompleted: number; cleanup: BenchmarkCleanup; outstanding: string[]; settled: Promise<void> },
  ) {
    super(message);
    this.name = "BenchmarkAbortedError";
    this.roundsCompleted = details.roundsCompleted;
    this.cleanup = details.cleanup;
    this.outstanding = details.outstanding;
    this.settled = details.settled;
  }
}

/**
 * Repeats cache-cold paired runs without relying on manual window switching.
 * Each round waits until Core is idle, clears the shared Core cache, starts 50
 * same-key requests in each window, then waits until both windows report their
 * series finished and Core has classified exactly the expected requests.
 * The timed mode sustains this workload for a specified interval.
 *
 * A round that fails or times out stops the run: the runner waits (bounded)
 * for whatever it started, then rejects with `BenchmarkAbortedError` saying
 * whether that tail has ended. Counters are never read across that boundary.
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
  drainTimeoutMs = 10_000,
  quietPolls = 3,
  now = () => performance.now(),
  sleep = delay,
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

    const expectedPerRound = size * 2;
    const abort = (message: string, cleanup: BenchmarkCleanup, outstanding: string[], settled = Promise.resolve()) =>
      new BenchmarkAbortedError(message, { roundsCompleted: results.length, cleanup, outstanding, settled });

    // Start only from an idle Core, so the tail of anything earlier (another
    // series, a stopped run) cannot be counted in this round.
    const idle = await waitForCoreIdle({ runtime, pollIntervalMs, timeoutMs: drainTimeoutMs, quietPolls, sleep });
    if (!idle.idle) {
      throw abort(
        `Раунд ${results.length + 1} не начат: Core ещё обрабатывает ${idle.inFlight} запросов, не относящихся к раунду.`,
        "dirty",
        [`Core: ${idle.inFlight} запросов в обработке`],
      );
    }

    await runtime.cache.clear();
    const before = await runtime.diagnostics.getStats();
    const started = now();

    // The secondary is signalled first; the main starts immediately after it
    // confirmed. Core counters verify that both sets really overlap.
    let secondary: SecondarySeries;
    try {
      secondary = await bridge.requestSeriesInSecondary({ projectId, size });
    } catch (error) {
      // A request confirmed just after main gave up could still start: drain.
      const drained = await drainRound({ runtime, pollIntervalMs, timeoutMs: drainTimeoutMs, quietPolls, sleep, pending: [] });
      throw abort(errorMessage(error), drained.cleanup, drained.outstanding);
    }
    const local = track(runLocalSeries(projectId, size).then(() => undefined));
    const remote = track(
      secondary.completed.then((completion) => {
        if (!completion.ok) throw new Error(completion.error ?? "серия во втором окне не завершилась");
      }),
    );
    const pending = [
      { label: "серия в main", state: local },
      { label: `серия в secondary (${secondary.requestId})`, state: remote },
    ];

    let failure: string | null = null;
    let after: RuntimeDebugStats | null = null;
    const roundDeadline = started + timeoutMs;
    while (true) {
      const current = await runtime.diagnostics.getStats();
      const delta = statsDelta(before, current);
      const classified = delta.operationsExecuted + delta.coalescedRequests + delta.cacheHits;
      if (local.error) {
        failure = `Серия в main завершилась с ошибкой: ${errorMessage(local.error)}`;
      } else if (remote.error) {
        failure = `Серия в secondary не завершилась: ${errorMessage(remote.error)}`;
      } else if (delta.requestsReceived > expectedPerRound || classified > expectedPerRound) {
        failure = `Core получил больше запросов, чем отправил раунд (${delta.requestsReceived} из ${expectedPerRound}).`;
      } else if (local.done && remote.done && delta.requestsReceived === expectedPerRound && classified === expectedPerRound) {
        after = current;
      } else if (now() >= roundDeadline) {
        failure =
          `Раунд не завершился за ${timeoutMs} мс: Core получил ${delta.requestsReceived} и классифицировал ` +
          `${classified} из ${expectedPerRound} запросов. Проверь, что окно secondary открыто.`;
      }
      if (failure !== null || after !== null) break;
      await sleep(pollIntervalMs);
    }

    if (after === null) {
      const drained = await drainRound({ runtime, pollIntervalMs, timeoutMs: drainTimeoutMs, quietPolls, sleep, pending });
      throw abort(`Раунд ${results.length + 1}: ${failure}`, drained.cleanup, drained.outstanding, drained.settled);
    }

    const deltas = statsDelta(before, after);
    const durationMs = Math.round((now() - started) * 100) / 100;
    const result: BenchmarkRoundResult = {
      round: results.length + 1,
      secondaryRequestId: secondary.requestId,
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

interface Tracked {
  done: boolean;
  error: unknown;
  promise: Promise<void>;
}

/** Remembers how a promise ended, so the round can poll it. Never rejects. */
function track(promise: Promise<void>): Tracked {
  const state: Tracked = { done: false, error: null, promise: Promise.resolve() };
  state.promise = promise.then(
    () => {
      state.done = true;
    },
    (error: unknown) => {
      state.done = true;
      state.error = error ?? new Error("неизвестная ошибка");
    },
  );
  return state;
}

interface IdleCheck {
  runtime: Pick<RuntimeClient, "diagnostics">;
  pollIntervalMs: number;
  timeoutMs: number;
  quietPolls: number;
  sleep(milliseconds: number): Promise<void>;
}

/**
 * Core is idle when every received request has been classified and the
 * counters stay the same for `quietPolls` polls in a row. A request still on
 * its way to Core cannot be seen here, which is why the round also waits for
 * both windows to report that their series ended.
 */
export async function waitForCoreIdle({
  runtime,
  pollIntervalMs,
  timeoutMs,
  quietPolls,
  sleep,
}: IdleCheck): Promise<{ idle: boolean; inFlight: number }> {
  const maxPolls = Math.max(quietPolls, Math.ceil(timeoutMs / pollIntervalMs));
  let previous: RuntimeDebugStats | null = null;
  let quiet = 0;
  let inFlight = 0;
  for (let poll = 0; poll < maxPolls; poll += 1) {
    const current = await runtime.diagnostics.getStats();
    inFlight = current.requestsReceived - (current.operationsExecuted + current.coalescedRequests + current.cacheHits);
    const unchanged = previous !== null && sameCounters(previous, current);
    quiet = inFlight === 0 && (previous === null || unchanged) ? quiet + 1 : 0;
    if (quiet >= quietPolls) return { idle: true, inFlight: 0 };
    previous = current;
    if (poll + 1 < maxPolls) await sleep(pollIntervalMs);
  }
  return { idle: false, inFlight };
}

/** Waits, bounded, for a stopped round's series to end and Core to go idle. */
async function drainRound({
  pending,
  ...check
}: IdleCheck & { pending: { label: string; state: Tracked }[] }): Promise<{
  cleanup: BenchmarkCleanup;
  outstanding: string[];
  settled: Promise<void>;
}> {
  const settled = Promise.all(pending.map(({ state }) => state.promise)).then(() => undefined);
  const timedOut = Symbol("timeout");
  const finished = await Promise.race([settled, check.sleep(check.timeoutMs).then(() => timedOut)]);
  const outstanding = pending.filter(({ state }) => !state.done).map(({ label }) => label);
  if (finished === timedOut && outstanding.length > 0) return { cleanup: "dirty", outstanding, settled };

  const idle = await waitForCoreIdle(check);
  if (!idle.idle) return { cleanup: "dirty", outstanding: [`Core: ${idle.inFlight} запросов в обработке`], settled };
  return { cleanup: "clean", outstanding: [], settled };
}

function sameCounters(a: RuntimeDebugStats, b: RuntimeDebugStats): boolean {
  return (
    a.requestsReceived === b.requestsReceived &&
    a.operationsExecuted === b.operationsExecuted &&
    a.coalescedRequests === b.coalescedRequests &&
    a.cacheHits === b.cacheHits &&
    a.failedRequests === b.failedRequests
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
      if (error instanceof BenchmarkAbortedError && error.cleanup === "dirty") {
        // Something from the stopped run may still change Core counters: keep
        // the buttons locked until it has ended and Core is idle again.
        status.textContent =
          `Автотест прерван, но ещё выполняется: ${error.outstanding.join("; ")}. ` +
          "Новый запуск станет доступен, когда это завершится (или закрой окно secondary).";
        await waitUntilSafe(error);
        status.textContent = "Автотест прерван. Хвост прерванного раунда завершился, можно запускать снова.";
      } else {
        status.textContent = "Автотест прерван. Подробности приведены ниже.";
      }
    } finally {
      running = false;
      fixedButton.disabled = false;
      timedButton.disabled = false;
    }
  }

  async function waitUntilSafe(error: BenchmarkAbortedError): Promise<void> {
    await error.settled;
    const check = { runtime, pollIntervalMs: 250, timeoutMs: 5_000, quietPolls: 3, sleep: delay };
    while (!(await waitForCoreIdle(check)).idle) {
      // Keep the lock; a request that never finishes in Core needs a restart anyway.
    }
  }

  // Clicks while a run or its cleanup is in progress are ignored by `running`.
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

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
