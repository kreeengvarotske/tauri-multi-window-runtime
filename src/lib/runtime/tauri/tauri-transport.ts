// Real integration: the only module that calls Tauri IPC.
// Error normalization is done by the client, not here.

import { invoke, isTauri } from "@tauri-apps/api/core";
import {
  RUNTIME_COMMANDS,
  type GetMetadataParams,
  type InvalidateProjectResult,
  type ProjectMetadata,
  type RuntimeCommandName,
  type RuntimeDebugStats,
} from "../contract";
import { RuntimeError } from "../errors";
import type { RuntimeTransport } from "../transport";

export function createTauriTransport(): RuntimeTransport {
  return {
    mode: "tauri",
    getProjectMetadata: ({ projectId }) => call<ProjectMetadata>(RUNTIME_COMMANDS.getProjectMetadata, { projectId }),
    getDebugStats: () => call<RuntimeDebugStats>(RUNTIME_COMMANDS.getDebugStats),
    invalidateProject: ({ projectId }: GetMetadataParams) =>
      call<InvalidateProjectResult>(RUNTIME_COMMANDS.invalidateProject, { projectId }),
    clearCache: () => call<void>(RUNTIME_COMMANDS.clearCache),
  };
}

async function call<T>(command: RuntimeCommandName, args?: Record<string, unknown>): Promise<T> {
  // No silent fallback to mock: outside Tauri this is an explicit error.
  if (!isTauri()) {
    throw new RuntimeError(
      "IPC_UNAVAILABLE",
      "Tauri IPC недоступен: страница открыта не в окне Tauri. Запустите `npm run tauri dev` или режим MOCK (`npm run dev:mock`).",
      { command },
    );
  }
  return invoke<T>(command, args);
}
