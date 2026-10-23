// Public SDK API. UI code talks to Rust Core only through this module.
//
// Intentionally absent: request deduplication, caching and retries. Those are
// responsibilities of Rust Core; every call here reaches the transport.
// The frontend never sends window ids, access scopes or similar fields:
// access context is determined and verified by Core.

import { createMockTransport, type MockTransport } from "./mock-client";
import { createTauriTransport } from "./tauri-client";
import {
  RuntimeError,
  type GetMetadataParams,
  type ProjectMetadata,
  type RuntimeDebugStats,
  type RuntimeMode,
  type RuntimeTransport,
} from "./types";

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
        guard(() => {
          const projectId = params.projectId.trim();
          if (!projectId) {
            throw new RuntimeError("INVALID_ARGUMENT", "projectId не может быть пустым.");
          }
          return transport.getProjectMetadata({ projectId });
        }),
    },
    diagnostics: {
      getStats: () => guard(() => transport.getDebugStats()),
    },
  };
}

/** Guarantees that every rejection reaching the UI is a RuntimeError. */
async function guard<T>(fn: () => Promise<T>): Promise<T> {
  try {
    return await fn();
  } catch (error) {
    if (error instanceof RuntimeError) throw error;
    const message = error instanceof Error ? error.message : String(error);
    throw new RuntimeError("UNKNOWN", message, { originalError: error });
  }
}

export interface RuntimeSetup {
  runtime: RuntimeClient;
  /** Present only in mock mode, for controls that simulate failures. */
  mock: MockTransport | null;
}

/**
 * Builds the client from `VITE_RUNTIME_MODE`. There is no silent fallback:
 * an unknown value is a configuration error, and an IPC failure in tauri mode
 * is reported as an error instead of switching to mock.
 */
export function createRuntimeFromEnv(rawMode: string | undefined = import.meta.env.VITE_RUNTIME_MODE): RuntimeSetup {
  const mode = (rawMode ?? "tauri").trim().toLowerCase();
  if (mode === "mock") {
    const mock = createMockTransport();
    return { runtime: createRuntimeClient(mock), mock };
  }
  if (mode === "tauri") {
    return { runtime: createRuntimeClient(createTauriTransport()), mock: null };
  }
  throw new Error(`Неизвестное значение VITE_RUNTIME_MODE: «${rawMode}». Ожидается «tauri» или «mock».`);
}

export { RuntimeError } from "./types";
export type { ProjectMetadata, RuntimeDebugStats, RuntimeMode } from "./types";
