// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// Tauri events are not buffered: an event emitted before a listener is
// registered is lost. This fake bus does the same, and a window's `listen()`
// resolves only after its registration delay, like the IPC round trip in a
// freshly loaded WebView. Each window loads its own copy of the module.
type Handler = (event: { payload: unknown }) => void;
const bus = vi.hoisted(() => ({
  listeners: new Map<string, Set<(event: { payload: unknown }) => void>>(),
  openWindows: new Set<string>(["main", "secondary"]),
  registrationDelayMs: new Map<string, number>(),
  currentLabel: "main",
  emitted: [] as { target: string; event: string; payload: unknown }[],
  stats: { requestsReceived: 0, operationsExecuted: 0, failedRequests: 0 },
  reset() {
    this.listeners.clear();
    this.openWindows = new Set(["main", "secondary"]);
    this.registrationDelayMs.clear();
    this.currentLabel = "main";
    this.emitted = [];
    this.stats = { requestsReceived: 0, operationsExecuted: 0, failedRequests: 0 };
  },
  deliver(target: string, event: string, payload: unknown) {
    this.emitted.push({ target, event, payload });
    for (const handler of [...(this.listeners.get(target + "/" + event) ?? [])]) {
      try {
        handler({ payload });
      } catch {
        // ignored, as across real WebViews
      }
    }
  },
}));

vi.mock("@tauri-apps/api/core", () => ({
  invoke: async (command: string) => {
    if (command === "baseline_get_debug_stats") {
      return { ...bus.stats, coalescedRequests: 0, cacheHits: 0, cachedEntries: 0, cachePolicy: { kind: "noStore" } };
    }
    bus.stats.requestsReceived += 1;
    bus.stats.operationsExecuted += 1;
    await new Promise((resolve) => setTimeout(resolve, 400));
    return { projectId: "project-42", name: "Project 42", revision: 7, computedAtMs: Date.now() };
  },
}));
vi.mock("@tauri-apps/api/event", () => ({
  emitTo: async (target: string, event: string, payload: unknown) => bus.deliver(target, event, payload),
  listen: async (event: string, handler: Handler) => {
    const label = bus.currentLabel;
    const delay = bus.registrationDelayMs.get(label) ?? 0;
    if (delay > 0) await new Promise((resolve) => setTimeout(resolve, delay));
    const key = label + "/" + event;
    if (!bus.listeners.has(key)) bus.listeners.set(key, new Set());
    bus.listeners.get(key)!.add(handler);
    return () => bus.listeners.get(key)?.delete(handler);
  },
}));
vi.mock("@tauri-apps/api/webviewWindow", () => ({
  WebviewWindow: {
    getByLabel: async (label: string) => (bus.openWindows.has(label) ? { label } : null),
  },
}));

type PairedLoad = typeof import("./paired-load");

/** Loads a fresh copy of the module as the given window would. */
async function loadWindow(label: "main" | "secondary"): Promise<PairedLoad> {
  vi.resetModules();
  bus.currentLabel = label;
  const module = await import("./paired-load");
  module.installPairedLoadBridge(label, true);
  // `listen` captures the label synchronously; main keeps listening as main.
  bus.currentLabel = "main";
  return module;
}

/** Closes the secondary window: its listeners go away with its WebView. */
function closeSecondary() {
  for (const key of [...bus.listeners.keys()]) if (key.startsWith("secondary/")) bus.listeners.delete(key);
  bus.openWindows.delete("secondary");
}

async function settle<T>(promise: Promise<T>, advanceMs: number) {
  const outcome = promise.then(
    (value) => ({ ok: true as const, value }),
    (error: unknown) => ({ ok: false as const, error: String(error) }),
  );
  await vi.advanceTimersByTimeAsync(advanceMs);
  return outcome;
}

const runShort = (main: PairedLoad) => main.runTimedPairedLoad({ durationSeconds: 5, requestsPerWindow: 10 });

beforeEach(() => {
  bus.reset();
  vi.useFakeTimers();
});
afterEach(() => {
  vi.useRealTimers();
});

describe("paired-load window handshake", () => {
  it("works when the secondary became ready before main started listening", async () => {
    bus.registrationDelayMs.set("main", 500);
    const main = await loadWindow("main");
    await loadWindow("secondary");
    await vi.advanceTimersByTimeAsync(1_000);
    bus.registrationDelayMs.delete("main");

    const result = await settle(runShort(main), 30_000);
    expect(result).toMatchObject({ ok: true, value: { passed: true } });
  });

  it("does not lose the first round when a reopened secondary is still loading", async () => {
    const main = await loadWindow("main");
    await loadWindow("secondary");
    await vi.advanceTimersByTimeAsync(100);
    // The secondary is closed and opened again; its new page registers late.
    closeSecondary();
    bus.openWindows.add("secondary");
    bus.registrationDelayMs.set("secondary", 300);
    await loadWindow("secondary");

    const result = await settle(runShort(main), 30_000);
    expect(result).toMatchObject({ ok: true, value: { passed: true } });
  });

  it("runs each round once in the secondary even if the request arrives repeatedly", async () => {
    const main = await loadWindow("main");
    await loadWindow("secondary");
    await vi.advanceTimersByTimeAsync(100);
    const result = await settle(runShort(main), 30_000);
    expect(result.ok).toBe(true);
    const report = (result as { value: Awaited<ReturnType<PairedLoad["runTimedPairedLoad"]>> }).value;

    const receivedBefore = bus.stats.requestsReceived;
    for (const e of bus.emitted.filter((e) => e.target === "secondary")) bus.deliver(e.target, e.event, e.payload);
    await vi.advanceTimersByTimeAsync(5_000);
    expect(bus.stats.requestsReceived).toBe(receivedBefore);
    expect(report.totals.requestsReceived).toBe(report.requestsExpected);
  });

  it("fails clearly when the secondary never confirms, and a late listener does not start the round", async () => {
    const main = await loadWindow("main");
    // The secondary window exists, but its page never registered a listener.
    const result = await settle(runShort(main), 6_000);
    expect(result.ok).toBe(false);
    expect((result as { error: string }).error).toMatch(/did not confirm benchmark round 1/);

    await loadWindow("secondary");
    await vi.advanceTimersByTimeAsync(5_000);
    expect(bus.stats.requestsReceived).toBe(0);
    expect(bus.listeners.get("main/baseline://paired-load-ack")?.size ?? 0).toBe(0);
  });

  it("ignores a confirmation for another round", async () => {
    const main = await loadWindow("main");
    const run = runShort(main);
    await vi.advanceTimersByTimeAsync(50);
    bus.deliver("main", "baseline://paired-load-ack", { runId: "older-run", round: 1 });
    const result = await settle(run, 6_000);
    expect(result.ok).toBe(false);
    expect((result as { error: string }).error).toMatch(/did not confirm/);
  });

  it("waits for a secondary window that is still being created", async () => {
    closeSecondary();
    const main = await loadWindow("main");
    // "Open secondary window" was just clicked: Tauri finds the window only
    // ~100-150 ms later on Windows 10, and its page registers later still.
    main.noteSecondaryOpening();
    setTimeout(() => bus.openWindows.add("secondary"), 120);
    const run = runShort(main);
    bus.registrationDelayMs.set("secondary", 300);
    await loadWindow("secondary");
    bus.openWindows.delete("secondary");

    const result = await settle(run, 30_000);
    expect(result).toMatchObject({ ok: true, value: { passed: true } });
  });

  it("still fails when the window being created never appears", async () => {
    closeSecondary();
    const main = await loadWindow("main");
    main.noteSecondaryOpening();
    const result = await settle(runShort(main), 10_000);
    expect(result.ok).toBe(false);
    expect((result as { error: string }).error).toMatch(/Open the secondary window/);
    expect(bus.emitted.filter((e) => e.event === "baseline://paired-load-request")).toHaveLength(0);
  });

  it("does not wait when the window failed to be created", async () => {
    closeSecondary();
    const main = await loadWindow("main");
    main.noteSecondaryOpening()();
    const result = await settle(runShort(main), 100);
    expect(result.ok).toBe(false);
    expect((result as { error: string }).error).toMatch(/Open the secondary window/);
  });
});
