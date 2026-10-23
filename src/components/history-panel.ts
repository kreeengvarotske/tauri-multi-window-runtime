import type { SeriesResult } from "../state/series";
import { formatMs, h, panel } from "./dom";

const MAX_RECORDS = 20;

export interface HistoryPanel {
  element: HTMLElement;
  add(record: SeriesResult): void;
}

/** In-memory history of the latest series; nothing is persisted or shared between windows. */
export function createHistoryPanel(): HistoryPanel {
  const records: SeriesResult[] = [];
  const list = h("ol", { class: "history" });
  const empty = h("p", { class: "hint", text: "Серий пока не было." });

  function render(): void {
    empty.hidden = records.length > 0;
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
    element: panel(`История запусков (последние ${MAX_RECORDS})`, empty, list),
    add(record) {
      records.unshift(record);
      records.length = Math.min(records.length, MAX_RECORDS);
      render();
    },
  };
}
