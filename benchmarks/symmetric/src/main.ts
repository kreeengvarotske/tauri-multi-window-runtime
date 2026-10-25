import { invoke } from "@tauri-apps/api/core";
import { getCurrentWebviewWindow } from "@tauri-apps/api/webviewWindow";
import { createBridge, delay, tauriPort } from "./bridge";
import { type BenchReport, type SeriesRequest, type SeriesResult, runScenario, runSeries } from "./runner";
import type { BenchConfig } from "./scenarios";

// Deliberately minimal UI: no polling, history or live stats, so the two
// builds differ only in the request path.
const status = document.querySelector<HTMLPreElement>("#status")!;
const runButton = document.querySelector<HTMLButtonElement>("#run")!;
const label = getCurrentWebviewWindow().label;
const now = () => performance.now();
const show = (text: string) => (status.textContent = text);

async function start(): Promise<void> {
  const config = await invoke<BenchConfig>("bench_config");
  document.title = `Symmetric Bench (${config.build}) — ${label}`;
  const bridge = createBridge<SeriesRequest, SeriesResult>(tauriPort());

  if (label !== "main") {
    runButton.hidden = true;
    await bridge.serve((request) => runSeries(invoke, request, now));
    show(`${config.build} · secondary window, serving requests`);
    return;
  }

  const describe = `${config.build} · ${config.scenario} · policy ${config.policy} · ${config.requestsPerWindow}/window · ` +
    `${config.work.bufferMb} MB × ${config.work.iterations} iterations`;
  const run = async () => {
    runButton.disabled = true;
    let report: BenchReport | null = null;
    let failure: unknown = null;
    try {
      report = await runScenario(config, {
        invoke,
        bridge,
        now,
        wallClock: () => new Date().toISOString(),
        sleep: delay,
        onProgress: (text) => show(`${describe}\n${text}`),
      });
      show(`${describe}\n${report.passed ? "PASS" : "FAIL"}: ${report.summary.passedRounds}/${report.summary.rounds} rounds, ` +
        `${report.summary.requestsPerSecond} requests/s, round p50 ${report.summary.roundMs?.p50 ?? "-"} ms` +
        (report.abort ? `\nAborted: ${report.abort.error} (${report.abort.cleanup})` : ""));
    } catch (error) {
      failure = error;
      show(`${describe}\nError: ${String(error)}`);
    } finally {
      runButton.disabled = false;
    }
    if (config.automated) {
      const output = report ?? { schemaVersion: 1, config, error: String(failure), passed: false };
      await invoke("bench_write_report", { report: JSON.stringify(output, null, 2) });
      await invoke("bench_exit", { code: report?.passed ? 0 : 1 });
    }
  };

  runButton.addEventListener("click", () => void run());
  show(describe);
  if (config.automated) {
    runButton.hidden = true;
    await run();
  }
}

start().catch((error: unknown) => show(`Could not start: ${String(error)}`));
