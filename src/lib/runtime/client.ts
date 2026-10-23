// Public SDK API. UI code talks to the backend only through this client.
//
// Intentionally absent: request deduplication, caching and retries. Those are
// responsibilities of Rust Core; every call here reaches the transport.
// The frontend never sends window ids, access scopes or similar fields:
// access context is determined and verified by Core.

import {
  PROJECT_ID_MAX_LENGTH,
  RUNTIME_COMMANDS,
  type GetMetadataParams,
  type ProjectMetadata,
  type RuntimeCommandName,
  type RuntimeDebugStats,
} from "./contract";
import { RuntimeError, normalizeRuntimeError } from "./errors";
import { createMockTransport, type MockControls } from "./mock/mock-transport";
import { createTauriTransport } from "./tauri/tauri-transport";
import type { RuntimeMode, RuntimeTransport } from "./transport";

export interface RuntimeClient {
  readonly mode: RuntimeMode;
  readonly projects: {
    getMetadata(params: GetMetadataParams): Promise<ProjectMetadata>;
  };
  readonly diagnostics: {
    getStats(): Promise<RuntimeDebugStats>;
  };
}

export function createRuntimeClient(transport: RuntimeTransport): RuntimeClient {
  return {
    mode: transport.mode,
    projects: {
      getMetadata: (params) =>
        guard(RUNTIME_COMMANDS.getProjectMetadata, () =>
          transport.getProjectMetadata({ projectId: validateProjectId(params.projectId) }),
        ),
    },
    diagnostics: {
      getStats: () => guard(RUNTIME_COMMANDS.getDebugStats, () => transport.getDebugStats()),
    },
  };
}

/** Same rule as the IPC layer, checked early so obviously bad input never leaves the window. */
function validateProjectId(raw: string): string {
  const projectId = raw.trim();
  if (!projectId) {
    throw new RuntimeError("INVALID_ARGUMENT", "projectId не может быть пустым.");
  }
  if (projectId.length > PROJECT_ID_MAX_LENGTH) {
    throw new RuntimeError("INVALID_ARGUMENT", `projectId длиннее ${PROJECT_ID_MAX_LENGTH} символов.`);
  }
  return projectId;
}

/** Guarantees that every rejection reaching the UI is a RuntimeError. */
async function guard<T>(command: RuntimeCommandName, fn: () => Promise<T>): Promise<T> {
  try {
    return await fn();
  } catch (error) {
    throw normalizeRuntimeError(command, error);
  }
}

export interface RuntimeSetup {
  runtime: RuntimeClient;
  /** Present only in mock mode, for controls that simulate failures. */
  mock: MockControls | null;
}

/**
 * Builds the client from `VITE_RUNTIME_MODE`. There is no silent fallback:
 * an unknown value is a configuration error, and an IPC failure in tauri mode
 * is reported as an error instead of switching to mock.
 */
export function createRuntimeFromEnv(
  rawMode: string | undefined = import.meta.env.VITE_RUNTIME_MODE,
  context: { windowLabel?: string } = {},
): RuntimeSetup {
  const mode = (rawMode ?? "tauri").trim().toLowerCase();
  if (mode === "mock") {
    const mock = createMockTransport({ windowLabel: context.windowLabel });
    return { runtime: createRuntimeClient(mock), mock };
  }
  if (mode === "tauri") {
    return { runtime: createRuntimeClient(createTauriTransport()), mock: null };
  }
  throw new Error(`Неизвестное значение VITE_RUNTIME_MODE: «${rawMode}». Ожидается «tauri» или «mock».`);
}
