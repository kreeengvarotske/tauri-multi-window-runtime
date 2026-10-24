import { invoke, isTauri } from "@tauri-apps/api/core";
import { WebviewWindow, getCurrentWebviewWindow } from "@tauri-apps/api/webviewWindow";
import { installPairedLoadBridge, runTimedPairedLoad, type PairedLoadReport } from "./paired-load";
import "./styles.css";

interface ProjectMetadata {
  projectId: string;
  name: string;
  revision: number;
  computedAtMs: number;
}

interface DebugStats {
  requestsReceived: number;
  operationsExecuted: number;
  coalescedRequests: number;
  cacheHits: number;
  failedRequests: number;
  cachedEntries: number;
  cachePolicy: { kind: string };
}

interface SeriesHistory {
  timestamp: string;
  projectId: string;
  successes: number;
  total: number;
  failures: number;
  durationMs: number;
}

const byId = <T extends HTMLElement>(id: string): T => {
  const element = document.getElementById(id);
  if (!element) throw new Error("Missing element: " + id);
  return element as T;
};

const projectIdInput = byId<HTMLInputElement>("project-id");
const requestCountSelect = byId<HTMLSelectElement>("request-count");
const runButton = byId<HTMLButtonElement>("run-series");
const openSecondaryButton = byId<HTMLButtonElement>("open-secondary");
const refreshStatsButton = byId<HTMLButtonElement>("refresh-stats");
const historyList = byId<HTMLOListElement>("history");
const runStatus = byId<HTMLParagraphElement>("run-status");
const sampleResponse = byId<HTMLPreElement>("sample-response");
const lastError = byId<HTMLParagraphElement>("last-error");
const timedLoadPanel = byId<HTMLElement>("timed-load-panel");
const timedLoadButton = byId<HTMLButtonElement>("run-timed-load");
const downloadTimedReportButton = byId<HTMLButtonElement>("download-timed-report");
const timedLoadStatus = byId<HTMLParagraphElement>("timed-load-status");
const timedLoadReportElement = byId<HTMLPreElement>("timed-load-report");

const tauri = isTauri();
const windowLabel = tauri
  ? getCurrentWebviewWindow().label
  : new URLSearchParams(window.location.search).get("window") ?? "main";
byId<HTMLSpanElement>("window-label").textContent = windowLabel;
byId<HTMLSpanElement>("mode-badge").textContent = tauri ? "TAURI" : "BROWSER";
openSecondaryButton.hidden = windowLabel !== "main";
timedLoadPanel.hidden = windowLabel !== "main" || !tauri;
installPairedLoadBridge(windowLabel, tauri);

const history: SeriesHistory[] = [];
let automatedLoadRunning = false;
let latestPairedLoadReport: PairedLoadReport | null = null;
const maxHistoryItems = 20;

function setText(id: string, value: string): void {
  byId<HTMLElement>(id).textContent = value;
}

function formatMilliseconds(value: number): string {
  return value.toFixed(1) + " ms";
}

function setRunBusy(busy: boolean): void {
  runButton.disabled = busy;
  requestCountSelect.disabled = busy;
  projectIdInput.disabled = busy;
  timedLoadButton.disabled = busy || automatedLoadRunning;
  runButton.textContent = busy ? "Running…" : "Run concurrent series";
}

function renderHistory(): void {
  historyList.replaceChildren();
  if (history.length === 0) {
    const empty = document.createElement("li");
    empty.className = "history-empty";
    empty.textContent = "No runs recorded yet.";
    historyList.append(empty);
    return;
  }

  for (const item of history) {
    const row = document.createElement("li");
    row.className = "history-item";
    const title = document.createElement("strong");
    title.textContent = item.timestamp + " · " + item.projectId;
    const details = document.createElement("span");
    details.textContent =
      item.successes + "/" + item.total + " succeeded · " +
      item.failures + " errors · " + formatMilliseconds(item.durationMs);
    row.append(title, details);
    historyList.append(row);
  }
}

async function openSecondaryWindow(): Promise<void> {
  if (!tauri) {
    const url = new URL(window.location.href);
    url.searchParams.set("window", "secondary");
    window.open(url.toString(), "vanilla-tauri-baseline-secondary");
    return;
  }

  const existing = await WebviewWindow.getByLabel("secondary");
  if (existing) {
    await existing.unminimize();
    await existing.show();
    await existing.setFocus();
    return;
  }

  const created = new WebviewWindow("secondary", {
    url: "index.html",
    title: "Vanilla Tauri Baseline — secondary",
    width: 900,
    height: 650,
    minWidth: 480,
    minHeight: 400,
  });

  await new Promise<void>((resolve, reject) => {
    void created.once("tauri://created", () => resolve());
    void created.once<string>("tauri://error", (event) => {
      reject(new Error(String(event.payload)));
    });
  });
}

async function runSeries(): Promise<void> {
  if (!tauri) {
    runStatus.textContent = "Run this benchmark from the native Tauri app, not a browser tab.";
    return;
  }

  const projectId = projectIdInput.value.trim();
  const count = Number(requestCountSelect.value);
  if (!projectId || projectId.length > 128) {
    runStatus.textContent = "Enter a project ID between 1 and 128 characters.";
    projectIdInput.focus();
    return;
  }

  setRunBusy(true);
  runStatus.textContent = "Sending " + count + " independent IPC requests…";
  lastError.textContent = "None";
  const start = performance.now();

  try {
    const settled = await Promise.allSettled(
      Array.from({ length: count }, () =>
        invoke<ProjectMetadata>("baseline_get_project_metadata", { projectId }),
      ),
    );
    const durationMs = performance.now() - start;
    const succeeded = settled.filter(
      (entry): entry is PromiseFulfilledResult<ProjectMetadata> => entry.status === "fulfilled",
    );
    const failed = settled.filter((entry) => entry.status === "rejected");
    const distinctPayloads = new Set(succeeded.map((entry) => JSON.stringify(entry.value)));

    setText("sent-count", String(count));
    setText("success-count", String(succeeded.length));
    setText("failed-count", String(failed.length));
    setText("distinct-count", String(distinctPayloads.size));
    setText("duration-value", formatMilliseconds(durationMs));
    sampleResponse.textContent = succeeded.length > 0
      ? JSON.stringify(succeeded[0].value, null, 2)
      : "No successful response.";
    lastError.textContent = failed.length > 0
      ? String(failed[0].status === "rejected" ? failed[0].reason : "Unknown error")
      : "None";
    runStatus.textContent =
      "Completed: " + succeeded.length + "/" + count + " succeeded, " + failed.length + " failed.";

    history.unshift({
      timestamp: new Date().toLocaleTimeString(),
      projectId,
      successes: succeeded.length,
      total: count,
      failures: failed.length,
      durationMs,
    });
    history.splice(maxHistoryItems);
    renderHistory();
  } catch (error) {
    runStatus.textContent = "The request series could not be completed.";
    lastError.textContent = String(error);
  } finally {
    setRunBusy(false);
  }
}

async function runAutomatedTimedLoad(): Promise<void> {
  if (automatedLoadRunning || runButton.disabled) return;
  if (!tauri) {
    timedLoadStatus.textContent = "Run this benchmark from the native Tauri app, not a browser tab.";
    return;
  }

  automatedLoadRunning = true;
  setRunBusy(true);
  openSecondaryButton.disabled = true;
  refreshStatsButton.disabled = true;
  timedLoadButton.disabled = true;
  downloadTimedReportButton.hidden = true;
  timedLoadStatus.className = "status";
  timedLoadStatus.textContent = "Running paired load for at least 60 seconds. Keep both windows open and do not run other series.";
  timedLoadReportElement.textContent = "Benchmark in progress…";
  latestPairedLoadReport = null;

  try {
    latestPairedLoadReport = await runTimedPairedLoad({
      durationSeconds: 60,
      requestsPerWindow: 50,
      projectId: "project-42",
      onRound(round, roundsCompleted) {
        timedLoadStatus.textContent =
          "Round " + roundsCompleted + ": " + round.requestsAttempted + "/" +
          round.requestsExpected + " requests attempted, " + round.failures +
          " failures, " + round.durationMs.toFixed(1) + " ms.";
      },
    });

    timedLoadReportElement.textContent = JSON.stringify(latestPairedLoadReport, null, 2);
    timedLoadStatus.className = latestPairedLoadReport.passed ? "status status-success" : "status status-error";
    timedLoadStatus.textContent = latestPairedLoadReport.passed
      ? "PASS: " + latestPairedLoadReport.totals.requestsReceived + " requests, " +
        latestPairedLoadReport.totals.operationsExecuted + " operations, 0 coalesced requests and 0 errors."
      : "The load finished, but the observed results did not match the baseline expectations. Inspect the JSON report.";
    downloadTimedReportButton.hidden = false;
  } catch (error) {
    timedLoadReportElement.textContent = String(error);
    timedLoadStatus.className = "status status-error";
    timedLoadStatus.textContent = "Paired load stopped before a complete report was produced.";
  } finally {
    automatedLoadRunning = false;
    setRunBusy(false);
    openSecondaryButton.disabled = false;
    refreshStatsButton.disabled = false;
    timedLoadButton.disabled = false;
  }
}

function downloadTimedReport(): void {
  if (!latestPairedLoadReport) return;
  const json = JSON.stringify(latestPairedLoadReport, null, 2);
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const url = URL.createObjectURL(new Blob([json], { type: "application/json" }));
  const link = document.createElement("a");
  link.href = url;
  link.download = "vanilla-tauri-benchmark-" + timestamp + ".json";
  link.click();
  window.setTimeout(() => URL.revokeObjectURL(url), 0);
}

async function refreshStats(): Promise<void> {
  if (!tauri) {
    setText("stats-updated", "Backend stats are only available in the native Tauri app.");
    return;
  }

  refreshStatsButton.disabled = true;
  setText("stats-updated", "Refreshing…");
  try {
    const stats = await invoke<DebugStats>("baseline_get_debug_stats");
    setText("stats-requests", String(stats.requestsReceived));
    setText("stats-executions", String(stats.operationsExecuted));
    setText("stats-coalesced", String(stats.coalescedRequests));
    setText("stats-cache-hits", String(stats.cacheHits));
    setText("stats-failures", String(stats.failedRequests));
    setText("stats-cache-entries", String(stats.cachedEntries));
    setText("stats-policy", "Cache policy: " + stats.cachePolicy.kind);
    setText("stats-updated", "Updated at " + new Date().toLocaleTimeString());
  } catch (error) {
    setText("stats-updated", "Stats request failed: " + String(error));
  } finally {
    refreshStatsButton.disabled = false;
  }
}

runButton.addEventListener("click", () => void runSeries());
timedLoadButton.addEventListener("click", () => void runAutomatedTimedLoad());
downloadTimedReportButton.addEventListener("click", downloadTimedReport);
refreshStatsButton.addEventListener("click", () => void refreshStats());
openSecondaryButton.addEventListener("click", async () => {
  openSecondaryButton.disabled = true;
  try {
    await openSecondaryWindow();
  } catch (error) {
    runStatus.textContent = "Could not open the secondary window: " + String(error);
  } finally {
    openSecondaryButton.disabled = false;
  }
});

setRunBusy(false);
renderHistory();
