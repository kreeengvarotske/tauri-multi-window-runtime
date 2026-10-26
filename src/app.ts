import { WINDOW_LABELS, type RuntimeSetup } from "./lib/runtime";
import {
  createWindowBridge,
  type OpenResult,
  type SeriesRequest,
  type WindowBridge,
  type WindowIdentity,
} from "./lib/windows";
import { errorMessage, h } from "./components/dom";
import { createStatusBar } from "./components/status-bar";
import { createWindowPanel } from "./components/window-panel";
import { SERIES_SIZES, createRequestPanel } from "./components/request-panel";
import { createStatsPanel } from "./components/stats-panel";
import { createHistoryPanel } from "./components/history-panel";

export interface AppOptions {
  /** Result of runtime setup; a thrown configuration error is passed as `error`. */
  setup: RuntimeSetup | { error: unknown };
  identity: WindowIdentity;
  openSecondary?: () => Promise<OpenResult>;
  /** Window-to-window messaging; tests pass a fake. */
  bridge?: WindowBridge;
}

/** Renders the app. All backend access goes through `setup.runtime`. */
export function mountApp(root: HTMLElement, { setup, identity, openSecondary, bridge }: AppOptions): void {
  if ("error" in setup) {
    root.replaceChildren(
      h("div", { class: "banner banner-error" }, h("strong", { text: "Ошибка конфигурации. " }), errorMessage(setup.error)),
    );
    return;
  }

  const { runtime, mock } = setup;
  const isMain = identity.label === WINDOW_LABELS.main;
  const liveStats = runtime.mode === "tauri";
  const windows = bridge ?? createWindowBridge();
  const stats = createStatsPanel(runtime);
  const history = createHistoryPanel();
  let stopAutoRefresh: (() => void) | null = null;

  const requests = createRequestPanel({
    runtime,
    mock,
    onSeriesStart() {
      // Mock has no Core stats to poll.
      if (!liveStats) return;
      stopAutoRefresh?.();
      stopAutoRefresh = stats.startAutoRefresh();
    },
    onSeriesComplete(result) {
      history.add(result);
      if (!liveStats) return;
      stopAutoRefresh?.();
      stopAutoRefresh = null;
      if (result.sample) stats.trackResult(result.sample);
      void stats.refresh();
    },
    onRefreshStats: () => stats.refresh(),
    allowCacheAdmin: runtime.mode === "tauri" && isMain,
    onRunInBothWindows: isMain ? (request) => windows.requestSeriesInSecondary(request) : undefined,
  });

  // Every window hears about cache changes, including the ones made elsewhere.
  // The event is only a hint: any window may emit it, so the payload is
  // checked and the stats are re-read from Core either way.
  void runtime.events.onCacheInvalidated((event: unknown) => {
    const projectId = invalidatedProjectId(event);
    if (projectId !== undefined) stats.cacheInvalidated(projectId);
    void stats.refresh();
  });
  if (!isMain) {
    void windows.onSeriesRequest((request) => {
      if (!isOfferedSeries(request)) return;
      void requests.run(request.projectId, request.size, "По команде из main");
    });
  }

  root.replaceChildren(
    createStatusBar(runtime.mode, identity),
    h(
      "div",
      { class: "layout" },
      h("div", { class: "column" }, requests.element),
      h("div", { class: "column" }, stats.element, createWindowPanel(identity, openSecondary), history.element),
    ),
  );
}

/**
 * Window events are not authenticated: any window may emit them. A request
 * drives work here only if it is a series this UI itself offers.
 */
function isOfferedSeries(request: unknown): request is SeriesRequest {
  if (typeof request !== "object" || request === null) return false;
  const { projectId, size } = request as Record<string, unknown>;
  return typeof projectId === "string" && SERIES_SIZES.some((n) => n === size);
}

/** `projectId` of a well-formed cache-invalidated payload, otherwise `undefined`. */
function invalidatedProjectId(event: unknown): string | null | undefined {
  if (typeof event !== "object" || event === null) return undefined;
  const { projectId } = event as Record<string, unknown>;
  return typeof projectId === "string" || projectId === null ? projectId : undefined;
}
