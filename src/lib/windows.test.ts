import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createWindowBridge, type SeriesRequest } from "./windows";

// Tauri events are not buffered: an event emitted before a listener is
// registered is lost. This fake bus behaves the same way, and listener
// registration resolves only after `registrationDelayMs`, like the async
// `listen()` IPC round trip in a freshly loaded WebView.
type Handler = (event: { payload: unknown }) => void;
const bus = vi.hoisted(() => ({
  listeners: new Map<string, Set<(event: { payload: unknown }) => void>>(),
  openWindows: new Set<string>(["main", "secondary"]),
  registrationDelayMs: new Map<string, number>(),
  currentLabel: "main",
  emitted: [] as { target: string; event: string; payload: unknown }[],
  reset() {
    this.listeners.clear();
    this.openWindows = new Set(["main", "secondary"]);
    this.registrationDelayMs.clear();
    this.currentLabel = "main";
    this.emitted = [];
  },
  deliver(target: string, event: string, payload: unknown) {
    this.emitted.push({ target, event, payload });
    // A listener in another window cannot throw into the sender.
    for (const handler of this.listeners.get(`${target}/${event}`) ?? []) {
      try {
        handler({ payload });
      } catch {
        // ignored, as across real WebViews
      }
    }
  },
}));

vi.mock("@tauri-apps/api/core", () => ({ isTauri: () => true }));
vi.mock("@tauri-apps/api/event", () => ({
  emitTo: async (target: string, event: string, payload: unknown) => bus.deliver(target, event, payload),
}));
vi.mock("@tauri-apps/api/webviewWindow", () => ({
  WebviewWindow: {
    getByLabel: async (label: string) => (bus.openWindows.has(label) ? { label } : null),
  },
  getCurrentWebviewWindow: () => {
    const label = bus.currentLabel;
    return {
      label,
      async listen(event: string, handler: Handler) {
        const delay = bus.registrationDelayMs.get(label) ?? 0;
        if (delay > 0) await new Promise((resolve) => setTimeout(resolve, delay));
        const key = `${label}/${event}`;
        if (!bus.listeners.has(key)) bus.listeners.set(key, new Set());
        bus.listeners.get(key)!.add(handler);
        return () => bus.listeners.get(key)?.delete(handler);
      },
    };
  },
}));


function bridgeFor(label: "main" | "secondary", options?: Parameters<typeof createWindowBridge>[0]) {
  bus.currentLabel = label;
  const bridge = createWindowBridge(options);
  bus.currentLabel = "main";
  return bridge;
}

const REQUEST: SeriesRequest = { projectId: "project-42", size: 50 };

beforeEach(() => {
  bus.reset();
  vi.useFakeTimers();
});
afterEach(() => {
  vi.useRealTimers();
});

describe("window bridge handshake", () => {
  it("does not lose a request sent before the secondary listener is registered", async () => {
    bus.registrationDelayMs.set("secondary", 300);
    const main = bridgeFor("main");
    const secondary = bridgeFor("secondary");
    const handler = vi.fn();

    // The secondary page is still loading: its listener is registered 300 ms
    // after the window exists, while main asks for a series right away.
    bus.currentLabel = "secondary";
    void secondary.onSeriesRequest(handler);
    bus.currentLabel = "main";
    const sent = main.requestSeriesInSecondary(REQUEST);
    sent.catch(() => {});

    await vi.advanceTimersByTimeAsync(1_000);
    await expect(sent).resolves.toMatchObject({ requestId: expect.any(String) });
    expect(handler).toHaveBeenCalledTimes(1);
    expect(handler).toHaveBeenCalledWith(REQUEST);
  });

  it("runs the series once even if the request is delivered repeatedly", async () => {
    bus.registrationDelayMs.set("secondary", 250);
    const main = bridgeFor("main", { retryIntervalMs: 20 });
    const secondary = bridgeFor("secondary");
    const handler = vi.fn();
    bus.currentLabel = "secondary";
    void secondary.onSeriesRequest(handler);
    bus.currentLabel = "main";

    const sent = main.requestSeriesInSecondary(REQUEST);
    await vi.advanceTimersByTimeAsync(1_000);
    await sent;
    // Replay every series event that reached the secondary once more.
    for (const e of bus.emitted.filter((e) => e.target === "secondary")) bus.deliver(e.target, e.event, e.payload);
    await vi.advanceTimersByTimeAsync(100);

    expect(handler).toHaveBeenCalledTimes(1);
  });

  it("fails with a clear error when the secondary never confirms, and a late listener does not start it", async () => {
    const main = bridgeFor("main", { confirmTimeoutMs: 2_000 });
    const sent = main.requestSeriesInSecondary(REQUEST);
    const outcome = sent.then(
      () => "resolved",
      (error: Error) => error.message,
    );

    await vi.advanceTimersByTimeAsync(2_500);
    expect(await outcome).toMatch(/не подтвердило/);

    // The secondary finally starts listening after main gave up.
    const handler = vi.fn();
    bus.currentLabel = "secondary";
    await bridgeFor("secondary").onSeriesRequest(handler);
    bus.currentLabel = "main";
    await vi.advanceTimersByTimeAsync(1_000);
    expect(handler).not.toHaveBeenCalled();
    // main no longer listens for confirmations of the abandoned request.
    expect(bus.listeners.get("main/lab://run-series-ack")?.size ?? 0).toBe(0);
  });

  it("ignores a confirmation that belongs to another request", async () => {
    const main = bridgeFor("main", { confirmTimeoutMs: 1_000 });
    const sent = main.requestSeriesInSecondary(REQUEST);
    const outcome = sent.then(
      () => "resolved",
      (error: Error) => error.message,
    );
    await vi.advanceTimersByTimeAsync(50);
    // A late acknowledgement of an earlier, abandoned request arrives.
    bus.deliver("main", "lab://run-series-ack", { requestId: "stale-request" });
    await vi.advanceTimersByTimeAsync(1_100);
    expect(await outcome).toMatch(/не подтвердило/);
  });

  it("fails fast when the secondary window is closed during the handshake", async () => {
    const main = bridgeFor("main", { confirmTimeoutMs: 5_000, retryIntervalMs: 100 });
    const sent = main.requestSeriesInSecondary(REQUEST);
    const outcome = sent.then(
      () => "resolved",
      (error: Error) => error.message,
    );
    await vi.advanceTimersByTimeAsync(150);
    bus.openWindows.delete("secondary");
    await vi.advanceTimersByTimeAsync(300);
    expect(await outcome).toMatch(/не открыто|закрыто/);
  });

  it("does not report success when the secondary handler fails to start the series", async () => {
    const main = bridgeFor("main", { confirmTimeoutMs: 1_000 });
    const secondary = bridgeFor("secondary");
    bus.currentLabel = "secondary";
    await secondary.onSeriesRequest(() => {
      throw new Error("cannot start");
    });
    bus.currentLabel = "main";
    const outcome = main.requestSeriesInSecondary(REQUEST).then(
      () => "resolved",
      (error: Error) => error.message,
    );
    await vi.advanceTimersByTimeAsync(1_100);
    expect(await outcome).toMatch(/не подтвердило/);
  });

  it("rejects immediately when the secondary window is not open", async () => {
    bus.openWindows.delete("secondary");
    const main = bridgeFor("main");
    await expect(main.requestSeriesInSecondary(REQUEST)).rejects.toThrow(/не открыто/);
    expect(bus.emitted).toHaveLength(0);
  });

  it("reports completion of exactly the confirmed series", async () => {
    const main = bridgeFor("main");
    const secondary = bridgeFor("secondary");
    let finishSeries!: () => void;
    bus.currentLabel = "secondary";
    await secondary.onSeriesRequest(() => new Promise<void>((resolve) => (finishSeries = resolve)));
    bus.currentLabel = "main";

    const series = await main.requestSeriesInSecondary(REQUEST);
    let completion: unknown = null;
    void series.completed.then((value) => (completion = value));
    // A report about another request must not settle this one.
    bus.deliver("main", "lab://run-series-done", { requestId: "older-request", ok: true });
    await vi.advanceTimersByTimeAsync(100);
    expect(completion).toBeNull();

    finishSeries();
    await vi.advanceTimersByTimeAsync(10);
    expect(completion).toEqual({ ok: true });
    expect(bus.listeners.get("main/lab://run-series-done")?.size ?? 0).toBe(0);
  });

  it("reports a series that failed in the secondary", async () => {
    const main = bridgeFor("main");
    const secondary = bridgeFor("secondary");
    bus.currentLabel = "secondary";
    await secondary.onSeriesRequest(async () => {
      throw new Error("series broke");
    });
    bus.currentLabel = "main";
    const series = await main.requestSeriesInSecondary(REQUEST);
    await vi.advanceTimersByTimeAsync(10);
    await expect(series.completed).resolves.toEqual({ ok: false, error: "series broke" });
  });

  it("settles completion when the secondary closes before reporting", async () => {
    const main = bridgeFor("main", { closedCheckIntervalMs: 200 });
    const secondary = bridgeFor("secondary");
    bus.currentLabel = "secondary";
    await secondary.onSeriesRequest(() => new Promise<void>(() => {}));
    bus.currentLabel = "main";
    const series = await main.requestSeriesInSecondary(REQUEST);
    bus.openWindows.delete("secondary");
    await vi.advanceTimersByTimeAsync(250);
    await expect(series.completed).resolves.toMatchObject({ ok: false, error: expect.stringMatching(/закрыто/) });
  });
});
