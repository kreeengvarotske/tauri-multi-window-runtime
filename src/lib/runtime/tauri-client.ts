// The only module that talks to Tauri IPC directly.

import { invoke, isTauri } from "@tauri-apps/api/core";
import {
  RuntimeCommand,
  RuntimeError,
  type GetMetadataParams,
  type ProjectMetadata,
  type RuntimeCommandName,
  type RuntimeDebugStats,
  type RuntimeTransport,
} from "./types";

export function createTauriTransport(): RuntimeTransport {
  return {
    mode: "tauri",
    getProjectMetadata: ({ projectId }: GetMetadataParams) =>
      call<ProjectMetadata>(RuntimeCommand.getProjectMetadata, { projectId }),
    getDebugStats: () => call<RuntimeDebugStats>(RuntimeCommand.getDebugStats),
  };
}

async function call<T>(command: RuntimeCommandName, args?: Record<string, unknown>): Promise<T> {
  if (!isTauri()) {
    throw new RuntimeError(
      "IPC_UNAVAILABLE",
      "Tauri IPC недоступен: страница открыта не в окне Tauri. Запустите `npm run tauri dev` или используйте режим MOCK (`npm run dev:mock`).",
      { command },
    );
  }
  try {
    return await invoke<T>(command, args);
  } catch (error) {
    throw normalizeInvokeError(command, error);
  }
}

/**
 * A rejected `invoke` carries whatever Rust serialized as the error: usually a
 * string, sometimes an object. Turn it into a RuntimeError with a readable message.
 */
function normalizeInvokeError(command: RuntimeCommandName, error: unknown): RuntimeError {
  const raw = describe(error);

  // Tauri reports unregistered commands as "Command <name> not found".
  if (/command .* not found/i.test(raw)) {
    return new RuntimeError(
      "COMMAND_NOT_FOUND",
      `Rust Core не предоставляет команду \`${command}\`. Проверьте, что Core собран из ветки с этой командой. (${raw})`,
      { command, originalError: error },
    );
  }

  let coreCode: string | null = null;
  if (isRecord(error) && typeof error.code === "string") coreCode = error.code;

  return new RuntimeError("CORE_ERROR", `Rust Core вернул ошибку на \`${command}\`: ${raw}`, {
    command,
    coreCode,
    originalError: error,
  });
}

function describe(error: unknown): string {
  if (typeof error === "string") return error;
  if (error instanceof Error) return error.message;
  if (isRecord(error) && typeof error.message === "string") return error.message;
  try {
    return JSON.stringify(error);
  } catch {
    return String(error);
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
