import type { MockTransport } from "../lib/runtime/mock-client";
import type { ProjectMetadata, RuntimeClient } from "../lib/runtime/client";
import type { SeriesRecord } from "./history-panel";
import { errorMessage, formatMs, h, panel } from "./dom";

const SERIES_SIZES = [1, 10, 20, 50] as const;
const DEFAULT_PROJECT_ID = "project-42";

export interface RequestPanelOptions {
  runtime: RuntimeClient;
  mock: MockTransport | null;
  onSeriesComplete(record: SeriesRecord): void;
  onRefreshStats(): void;
}

export function createRequestPanel({ runtime, mock, onSeriesComplete, onRefreshStats }: RequestPanelOptions): HTMLElement {
  const projectInput = h("input", {
    class: "input mono",
    attrs: { id: "project-id", type: "text", value: DEFAULT_PROJECT_ID, spellcheck: "false", autocomplete: "off" },
  });
  const sizeSelect = h(
    "select",
    { class: "input", attrs: { id: "series-size" } },
    ...SERIES_SIZES.map((n) => h("option", { text: String(n), attrs: { value: String(n) } })),
  );
  const runButton = h("button", { class: "btn", text: "Выполнить серию запросов", attrs: { type: "button" } });
  const retryButton = h("button", { class: "btn btn-secondary", text: "Повторить серию", attrs: { type: "button" } });
  retryButton.hidden = true;
  const statsButton = h("button", { class: "btn btn-secondary", text: "Обновить статистику Core", attrs: { type: "button" } });

  const out = {
    sent: h("dd", { class: "mono", text: "—" }),
    succeeded: h("dd", { class: "mono text-ok", text: "—" }),
    failed: h("dd", { class: "mono", text: "—" }),
    duration: h("dd", { class: "mono", text: "—" }),
  };
  const sample = h("pre", { class: "code", text: "Нет данных" });
  const lastError = h("pre", { class: "code code-error", text: "Нет ошибок" });
  const state = h("p", { class: "hint", attrs: { "aria-live": "polite" } });

  let lastSeries: { projectId: string; size: number } | null = null;

  async function runSeries(projectId: string, size: number): Promise<void> {
    lastSeries = { projectId, size };
    runButton.disabled = true;
    retryButton.disabled = true;
    state.className = "hint";
    state.textContent = `Выполняется серия из ${size} запросов…`;
    out.sent.textContent = String(size);
    out.succeeded.textContent = out.failed.textContent = out.duration.textContent = "…";

    const started = performance.now();
    // All calls are created in the same tick so they overlap in Core.
    // No deduplication here: each call goes through the SDK to the transport.
    const results = await Promise.allSettled(
      Array.from({ length: size }, () => runtime.projects.getMetadata({ projectId })),
    );
    const durationMs = performance.now() - started;

    const fulfilled = results.filter((r): r is PromiseFulfilledResult<ProjectMetadata> => r.status === "fulfilled");
    const rejected = results.filter((r): r is PromiseRejectedResult => r.status === "rejected");

    out.succeeded.textContent = String(fulfilled.length);
    out.failed.textContent = String(rejected.length);
    out.failed.className = rejected.length > 0 ? "mono text-error" : "mono";
    out.duration.textContent = formatMs(durationMs);
    if (fulfilled.length > 0) sample.textContent = JSON.stringify(fulfilled[0].value, null, 2);
    if (rejected.length > 0) lastError.textContent = errorMessage(rejected[rejected.length - 1].reason);

    state.className = rejected.length > 0 ? "hint text-error" : "hint text-ok";
    state.textContent =
      rejected.length > 0
        ? `Серия завершена с ошибками: ${rejected.length} из ${size}.`
        : `Серия завершена: все ${size} ответов успешны.`;

    runButton.disabled = false;
    retryButton.disabled = false;
    retryButton.hidden = rejected.length === 0;

    onSeriesComplete({
      finishedAt: new Date(),
      mode: runtime.mode,
      projectId,
      sent: size,
      succeeded: fulfilled.length,
      failed: rejected.length,
      durationMs,
    });
  }

  runButton.addEventListener("click", () => {
    void runSeries(projectInput.value, Number(sizeSelect.value));
  });
  retryButton.addEventListener("click", () => {
    if (lastSeries) void runSeries(lastSeries.projectId, lastSeries.size);
  });
  statsButton.addEventListener("click", onRefreshStats);

  const form = h(
    "div",
    { class: "form" },
    field("projectId", "project-id", projectInput),
    field("Количество запросов", "series-size", sizeSelect),
    mock && mockFailureField(mock),
  );

  const summary = h(
    "dl",
    { class: "summary" },
    h("dt", { text: "Отправлено" }), out.sent,
    h("dt", { text: "Успешно" }), out.succeeded,
    h("dt", { text: "С ошибкой" }), out.failed,
    h("dt", { text: "Время серии" }), out.duration,
  );

  return panel(
    "Запросы getMetadata",
    form,
    h("div", { class: "row" }, runButton, retryButton, statsButton),
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
      text: "Сколько выполнений реально запустил Core, показывает только его статистика, а не эта панель.",
    }),
  );
}

function field(label: string, id: string, control: HTMLElement): HTMLElement {
  return h("div", { class: "field" }, h("label", { text: label, attrs: { for: id } }), control);
}

function mockFailureField(mock: MockTransport): HTMLElement {
  const select = h(
    "select",
    { class: "input", attrs: { id: "mock-failure-rate" } },
    ...[0, 0.2, 0.5, 1].map((rate) =>
      h("option", { text: `${rate * 100}%`, attrs: { value: String(rate) } }),
    ),
  );
  select.value = String(mock.failureRate);
  select.addEventListener("change", () => {
    mock.failureRate = Number(select.value);
  });
  return field("MOCK: доля ошибок", "mock-failure-rate", select);
}
