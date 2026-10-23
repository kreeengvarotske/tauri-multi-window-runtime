import type { RuntimeSetup } from "./lib/runtime";
import type { OpenResult, WindowIdentity } from "./lib/windows";
import { errorMessage, h } from "./components/dom";
import { createStatusBar } from "./components/status-bar";
import { createWindowPanel } from "./components/window-panel";
import { createRequestPanel } from "./components/request-panel";
import { createStatsPanel } from "./components/stats-panel";
import { createHistoryPanel } from "./components/history-panel";

export interface AppOptions {
  /** Result of runtime setup; a thrown configuration error is passed as `error`. */
  setup: RuntimeSetup | { error: unknown };
  identity: WindowIdentity;
  openSecondary?: () => Promise<OpenResult>;
}

/** Renders the app. All backend access goes through `setup.runtime`. */
export function mountApp(root: HTMLElement, { setup, identity, openSecondary }: AppOptions): void {
  if ("error" in setup) {
    root.replaceChildren(
      h("div", { class: "banner banner-error" }, h("strong", { text: "Ошибка конфигурации. " }), errorMessage(setup.error)),
    );
    return;
  }

  const { runtime, mock } = setup;
  const stats = createStatsPanel(runtime);
  const history = createHistoryPanel();
  const requests = createRequestPanel({
    runtime,
    mock,
    onSeriesComplete: history.add,
    onRefreshStats: () => void stats.refresh(),
  });

  root.replaceChildren(
    createStatusBar(runtime.mode, identity),
    h(
      "div",
      { class: "layout" },
      h("div", { class: "column" }, requests),
      h("div", { class: "column" }, stats.element, createWindowPanel(identity, openSecondary), history.element),
    ),
  );
}
