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

  it("trims projectId for metadata and cache invalidation", async () => {
    const getProjectMetadata = vi.fn(async ({ projectId }: { projectId: string }) => ({
      projectId,
      name: "n",
      revision: 1,
      computedAtMs: 1,
    }));
    const invalidateProject = vi.fn(async ({ projectId }: { projectId: string }) => ({
      invalidated: projectId === "demo",
    }));
    const runtime = createRuntimeClient({ ...fakeCoreTransport(), getProjectMetadata, invalidateProject });
    await runtime.projects.getMetadata({ projectId: "  demo " });
    await runtime.cache.invalidateProject({ projectId: " demo " });
    expect(getProjectMetadata).toHaveBeenCalledWith({ projectId: "demo" });
    expect(invalidateProject).toHaveBeenCalledWith({ projectId: "demo" });
  });

  it("counts projectId length in Unicode scalar values like Rust", async () => {
    const invalidateProject = vi.fn(async () => ({ invalidated: true }));
    const runtime = createRuntimeClient({ ...fakeCoreTransport(), invalidateProject });
    await runtime.cache.invalidateProject({ projectId: "😀".repeat(128) });
    expect(invalidateProject).toHaveBeenCalledOnce();
    await expect(runtime.cache.invalidateProject({ projectId: "😀".repeat(129) })).rejects.toMatchObject({
      code: "INVALID_ARGUMENT",
    });
    expect(invalidateProject).toHaveBeenCalledOnce();
  });

  it("validates cache administration inputs before transport", async () => {
    const invalidateProject = vi.fn(async () => ({ invalidated: false }));
    const runtime = createRuntimeClient({ ...fakeCoreTransport(), invalidateProject });
    await expect(runtime.cache.invalidateProject({ projectId: "  " })).rejects.toMatchObject({
      code: "INVALID_ARGUMENT",
    });
    expect(invalidateProject).not.toHaveBeenCalled();
  });

  it("uses the transport for cache clear and invalidation", async () => {
    const invalidateProject = vi.fn(async () => ({ invalidated: true }));
    const clearCache = vi.fn(async () => undefined);
    const runtime = createRuntimeClient({ ...fakeCoreTransport(), invalidateProject, clearCache });
    await expect(runtime.cache.invalidateProject({ projectId: "demo" })).resolves.toEqual({ invalidated: true });
    await expect(runtime.cache.clear()).resolves.toBeUndefined();
    expect(invalidateProject).toHaveBeenCalledWith({ projectId: "demo" });
    expect(clearCache).toHaveBeenCalledOnce();
  });

  it.each([[""], ["   "], ["x".repeat(129)]])("rejects invalid projectId %j before the transport", async (projectId) => {
    const transport = fakeCoreTransport();
    const runtime = createRuntimeClient(transport);
    await expect(runtime.projects.getMetadata({ projectId })).rejects.toMatchObject({ code: "INVALID_ARGUMENT" });
    expect(transport.calls).toBe(0);
  });

  it("turns raw transport rejections into RuntimeError with the command name", async () => {
    const transport: RuntimeTransport = {
      mode: "tauri",
      getProjectMetadata: () => Promise.reject({ code: "ACCESS_DENIED", message: "nope" }),
      getDebugStats: () => Promise.reject("Command runtime_get_debug_stats not found"),
      invalidateProject: () => Promise.reject("Command runtime_invalidate_project not found"),
      clearCache: () => Promise.reject("Command runtime_clear_cache not found"),
      onCacheInvalidated: async () => () => {},
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
