import type { RuntimeClient, RuntimeDebugStats } from "../lib/runtime";
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
  refresh(): Promise<void>;
}

/** Stats are fetched only on demand, to avoid extra IPC load during tests. */
export function createStatsPanel(runtime: RuntimeClient): StatsPanel {
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

  async function refresh(): Promise<void> {
    if (loading) return;
    loading = true;
    button.disabled = true;
    grid.classList.add("is-loading");
    status.className = "hint";
    status.textContent = "Запрашиваю статистику Core…";
    try {
      const stats = await runtime.diagnostics.getStats();
      for (const { key } of COUNTERS) values.get(key)!.textContent = String(stats[key]);
      policy.textContent = `Политика кэша: ${describeCachePolicy(stats.cachePolicy)}`;
      const ok = statsInvariantHolds(stats);
      invariant.hidden = false;
      invariant.className = ok ? "hint text-ok" : "hint text-error";
      invariant.textContent = ok
        ? "Инвариант выполнен: принятые = выполнения + присоединившиеся + попадания в кэш."
        : "Инвариант нарушен: принятые ≠ выполнения + присоединившиеся + попадания в кэш.";
      status.textContent = `Обновлено в ${new Date().toLocaleTimeString()}.`;
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
  }

  button.addEventListener("click", () => void refresh());

  const element = panel("Диагностика Core", grid, policy, invariant, h("div", { class: "row" }, button, status));
  return { element, refresh };
}
