import type { MockControls, RuntimeClient } from "../lib/runtime";
import { runSeries, type SeriesResult } from "../state/series";
import { errorMessage, formatMs, h, panel } from "./dom";

export const SERIES_SIZES = [1, 10, 20, 50] as const;
const DEFAULT_PROJECT_ID = "project-42";

export interface RequestPanelOptions {
  runtime: RuntimeClient;
  mock: MockControls | null;
  onSeriesComplete(result: SeriesResult): void;
  onRefreshStats(): Promise<void>;
  allowCacheAdmin: boolean;
}

export function createRequestPanel({
  runtime,
  mock,
  onSeriesComplete,
  onRefreshStats,
  allowCacheAdmin,
}: RequestPanelOptions): HTMLElement {
  const projectInput = h("input", {
    class: "input mono",
    attrs: { id: "project-id", type: "text", value: DEFAULT_PROJECT_ID, spellcheck: "false", autocomplete: "off" },
  });
  const sizeSelect = h(
    "select",
    { class: "input", attrs: { id: "series-size" } },
    ...SERIES_SIZES.map((n) => h("option", { text: String(n), attrs: { value: String(n) } })),
  );
  const runButton = h("button", { class: "btn", text: "Выполнить серию запросов", attrs: { type: "button", "data-action": "run" } });
  const retryButton = h("button", {
    class: "btn btn-secondary",
    text: "Повторить серию",
    attrs: { type: "button", "data-action": "retry" },
  });
  retryButton.hidden = true;
  const statsButton = h("button", {
    class: "btn btn-secondary",
    text: "Обновить статистику Core",
    attrs: { type: "button", "data-action": "refresh-stats" },
  });

  const out = {
    sent: h("dd", { class: "mono", text: "—", attrs: { "data-out": "sent" } }),
    succeeded: h("dd", { class: "mono text-ok", text: "—", attrs: { "data-out": "succeeded" } }),
    failed: h("dd", { class: "mono", text: "—", attrs: { "data-out": "failed" } }),
    distinct: h("dd", { class: "mono", text: "—", attrs: { "data-out": "distinct" } }),
    duration: h("dd", { class: "mono", text: "—", attrs: { "data-out": "duration" } }),
  };
  const sample = h("pre", { class: "code", text: "Нет данных", attrs: { "data-out": "sample" } });
  const lastError = h("pre", { class: "code code-error", text: "Нет ошибок", attrs: { "data-out": "last-error" } });
  const state = h("p", { class: "hint", attrs: { "aria-live": "polite", "data-out": "state" } });

  const invalidateCacheButton = h("button", {
    class: "btn btn-secondary",
    text: "Инвалидировать проект",
    attrs: { type: "button", "data-cache-action": "invalidate" },
  });
  const clearCacheButton = h("button", {
    class: "btn btn-secondary",
    text: "Очистить весь кэш",
    attrs: { type: "button", "data-cache-action": "clear" },
  });
  const cacheAdminStatus = h("p", {
    class: "hint",
    text: "Изменения затрагивают общий кэш обоих окон.",
    attrs: { "aria-live": "polite", "data-cache-admin-status": "" },
  });
  const cacheAdmin = allowCacheAdmin
    ? h(
        "div",
        { class: "cache-admin" },
        h("h3", { text: "Управление кэшем" }),
        h("div", { class: "row" }, invalidateCacheButton, clearCacheButton),
        cacheAdminStatus,
      )
    : null;
  let cacheAdminPending = false;

  async function runCacheAdmin(action: "invalidate" | "clear"): Promise<void> {
    if (cacheAdminPending) return;
    cacheAdminPending = true;
    invalidateCacheButton.disabled = true;
    clearCacheButton.disabled = true;
    cacheAdminStatus.className = "hint";
    cacheAdminStatus.textContent =
      action === "invalidate"
        ? `Инвалидирую кэш проекта «${projectInput.value.trim()}»…`
        : "Очищаю общий кэш…";

    try {
      if (action === "invalidate") {
        const projectId = projectInput.value;
        const result = await runtime.cache.invalidateProject({ projectId });
        cacheAdminStatus.className = result.invalidated ? "hint text-ok" : "hint";
        cacheAdminStatus.textContent = result.invalidated
          ? `Кэш проекта «${projectId.trim()}» инвалидирован.`
          : `Запись проекта «${projectId.trim()}» не найдена в кэше.`;
      } else {
        await runtime.cache.clear();
        cacheAdminStatus.className = "hint text-ok";
        cacheAdminStatus.textContent = "Общий кэш очищен.";
      }
      await onRefreshStats();
    } catch (error) {
      cacheAdminStatus.className = "hint text-error";
      cacheAdminStatus.textContent = errorMessage(error);
    } finally {
      cacheAdminPending = false;
      invalidateCacheButton.disabled = false;
      clearCacheButton.disabled = false;
    }
  }

  invalidateCacheButton.addEventListener("click", () => void runCacheAdmin("invalidate"));
  clearCacheButton.addEventListener("click", () => void runCacheAdmin("clear"));

  let lastSeries: { projectId: string; size: number } | null = null;

  async function run(projectId: string, size: number): Promise<void> {
    lastSeries = { projectId, size };
    runButton.disabled = true;
    retryButton.disabled = true;
    state.className = "hint";
    state.textContent = `Выполняется серия из ${size} запросов…`;
    out.sent.textContent = String(size);
    out.succeeded.textContent = out.failed.textContent = out.distinct.textContent = out.duration.textContent = "…";

    const result = await runSeries(runtime, projectId, size);

    out.succeeded.textContent = String(result.succeeded);
    out.failed.textContent = String(result.failed);
    out.failed.className = result.failed > 0 ? "mono text-error" : "mono";
    out.distinct.textContent = result.succeeded > 0 ? String(result.distinctResults) : "—";
    out.duration.textContent = formatMs(result.durationMs);
    if (result.sample) sample.textContent = JSON.stringify(result.sample, null, 2);
    if (result.lastError !== null) lastError.textContent = errorMessage(result.lastError);

    const codes = Object.entries(result.errorsByCode)
      .map(([code, count]) => `${code} × ${count}`)
      .join(", ");
    state.className = result.failed > 0 ? "hint text-error" : "hint text-ok";
    state.textContent =
      result.failed > 0
        ? `Серия завершена с ошибками: ${result.failed} из ${size} (${codes}).`
        : `Серия завершена: все ${size} ответов успешны.`;

    runButton.disabled = false;
    retryButton.disabled = false;
    retryButton.hidden = result.failed === 0;

    onSeriesComplete(result);
  }

  runButton.addEventListener("click", () => {
    void run(projectInput.value, Number(sizeSelect.value));
  });
  retryButton.addEventListener("click", () => {
    if (lastSeries) void run(lastSeries.projectId, lastSeries.size);
  });
  statsButton.addEventListener("click", () => void onRefreshStats());

  const projectField = field("projectId", "project-id", projectInput);
  if (mock) {
    const listId = "mock-project-ids";
    projectInput.setAttribute("list", listId);
    projectField.append(
      h("datalist", { attrs: { id: listId } }, ...mock.knownProjectIds.map((id) => h("option", { attrs: { value: id } }))),
    );
  }

  const form = h(
    "div",
    { class: "form" },
    projectField,
    field("Количество запросов", "series-size", sizeSelect),
    mock && mockFailureField(mock),
  );

  const summary = h(
    "dl",
    { class: "summary" },
    h("dt", { text: "Отправлено" }), out.sent,
    h("dt", { text: "Успешно" }), out.succeeded,
    h("dt", { text: "С ошибкой" }), out.failed,
    h("dt", { text: "Разных результатов" }), out.distinct,
    h("dt", { text: "Время серии" }), out.duration,
  );

  return panel(
    "Запросы getMetadata",
    form,
    mock &&
      h("p", {
        class: "hint",
        text: `MOCK-проекты: ${mock.knownProjectIds.join(", ")}. Mock не объединяет запросы: у каждого ответа свой computedAtMs.`,
      }),
    h("div", { class: "row" }, runButton, retryButton, statsButton),
    cacheAdmin,
    state,
    summary,
    h(
      "div",
      { class: "two-col" },
      h("div", {}, h("h3", { text: "Пример метаданных" }), sample),
      h("div", {}, h("h3", { text: "Последняя ошибка" }), lastError),
    ),
    h("p", {
      class: "hint",
      text: "Одинаковый computedAtMs у ответов значит один общий результат Core. Сколько операций реально запущено, показывает только статистика Core.",
    }),
  );
}

function field(label: string, id: string, control: HTMLElement): HTMLElement {
  return h("div", { class: "field" }, h("label", { text: label, attrs: { for: id } }), control);
}

function mockFailureField(mock: MockControls): HTMLElement {
  const select = h(
    "select",
    { class: "input", attrs: { id: "mock-failure-rate" } },
    ...[0, 0.2, 0.5, 1].map((rate) => h("option", { text: `${rate * 100}%`, attrs: { value: String(rate) } })),
  );
  select.value = String(mock.failureRate);
  select.addEventListener("change", () => {
    mock.failureRate = Number(select.value);
  });
  return field("MOCK: доля ошибок", "mock-failure-rate", select);
}
