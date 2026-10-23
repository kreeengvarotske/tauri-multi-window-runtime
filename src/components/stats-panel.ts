import type { ProjectMetadata, RuntimeClient, RuntimeDebugStats } from "../lib/runtime";
import { createCacheTimer, type CacheTimer } from "./cache-timer";
import { describeCachePolicy, statsInvariantHolds } from "../state/stats";
import { errorMessage, h, panel } from "./dom";

type Counter = Exclude<keyof RuntimeDebugStats, "cachePolicy">;

export const COUNTERS: { key: Counter; label: string }[] = [
  { key: "requestsReceived", label: "Принятые запросы" },
  { key: "operationsExecuted", label: "Реальные выполнения операций" },
  { key: "coalescedRequests", label: "Присоединившиеся запросы" },
  { key: "cacheHits", label: "Попадания в кэш" },
  { key: "failedRequests", label: "Запросы с ошибкой" },
  { key: "cachedEntries", label: "Записей в кэше" },
];

export interface StatsPanel {
  element: HTMLElement;
  /**
   * `live` is used while a series is in flight: counters update quietly, and
   * the invariant is not judged because some calls are still unfinished.
   */
  refresh(options?: { live?: boolean }): Promise<void>;
  /** Polls stats every `intervalMs` until the returned function is called. */
  startAutoRefresh(intervalMs?: number): () => void;
  /** Feeds the cache timer with the latest successful result. */
  trackResult(sample: ProjectMetadata): void;
  /** Called when Core reports that the cache was invalidated or cleared. */
  cacheInvalidated(projectId: string | null): void;
}

/** Stats are fetched only on demand, to avoid extra IPC load during tests. */
export function createStatsPanel(runtime: RuntimeClient, timer: CacheTimer = createCacheTimer()): StatsPanel {
  const values = new Map<Counter, HTMLElement>();
  const grid = h(
    "div",
    { class: "stats-grid" },
    ...COUNTERS.map(({ key, label }) => {
      const value = h("div", { class: "stat-value", text: "—", attrs: { "data-stat": key } });
      values.set(key, value);
      return h("div", { class: "stat" }, value, h("div", { class: "stat-label", text: label }));
    }),
  );
  const policy = h("p", { class: "hint", text: "Политика кэша: —", attrs: { "data-stat": "cachePolicy" } });
  const invariant = h("p", { class: "hint", attrs: { "data-stat": "invariant" } });
  invariant.hidden = true;
  const status = h("p", {
    class: "hint",
    text:
      runtime.mode === "mock"
        ? "Статистика ядра недоступна в MOCK-режиме."
        : "Нажмите «Обновить». Счётчики относятся ко всему Core, а не к этому окну.",
    attrs: { "aria-live": "polite", "data-stat": "status" },
  });
  const button = h("button", { class: "btn btn-secondary", text: "Обновить", attrs: { type: "button" } });

  let loading = false;
  // A full refresh requested while another one is in flight runs right after it,
  // so the final check after a series is never lost behind a live poll.
  let fullRefreshQueued = false;

  async function refresh({ live = false }: { live?: boolean } = {}): Promise<void> {
    if (loading) {
      if (!live) fullRefreshQueued = true;
      return;
    }
    loading = true;
    button.disabled = true;
    if (!live) {
      grid.classList.add("is-loading");
      status.className = "hint";
      status.textContent = "Запрашиваю статистику Core…";
    }
    try {
      const stats = await runtime.diagnostics.getStats();
      for (const { key } of COUNTERS) values.get(key)!.textContent = String(stats[key]);
      policy.textContent = `Политика кэша: ${describeCachePolicy(stats.cachePolicy)}`;
      timer.setPolicy(stats.cachePolicy);
      invariant.hidden = false;
      if (live) {
        invariant.className = "hint";
        invariant.textContent = "Серия выполняется: инвариант проверю, когда все запросы завершатся.";
      } else {
        const ok = statsInvariantHolds(stats);
        invariant.className = ok ? "hint text-ok" : "hint text-error";
        invariant.textContent = ok
          ? "Инвариант выполнен: принятые = выполнения + присоединившиеся + попадания в кэш."
          : "Инвариант нарушен: принятые ≠ выполнения + присоединившиеся + попадания в кэш.";
      }
      status.className = "hint";
      status.textContent = `${live ? "Автообновление" : "Обновлено"} в ${new Date().toLocaleTimeString()}.`;
    } catch (error) {
      for (const value of values.values()) value.textContent = "—";
      policy.textContent = "Политика кэша: —";
      invariant.hidden = true;
      status.className = "hint text-error";
      status.textContent = errorMessage(error);
    } finally {
      loading = false;
      button.disabled = false;
      grid.classList.remove("is-loading");
    }
    if (fullRefreshQueued) {
      fullRefreshQueued = false;
      await refresh();
    }
  }

  button.addEventListener("click", () => void refresh());

  function startAutoRefresh(intervalMs = 500): () => void {
    const poll = () => void refresh({ live: true });
    poll();
    const id = setInterval(poll, intervalMs);
    return () => clearInterval(id);
  }

  const element = panel(
    "Диагностика Core",
    grid,
    policy,
    timer.element,
    invariant,
    h("div", { class: "row" }, button, status),
  );
  return {
    element,
    refresh,
    startAutoRefresh,
    trackResult: (sample) => timer.track(sample),
    cacheInvalidated: (projectId) => timer.invalidated(projectId),
  };
}
