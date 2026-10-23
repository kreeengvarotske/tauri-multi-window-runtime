import "./styles.css";
import { createRuntimeFromEnv, type RuntimeSetup } from "./lib/runtime/client";
import { getWindowIdentity } from "./lib/windows";
import { errorMessage, h } from "./components/dom";
import { createStatusBar } from "./components/status-bar";
import { createWindowPanel } from "./components/window-panel";
import { createRequestPanel } from "./components/request-panel";
import { createStatsPanel } from "./components/stats-panel";
import { createHistoryPanel } from "./components/history-panel";

function mount(root: HTMLElement): void {
  let setup: RuntimeSetup;
  try {
    setup = createRuntimeFromEnv();
  } catch (error) {
    root.replaceChildren(
      h("div", { class: "banner banner-error" }, h("strong", { text: "Ошибка конфигурации. " }), errorMessage(error)),
    );
    return;
  }

  const { runtime, mock } = setup;
  const identity = getWindowIdentity();
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
      h("div", { class: "column" }, stats.element, createWindowPanel(identity), history.element),
    ),
  );
}

mount(document.querySelector<HTMLElement>("#app")!);
