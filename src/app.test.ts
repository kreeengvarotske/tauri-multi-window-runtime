import { beforeEach, describe, expect, it, vi } from "vitest";
import { mountApp } from "./app";
import { createRuntimeClient, type RuntimeTransport } from "./lib/runtime";
import type { WindowIdentity } from "./lib/windows";
import { SAMPLE_STATS, deferred, fakeCoreTransport, flush, instantMock } from "./test/fakes";

const MAIN: WindowIdentity = { label: "main", native: true };

let root: HTMLElement;
beforeEach(() => {
  document.body.innerHTML = "";
  root = document.createElement("main");
  document.body.append(root);
});

function mountMock(identity = MAIN, mock = instantMock({ windowLabel: identity.label })) {
  mountApp(root, { setup: { runtime: createRuntimeClient(mock), mock }, identity, openSecondary: vi.fn() });
  return mock;
}

function mountTauri(transport: RuntimeTransport, openSecondary = vi.fn()) {
  mountApp(root, { setup: { runtime: createRuntimeClient(transport), mock: null }, identity: MAIN, openSecondary });
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

  it("invalidates the current project and refreshes Core stats", async () => {
    const transport = fakeCoreTransport();
    const invalidateProject = vi.fn(async () => ({ invalidated: true }));
    const getDebugStats = vi.fn(async () => SAMPLE_STATS);
    mountTauri({ ...transport, invalidateProject, getDebugStats });
    setInput("#project-id", "demo");
    button("Сбросить кэш проекта").click();
    await flush();
    expect(invalidateProject).toHaveBeenCalledWith({ projectId: "demo" });
    expect(out("state")).toContain("Кэш проекта «demo» сброшен");
    expect(getDebugStats).toHaveBeenCalledOnce();
  });

  it("clears the cache and shows Core errors such as ACCESS_DENIED", async () => {
    const clearCache = vi
      .fn()
      .mockResolvedValueOnce(undefined)
      .mockRejectedValueOnce({ code: "ACCESS_DENIED", message: "main only" });
    mountTauri({ ...fakeCoreTransport(), clearCache });
    const clear = button("Очистить весь кэш");
    clear.click();
    await flush();
    expect(out("state")).toBe("Кэш Core очищен.");
    clear.click();
    await flush();
    expect(out("state")).toBe("ACCESS_DENIED: main only");
    expect(clear.disabled).toBe(false);
  });

  it("does not offer cache controls in the secondary window", () => {
    mountMock({ label: "secondary", native: true });
    expect(button("Сбросить кэш проекта")).toBeUndefined();
    expect(button("Очистить весь кэш")).toBeUndefined();
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
});
