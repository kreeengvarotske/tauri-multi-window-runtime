import { describe, expect, it, vi } from "vitest";
import { createRuntimeClient, createRuntimeFromEnv } from "./client";
import { RuntimeError } from "./errors";
import type { RuntimeTransport } from "./transport";
import { fakeCoreTransport } from "../../test/fakes";

describe("createRuntimeClient", () => {
  it("sends every call to the transport: no dedup or cache in the SDK", async () => {
    const transport = fakeCoreTransport();
    const runtime = createRuntimeClient(transport);
    await Promise.all(Array.from({ length: 20 }, () => runtime.projects.getMetadata({ projectId: "demo" })));
    expect(transport.calls).toBe(20);
  });

  it("trims projectId and sends only projectId", async () => {
    const getProjectMetadata = vi.fn(async ({ projectId }: { projectId: string }) => ({
      projectId,
      name: "n",
      revision: 1,
      computedAtMs: 1,
    }));
    const runtime = createRuntimeClient({ ...fakeCoreTransport(), getProjectMetadata });
    await runtime.projects.getMetadata({ projectId: "  demo " });
    expect(getProjectMetadata).toHaveBeenCalledWith({ projectId: "demo" });
  });

  it.each([[""], ["   "], ["x".repeat(129)]])("rejects invalid projectId %j before the transport", async (projectId) => {
    const transport = fakeCoreTransport();
    const runtime = createRuntimeClient(transport);
    await expect(runtime.projects.getMetadata({ projectId })).rejects.toMatchObject({ code: "INVALID_ARGUMENT" });
    expect(transport.calls).toBe(0);
  });

  it("turns raw transport rejections into RuntimeError with the command name", async () => {
    const transport: RuntimeTransport = {
      ...fakeCoreTransport(),
      getProjectMetadata: () => Promise.reject({ code: "ACCESS_DENIED", message: "nope" }),
      getDebugStats: () => Promise.reject("Command runtime_get_debug_stats not found"),
    };
    const runtime = createRuntimeClient(transport);

    const metadataError = await runtime.projects.getMetadata({ projectId: "demo" }).catch((e: unknown) => e);
    expect(metadataError).toBeInstanceOf(RuntimeError);
    expect(metadataError).toMatchObject({ code: "ACCESS_DENIED", command: "runtime_get_project_metadata" });

    await expect(runtime.diagnostics.getStats()).rejects.toMatchObject({
      code: "COMMAND_NOT_FOUND",
      command: "runtime_get_debug_stats",
    });
  });
});

describe("runtime.cache", () => {
  it("trims and validates projectId before invalidating", async () => {
    const invalidateProject = vi.fn(async () => ({ invalidated: true }));
    const runtime = createRuntimeClient({ ...fakeCoreTransport(), invalidateProject });
    await expect(runtime.cache.invalidateProject({ projectId: " demo " })).resolves.toEqual({ invalidated: true });
    expect(invalidateProject).toHaveBeenCalledWith({ projectId: "demo" });

    await expect(runtime.cache.invalidateProject({ projectId: "  " })).rejects.toMatchObject({ code: "INVALID_ARGUMENT" });
    expect(invalidateProject).toHaveBeenCalledOnce();
  });

  it("normalizes ACCESS_DENIED from Core with the command name", async () => {
    const runtime = createRuntimeClient({
      ...fakeCoreTransport(),
      clearCache: () => Promise.reject({ code: "ACCESS_DENIED", message: "main only" }),
    });
    await expect(runtime.cache.clear()).rejects.toMatchObject({
      code: "ACCESS_DENIED",
      command: "runtime_clear_cache",
    });
  });
});

describe("createRuntimeFromEnv", () => {
  it("builds a mock runtime with controls", () => {
    const { runtime, mock } = createRuntimeFromEnv("mock");
    expect(runtime.mode).toBe("mock");
    expect(mock?.knownProjectIds).toContain("demo");
  });

  it("builds a tauri runtime without mock controls, case-insensitively", () => {
    const { runtime, mock } = createRuntimeFromEnv(" TAURI ");
    expect(runtime.mode).toBe("tauri");
    expect(mock).toBeNull();
  });

  it("fails loudly on an unknown mode instead of falling back to mock", () => {
    expect(() => createRuntimeFromEnv("prod")).toThrow(/VITE_RUNTIME_MODE/);
  });
});
