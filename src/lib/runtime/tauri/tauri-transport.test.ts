import { beforeEach, describe, expect, it, vi } from "vitest";

const tauri = vi.hoisted(() => ({ isTauri: vi.fn(), invoke: vi.fn() }));
vi.mock("@tauri-apps/api/core", () => tauri);

import { createRuntimeClient } from "../client";
import { createTauriTransport } from "./tauri-transport";

describe("tauri transport", () => {
  beforeEach(() => {
    tauri.isTauri.mockReset();
    tauri.invoke.mockReset();
  });

  it("reports IPC_UNAVAILABLE outside Tauri and never calls invoke", async () => {
    tauri.isTauri.mockReturnValue(false);
    const runtime = createRuntimeClient(createTauriTransport());
    await expect(runtime.projects.getMetadata({ projectId: "demo" })).rejects.toMatchObject({ code: "IPC_UNAVAILABLE" });
    expect(tauri.invoke).not.toHaveBeenCalled();
  });

  it("calls the contract commands with camelCase args", async () => {
    tauri.isTauri.mockReturnValue(true);
    tauri.invoke.mockResolvedValue({});
    const transport = createTauriTransport();
    await transport.getProjectMetadata({ projectId: "demo" });
    await transport.getDebugStats();
    await transport.invalidateProject({ projectId: "demo" });
    await transport.clearCache();
    expect(tauri.invoke).toHaveBeenNthCalledWith(1, "runtime_get_project_metadata", { projectId: "demo" });
    expect(tauri.invoke).toHaveBeenNthCalledWith(2, "runtime_get_debug_stats", undefined);
    expect(tauri.invoke).toHaveBeenNthCalledWith(3, "runtime_invalidate_project", { projectId: "demo" });
    expect(tauri.invoke).toHaveBeenNthCalledWith(4, "runtime_clear_cache", undefined);
  });

  it("surfaces Core IpcError codes through the client", async () => {
    tauri.isTauri.mockReturnValue(true);
    tauri.invoke.mockRejectedValue({ code: "PROJECT_NOT_FOUND", message: "Project 'x' not found" });
    const runtime = createRuntimeClient(createTauriTransport());
    await expect(runtime.projects.getMetadata({ projectId: "x" })).rejects.toMatchObject({
      code: "PROJECT_NOT_FOUND",
      message: "Project 'x' not found",
    });
  });

  it("maps an unregistered command to COMMAND_NOT_FOUND", async () => {
    tauri.isTauri.mockReturnValue(true);
    tauri.invoke.mockRejectedValue("Command runtime_get_project_metadata not found");
    const runtime = createRuntimeClient(createTauriTransport());
    await expect(runtime.projects.getMetadata({ projectId: "demo" })).rejects.toMatchObject({
      code: "COMMAND_NOT_FOUND",
    });
  });
});
