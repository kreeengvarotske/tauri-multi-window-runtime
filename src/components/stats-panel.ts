import type { RuntimeClient, RuntimeDebugStats } from "../lib/runtime/client";
import { errorMessage, h, panel } from "./dom";

const COUNTERS: { key: keyof RuntimeDebugStats; label: string }[] = [
  { key: "requestsReceived", label: "Принятые запросы" },
  { key: "operationExecutions", label: "Реальные выполнения операций" },
  { key: "coalescedRequests", label: "Присоединившиеся запросы" },
  { key: "inFlightOperations", label: "Операции в процессе выполнения" },
];

export interface StatsPanel {
  element: HTMLElement;
  refresh(): Promise<void>;
}

/** Stats are fetched only on demand, to avoid extra IPC load during tests. */
export function createStatsPanel(runtime: RuntimeClient): StatsPanel {
  const values = new Map<keyof RuntimeDebugStats, HTMLElement>();
  const grid = h(
    "div",
    { class: "stats-grid" },
    ...COUNTERS.map(({ key, label }) => {
      const value = h("div", { class: "stat-value", text: "—" });
      values.set(key, value);
      return h("div", { class: "stat" }, value, h("div", { class: "stat-label", text: label }));
    }),
  );
  const status = h("p", {
    class: "hint",
    text:
      runtime.mode === "mock"
        ? "Статистика ядра недоступна в MOCK-режиме."
        : "Нажмите «Обновить статистику Core». Счётчики относятся ко всему Core, а не к этому окну.",
    attrs: { "aria-live": "polite" },
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
      status.textContent = `Обновлено в ${new Date().toLocaleTimeString()}.`;
    } catch (error) {
      for (const value of values.values()) value.textContent = "—";
      status.className = "hint text-error";
      status.textContent = errorMessage(error);
    } finally {
      loading = false;
      button.disabled = false;
      grid.classList.remove("is-loading");
    }
  }

  button.addEventListener("click", () => void refresh());

  const element = panel("Диагностика Core", grid, h("div", { class: "row" }, button, status));
  return { element, refresh };
}
