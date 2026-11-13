import { invoke } from "@tauri-apps/api/core";
import { getCurrentWebviewWindow } from "@tauri-apps/api/webviewWindow";
import { createRenderer } from "./renderer";
import { type WindowFailure, buildRunReport } from "./report";
import { type CatalogConfig, type Plan, type WindowDeps, type WindowReport, runWindow } from "./window";

// Every window runs the same code; main also starts the run and writes the
// report. The UI renders each response into one table, the same in all arms.
const startedAt = performance.now();
const status = document.querySelector<HTMLPreElement>("#status")!;
const table = document.querySelector<HTMLTableElement>("#page")!;
const label = getCurrentWebviewWindow().label;
const show = (text: string) => (status.textContent = text);
const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

function jsHeapBytes(): number | null {
  const memory = (performance as Performance & { memory?: { usedJSHeapSize: number } }).memory;
  return typeof memory?.usedJSHeapSize === "number" ? memory.usedJSHeapSize : null;
}

/** Main only: begins the run once every window is ready. */
async function begin(): Promise<Plan> {
  const deadline = performance.now() + 300_000;
  for (;;) {
    try {
      return await invoke<Plan>("catalog_begin");
    } catch (error) {
      if (!String(error).includes("not every window is ready") || performance.now() > deadline) throw error;
      await sleep(250);
    }
  }
}

async function collect(): Promise<Record<string, WindowReport | WindowFailure>> {
  const deadline = performance.now() + 60_000;
  for (;;) {
    const reports = await invoke<Record<string, WindowReport | WindowFailure> | null>("catalog_collect");
    if (reports) return reports;
    if (performance.now() > deadline) throw new Error("not every window reported within 60 s");
    await sleep(250);
  }
}

async function start(): Promise<void> {
  const config = await invoke<CatalogConfig>("catalog_config");
  const render = createRenderer(table, config.textCache === true);
  const describe = `arm ${config.arm} (${config.armName}) · D${config.dataMib} · N${config.windows} · ${label}`;
  document.title = `Catalog Bench ${describe}`;
  const deps: WindowDeps = {
    invoke,
    label,
    now: () => performance.now(),
    unixNow: () => Date.now(),
    sleep,
    jsHeapBytes,
    render,
    onProgress: (text) => show(`${describe}\n${text}`),
  };
  const planned = label === "main" ? begin() : null;
  let report: WindowReport | null = null;
  try {
    report = await runWindow(config, deps, startedAt);
    await invoke("catalog_window_report", { report: JSON.stringify(report) });
    show(`${describe}\n${report.passed ? "PASS" : "FAIL"}: ${report.load.completedSteps}/${report.load.scheduledSteps} steps`);
  } catch (error) {
    show(`${describe}\nError: ${String(error)}`);
    await invoke("catalog_window_report", {
      report: JSON.stringify({ label, error: String(error), passed: false } satisfies WindowFailure),
    }).catch(() => {});
  }
  if (!planned) return;

  let output: unknown;
  let passed = false;
  try {
    const plan = await planned;
    const run = buildRunReport(config, plan, await collect());
    output = run;
    passed = run.passed;
    show(`${describe}\n${passed ? "PASS" : `FAIL: ${run.problems.join("; ")}`}`);
  } catch (error) {
    output = { schemaVersion: 1, scenario: "M", config, error: String(error), passed: false };
    show(`${describe}\nError: ${String(error)}`);
  }
  if (config.automated) {
    await invoke("catalog_write_report", { report: JSON.stringify(output, null, 2) });
    await invoke("catalog_exit", { code: passed ? 0 : 1 });
  }
}

start().catch((error: unknown) => show(`Could not start: ${String(error)}`));
