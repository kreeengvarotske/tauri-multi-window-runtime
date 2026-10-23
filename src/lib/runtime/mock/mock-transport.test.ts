import { describe, expect, it, vi } from "vitest";
import { createRuntimeClient } from "../client";
import { instantMock } from "../../../test/fakes";
import { createMockTransport } from "./mock-transport";

describe("mock transport", () => {
  it("returns typed fixture data with its own computedAtMs per call", async () => {
    const runtime = createRuntimeClient(instantMock());
    const [a, b] = await Promise.all([
      runtime.projects.getMetadata({ projectId: "demo" }),
      runtime.projects.getMetadata({ projectId: "demo" }),
    ]);
    expect(a).toMatchObject({ projectId: "demo", name: "Demo project", revision: 3 });
    expect(a.computedAtMs).not.toBe(b.computedAtMs);
  });

  it.each([
    ["missing", "PROJECT_NOT_FOUND"],
    ["broken", "OPERATION_FAILED"],
    ["forbidden", "ACCESS_DENIED"],
  ])("fixture %s fails with %s in the IpcError shape", async (projectId, code) => {
    const raw = await instantMock()
      .getProjectMetadata({ projectId })
      .catch((e: unknown) => e);
    expect(raw).toEqual({ code, message: expect.stringContaining("MOCK") });
  });

  it("decides access from its own window label, not from call arguments", async () => {
    const inMain = createRuntimeClient(instantMock({ windowLabel: "main" }));
    const inSecondary = createRuntimeClient(instantMock({ windowLabel: "secondary" }));
    await expect(inMain.projects.getMetadata({ projectId: "main-only" })).resolves.toMatchObject({ projectId: "main-only" });
    await expect(inSecondary.projects.getMetadata({ projectId: "main-only" })).rejects.toMatchObject({
      code: "ACCESS_DENIED",
    });
  });

  it("simulates operation failures by failureRate", async () => {
    const mock = instantMock({ random: () => 0.3 });
    mock.failureRate = 0.5;
    await expect(createRuntimeClient(mock).projects.getMetadata({ projectId: "demo" })).rejects.toMatchObject({
      code: "OPERATION_FAILED",
    });
    mock.failureRate = 0.2;
    await expect(createRuntimeClient(mock).projects.getMetadata({ projectId: "demo" })).resolves.toBeTruthy();
  });

  it("waits within the configured delay range", async () => {
    const sleep = vi.fn(() => Promise.resolve());
    const mock = createMockTransport({ sleep, random: () => 0.5, delayMs: { min: 100, max: 300 } });
    await mock.getProjectMetadata({ projectId: "demo" });
    expect(sleep).toHaveBeenCalledWith(200);
  });

  it("allows cache commands only in the main window", async () => {
    const inMain = createRuntimeClient(instantMock({ windowLabel: "main" }));
    const inSecondary = createRuntimeClient(instantMock({ windowLabel: "secondary" }));
    await expect(inMain.cache.invalidateProject({ projectId: "demo" })).resolves.toEqual({ invalidated: false });
    await expect(inMain.cache.clear()).resolves.toBeUndefined();
    await expect(inSecondary.cache.invalidateProject({ projectId: "demo" })).rejects.toMatchObject({
      code: "ACCESS_DENIED",
    });
    await expect(inSecondary.cache.clear()).rejects.toMatchObject({ code: "ACCESS_DENIED" });
  });

  it("does not fake Core stats", async () => {
    await expect(createRuntimeClient(instantMock()).diagnostics.getStats()).rejects.toMatchObject({
      code: "STATS_UNAVAILABLE_IN_MOCK",
    });
  });
});
