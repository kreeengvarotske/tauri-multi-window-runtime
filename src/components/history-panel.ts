import type { SeriesResult } from "../state/series";
import { errorMessage, formatMs, h, panel } from "./dom";

const MAX_RECORDS = 20;

export interface HistoryPanel {
  element: HTMLElement;
  add(record: SeriesResult): void;
}

export interface HistoryExport {
  /** Saves `json` as a file; returns false if the environment cannot do it. */
  download(json: string, fileName: string): boolean;
  copy(json: string): Promise<void>;
}

/** Plain JSON view of the history: dates as ISO strings, errors as `CODE: message`. */
export function historyToJson(records: readonly SeriesResult[]): string {
  return JSON.stringify(
    records.map(({ finishedAt, lastError, ...rest }) => ({
      ...rest,
      finishedAt: finishedAt.toISOString(),
      lastError: lastError === null ? null : errorMessage(lastError),
    })),
    null,
    2,
  );
}

const browserExport: HistoryExport = {
  download(json, fileName) {
    const url = URL.createObjectURL(new Blob([json], { type: "application/json" }));
    const link = h("a", { attrs: { href: url, download: fileName } });
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 0);
    return true;
  },
  copy: (json) => navigator.clipboard.writeText(json),
};

/** In-memory history of the latest series; nothing is persisted or shared between windows. */
export function createHistoryPanel(exporter: HistoryExport = browserExport): HistoryPanel {
  const records: SeriesResult[] = [];
  const list = h("ol", { class: "history" });
  const empty = h("p", { class: "hint", text: "Серий пока не было." });
  const downloadButton = h("button", { class: "btn btn-secondary", text: "Скачать JSON", attrs: { type: "button" } });
  const copyButton = h("button", { class: "btn btn-secondary", text: "Скопировать JSON", attrs: { type: "button" } });
  const exportStatus = h("p", { class: "hint", attrs: { "aria-live": "polite", "data-out": "history-export" } });
  const exportRow = h("div", { class: "row" }, downloadButton, copyButton, exportStatus);

  downloadButton.addEventListener("click", () => {
    const stamp = new Date().toISOString().replace(/[:.]/g, "-");
    const saved = exporter.download(historyToJson(records), `runtime-lab-history-${stamp}.json`);
    exportStatus.className = "hint";
    exportStatus.textContent = saved ? "Файл сохранён в загрузки." : "Скачивание недоступно, используйте «Скопировать JSON».";
  });
  copyButton.addEventListener("click", async () => {
    try {
      await exporter.copy(historyToJson(records));
      exportStatus.className = "hint text-ok";
      exportStatus.textContent = `Скопировано серий: ${records.length}.`;
    } catch (error) {
      exportStatus.className = "hint text-error";
      exportStatus.textContent = `Не удалось скопировать: ${errorMessage(error)}`;
    }
  });

  function render(): void {
    empty.hidden = records.length > 0;
    exportRow.hidden = records.length === 0;
    list.replaceChildren(
      ...records.map((r) =>
        h(
          "li",
          { class: r.failed > 0 ? "history-item has-errors" : "history-item" },
          h("span", { class: "mono", text: r.finishedAt.toLocaleTimeString() }),
          h("span", { class: "mono", text: r.projectId }),
          h("span", { text: `${r.succeeded}/${r.sent} успешно` }),
          h("span", { class: r.failed > 0 ? "text-error" : "muted", text: `ошибок: ${r.failed}` }),
          h("span", { class: "muted", text: `результатов: ${r.distinctResults}` }),
          h("span", { class: "mono", text: formatMs(r.durationMs) }),
          h("span", { class: "muted", text: r.mode.toUpperCase() }),
        ),
      ),
    );
  }

  render();
  return {
    element: panel(`История запусков (последние ${MAX_RECORDS})`, empty, list, exportRow),
    add(record) {
      records.unshift(record);
      records.length = Math.min(records.length, MAX_RECORDS);
      render();
    },
  };
}
