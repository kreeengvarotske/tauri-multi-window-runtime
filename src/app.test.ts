import { beforeEach, describe, expect, it, vi } from "vitest";
import { mountApp } from "./app";
import { createRuntimeClient, type RuntimeTransport } from "./lib/runtime";
import type { SeriesRequest, WindowBridge, WindowIdentity } from "./lib/windows";
import { SAMPLE_STATS, deferred, fakeCoreTransport, flush, instantMock } from "./test/fakes";

const MAIN: WindowIdentity = { label: "main", native: true };
const SECONDARY: WindowIdentity = { label: "secondary", native: true };

/** In-memory stand-in for window-to-window messaging. */
function fakeBridge() {
  let handler: ((request: SeriesRequest) => unknown) | null = null;
  const bridge: WindowBridge & { sent: SeriesRequest[]; deliver(request: SeriesRequest): void } = {
    sent: [],
    requestSeriesInSecondary: vi.fn(async (request: SeriesRequest) => {
      bridge.sent.push(request);
      return { requestId: `request-${bridge.sent.length}`, completed: Promise.resolve({ ok: true }) };
    }),
    async onSeriesRequest(h) {
      handler = h;
      return () => (handler = null);
    },
    deliver: (request) => void handler?.(request),
  };
  return bridge;
}

let root: HTMLElement;
beforeEach(() => {
  document.body.innerHTML = "";
  root = document.createElement("main");
  document.body.append(root);
});

function mountMock(identity = MAIN, mock = instantMock({ windowLabel: identity.label })) {
  mountApp(root, {
    setup: { runtime: createRuntimeClient(mock), mock },
    identity,
    openSecondary: vi.fn(),
    bridge: fakeBridge(),
  });
  return mock;
}

function mountTauri(
  transport: RuntimeTransport,
  openSecondary = vi.fn(),
  identity: WindowIdentity = MAIN,
  bridge: WindowBridge = fakeBridge(),
) {
  mountApp(root, { setup: { runtime: createRuntimeClient(transport), mock: null }, identity, openSecondary, bridge });
  return openSecondary;
}

const $ = <T extends HTMLElement = HTMLElement>(selector: string) => root.querySelector<T>(selector)!;
const out = (name: string) => $(`[data-out="${name}"]`).textContent;
const button = (text: string) =>
  [...root.querySelectorAll("button")].find((b) => b.textContent === text) as HTMLButtonElement;

function setInput(selector: string, value: string) {
  const el = $<HTMLInputElement | HTMLSelectElement>(selector);
  el.value = value;
  el.dispatchEvent(new Event("change"));
}

describe("Runtime Lab UI", () => {
  it("marks mock mode with a badge and a warning banner", () => {
    mountMock();
    expect($(".badge-warn").textContent).toContain("MOCK");
    expect($(".banner-warn").textContent).toContain("Rust Core не подключён");
  });

  it("shows no mock controls or banner in tauri mode", () => {
    mountTauri(fakeCoreTransport());
    expect(root.querySelector(".banner-warn")).toBeNull();
    expect(root.querySelector("#mock-failure-rate")).toBeNull();
  });

  it("runs a successful series and records it in history", async () => {
    mountMock();
    setInput("#project-id", "demo");
    setInput("#series-size", "10");
    button("Выполнить серию запросов").click();
    await flush();

    expect(out("sent")).toBe("10");
    expect(out("succeeded")).toBe("10");
    expect(out("failed")).toBe("0");
    expect(out("distinct")).toBe("10");
    expect(JSON.parse(out("sample")!)).toMatchObject({ projectId: "demo", name: "Demo project" });
    expect(button("Повторить серию").hidden).toBe(true);
    expect(root.querySelectorAll(".history-item")).toHaveLength(1);
  });

  it("shows error codes and offers a retry after a failed series", async () => {
    mountMock();
    setInput("#project-id", "missing");
    setInput("#series-size", "20");
    button("Выполнить серию запросов").click();
    await flush();

    expect(out("failed")).toBe("20");
    expect(out("state")).toContain("PROJECT_NOT_FOUND × 20");
    expect(out("last-error")).toMatch(/^PROJECT_NOT_FOUND: /);
    const retry = button("Повторить серию");
    expect(retry.hidden).toBe(false);

    retry.click();
    await flush();
    expect(root.querySelectorAll(".history-item.has-errors")).toHaveLength(2);
  });

  it("applies the mock failure rate control", async () => {
    mountMock();
    setInput("#mock-failure-rate", "1");
    button("Выполнить серию запросов").click();
    await flush();
    expect(out("state")).toContain("OPERATION_FAILED");
  });

  it("denies a main-only project in the secondary window (mock access rule)", async () => {
    mountMock({ label: "secondary", native: true });
    setInput("#project-id", "main-only");
    button("Выполнить серию запросов").click();
    await flush();
    expect(out("state")).toContain("ACCESS_DENIED");
  });

  it("disables the run button while a series is in flight", async () => {
    const pending = deferred<never>();
    mountTauri({ ...fakeCoreTransport(), getProjectMetadata: () => pending.promise });
    const run = button("Выполнить серию запросов");
    run.click();
    expect(run.disabled).toBe(true);
    expect(out("state")).toContain("Выполняется");

    pending.reject({ code: "INTERNAL", message: "boom" });
    await flush();
    expect(run.disabled).toBe(false);
    expect(out("last-error")).toBe("INTERNAL: boom");
  });

  it("reports that Core stats are unavailable in mock mode", async () => {
    mountMock();
    button("Обновить статистику Core").click();
    await flush();
    expect($('[data-stat="status"]').textContent).toContain("STATS_UNAVAILABLE_IN_MOCK");
    expect($('[data-stat="requestsReceived"]').textContent).toBe("—");
  });

  it("renders Core stats, cache policy and the invariant check", async () => {
    mountTauri(fakeCoreTransport());
    button("Обновить").click();
    await flush();
    expect($('[data-stat="requestsReceived"]').textContent).toBe(String(SAMPLE_STATS.requestsReceived));
    expect($('[data-stat="coalescedRequests"]').textContent).toBe("49");
    expect($('[data-stat="cachePolicy"]').textContent).toContain("TTL 30000 мс");
    expect($('[data-stat="invariant"]').className).toContain("text-ok");
  });

  it("flags stats that break the invariant", async () => {
    mountTauri(fakeCoreTransport({ ...SAMPLE_STATS, requestsReceived: 99 }));
    button("Обновить").click();
    await flush();
    expect($('[data-stat="invariant"]').textContent).toContain("нарушен");
  });

  it("invalidates the selected project from the cache in the main Tauri window", async () => {
    const transport = fakeCoreTransport();
    const invalidateProject = vi.fn(async ({ projectId }: { projectId: string }) => ({
      invalidated: projectId === "project-42",
    }));
    mountTauri({ ...transport, invalidateProject });
    button("Инвалидировать проект").click();
    await flush();

    expect(invalidateProject).toHaveBeenCalledWith({ projectId: "project-42" });
    expect($("[data-cache-admin-status]").textContent).toContain("Кэш проекта «project-42» инвалидирован.");
  });

  it("clears the cache from the main Tauri window", async () => {
    const transport = fakeCoreTransport();
    const clearCache = vi.fn(async () => undefined);
    mountTauri({ ...transport, clearCache });
    button("Очистить весь кэш").click();
    await flush();

    expect(clearCache).toHaveBeenCalledOnce();
    expect($("[data-cache-admin-status]").textContent).toContain("Общий кэш очищен.");
  });

  it("does not render cache administration controls in the secondary window", () => {
    mountTauri(fakeCoreTransport(), vi.fn(), { label: "secondary", native: true });
    expect(button("Инвалидировать проект")).toBeUndefined();
    expect(button("Очистить весь кэш")).toBeUndefined();
  });

  it("hides real cache administration in mock mode", () => {
    mountMock();
    expect(button("Инвалидировать проект")).toBeUndefined();
    expect(button("Очистить весь кэш")).toBeUndefined();
  });

  it("shows ACCESS_DENIED returned by a cache administration command", async () => {
    const transport = fakeCoreTransport();
    const invalidateProject = vi.fn(async () => {
      throw { code: "ACCESS_DENIED", message: "Only main is allowed" };
    });
    mountTauri({ ...transport, invalidateProject });
    button("Инвалидировать проект").click();
    await flush();

    expect($("[data-cache-admin-status]").className).toContain("text-error");
    expect($("[data-cache-admin-status]").textContent).toContain("ACCESS_DENIED: Only main is allowed");
  });

  it("opens the secondary window through the injected window API", async () => {
    const openSecondary = vi.fn().mockResolvedValue("created");
    mountTauri(fakeCoreTransport(), openSecondary);
    button("Открыть второе окно").click();
    await flush();
    expect(openSecondary).toHaveBeenCalledOnce();
    expect(root.textContent).toContain("Создано окно «secondary»");
  });

  it("does not offer to open windows from the secondary window", () => {
    mountMock({ label: "secondary", native: true });
    expect(button("Открыть второе окно")).toBeUndefined();
  });

  it("shows empty states before any request", () => {
    mountTauri(fakeCoreTransport());
    expect(root.textContent).toContain("Серий пока не было.");
    expect(root.querySelectorAll(".history-item")).toHaveLength(0);
    expect(out("sample")).toBe("Нет данных");
    expect(out("last-error")).toBe("Нет ошибок");
    expect($('[data-stat="requestsReceived"]').textContent).toBe("—");
    expect($('[data-stat="invariant"]').hidden).toBe(true);
  });

  it("shows a loading state while stats are requested", async () => {
    const pending = deferred<typeof SAMPLE_STATS>();
    mountTauri({ ...fakeCoreTransport(), getDebugStats: () => pending.promise });
    const refresh = button("Обновить");
    refresh.click();
    expect(refresh.disabled).toBe(true);
    expect($(".stats-grid").classList.contains("is-loading")).toBe(true);
    expect($('[data-stat="status"]').textContent).toContain("Запрашиваю");

    pending.resolve(SAMPLE_STATS);
    await flush();
    expect(refresh.disabled).toBe(false);
    expect($(".stats-grid").classList.contains("is-loading")).toBe(false);
  });

  it("shows a failure state when Core has no stats command", async () => {
    mountTauri({
      ...fakeCoreTransport(),
      getDebugStats: () => Promise.reject("Command runtime_get_debug_stats not found"),
    });
    button("Обновить").click();
    await flush();
    const status = $('[data-stat="status"]');
    expect(status.className).toContain("text-error");
    expect(status.textContent).toMatch(/^COMMAND_NOT_FOUND: /);
  });

  it("rejects an empty projectId without reaching the backend", async () => {
    const transport = fakeCoreTransport();
    mountTauri(transport);
    setInput("#project-id", "  ");
    button("Выполнить серию запросов").click();
    await flush();
    expect(transport.calls).toBe(0);
    expect(out("state")).toContain("INVALID_ARGUMENT × 1");
  });

  it("shows a configuration error instead of the app", () => {
    mountApp(root, { setup: { error: new Error("bad mode") }, identity: MAIN });
    expect($(".banner-error").textContent).toContain("bad mode");
    expect(root.querySelector("button")).toBeNull();
  });

  it("polls Core stats while a series runs and checks the invariant afterwards", async () => {
    const pending = deferred<never>();
    const getDebugStats = vi.fn(async () => SAMPLE_STATS);
    mountTauri({ ...fakeCoreTransport(), getProjectMetadata: () => pending.promise, getDebugStats });
    vi.useFakeTimers();
    try {
      button("Выполнить серию запросов").click();
      await vi.advanceTimersByTimeAsync(1100);
      expect(getDebugStats.mock.calls.length).toBeGreaterThanOrEqual(3);
      expect($('[data-stat="invariant"]').textContent).toContain("Серия выполняется");

      pending.reject({ code: "INTERNAL", message: "boom" });
      await vi.advanceTimersByTimeAsync(0);
      const callsAfterSeries = getDebugStats.mock.calls.length;
      await vi.advanceTimersByTimeAsync(2000);
      expect(getDebugStats.mock.calls.length).toBe(callsAfterSeries);
      expect($('[data-stat="invariant"]').textContent).toContain("Инвариант выполнен");
    } finally {
      vi.useRealTimers();
    }
  });

  it("shows when the cached result of the last series expires", async () => {
    mountTauri(fakeCoreTransport());
    button("Выполнить серию запросов").click();
    await flush();
    await flush();
    expect($('[data-stat="cache-timer"]').hidden).toBe(false);
    // fakeCoreTransport answers computedAtMs 42, long in the past.
    expect($('[data-stat="cache-timer"]').textContent).toContain("истёк");
  });

  it("refreshes stats and the timer when any window invalidates the cache", async () => {
    let emit: ((event: { projectId: string | null }) => void) | null = null;
    const getDebugStats = vi.fn(async () => SAMPLE_STATS);
    mountTauri(
      {
        ...fakeCoreTransport(),
        getDebugStats,
        async onCacheInvalidated(handler) {
          emit = handler;
          return () => {};
        },
      },
      vi.fn(),
      SECONDARY,
    );
    button("Выполнить серию запросов").click();
    await flush();
    await flush();
    const calls = getDebugStats.mock.calls.length;

    emit!({ projectId: "project-42" });
    await flush();
    expect(getDebugStats.mock.calls.length).toBe(calls + 1);
    expect($('[data-stat="cache-timer"]').textContent).toContain("сброшен");
  });

  it("asks the secondary window to run the same series, then runs it here", async () => {
    const bridge = fakeBridge();
    const transport = fakeCoreTransport();
    mountTauri(transport, vi.fn(), MAIN, bridge);
    setInput("#project-id", "demo");
    setInput("#series-size", "20");
    button("Серия в обоих окнах").click();
    await flush();
    await flush();
    expect(bridge.sent).toEqual([{ projectId: "demo", size: 20 }]);
    expect(transport.calls).toBe(20);
    expect(out("state")).toContain("все 20 ответов успешны");
  });

  it("reports a closed secondary window instead of running half a demo", async () => {
    const bridge = fakeBridge();
    bridge.requestSeriesInSecondary = vi.fn().mockRejectedValue(new Error("Окно «secondary» не открыто."));
    const transport = fakeCoreTransport();
    mountTauri(transport, vi.fn(), MAIN, bridge);
    button("Серия в обоих окнах").click();
    await flush();
    expect(transport.calls).toBe(0);
    expect(out("state")).toContain("не открыто");
    expect(button("Серия в обоих окнах").disabled).toBe(false);
  });

  it("runs a series requested by the main window in the secondary window", async () => {
    const bridge = fakeBridge();
    const transport = fakeCoreTransport();
    mountTauri(transport, vi.fn(), SECONDARY, bridge);
    expect(button("Серия в обоих окнах").hidden).toBe(true);
    await flush();
    bridge.deliver({ projectId: "demo", size: 10 });
    await flush();
    await flush();
    expect(transport.calls).toBe(10);
    expect($<HTMLInputElement>("#project-id").value).toBe("demo");
    expect(out("state")).toContain("все 10 ответов успешны");
  });

  it("exports the series history as JSON", async () => {
    const writeText = vi.fn(async (_text: string) => {});
    Object.defineProperty(navigator, "clipboard", { value: { writeText }, configurable: true });
    mountMock();
    expect(button("Скопировать JSON").closest(".row")!.hasAttribute("hidden")).toBe(true);
    setInput("#project-id", "missing");
    button("Выполнить серию запросов").click();
    await flush();

    button("Скопировать JSON").click();
    await flush();
    const exported = JSON.parse(writeText.mock.calls[0][0]);
    expect(exported).toHaveLength(1);
    expect(exported[0]).toMatchObject({ projectId: "missing", failed: 1, mode: "mock" });
    expect(exported[0].finishedAt).toMatch(/^\d{4}-\d\d-\d\dT/);
    expect(exported[0].lastError).toMatch(/^PROJECT_NOT_FOUND: /);
    expect(out("history-export")).toBe("Скопировано серий: 1.");
  });
});
