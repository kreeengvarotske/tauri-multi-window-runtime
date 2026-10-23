// Mock transport for UI development without Rust Core.
//
// It lives in the JavaScript context of one window: it shares nothing with
// other WebViews and proves nothing about Core behaviour. Every call computes
// its own result (own `computedAtMs`), there is no coalescing or cache here.
// Errors are thrown in the IpcError shape `{ code, message }`, as Core would.

import type { CoreErrorCode, IpcErrorPayload, ProjectMetadata, RuntimeDebugStats } from "../contract";
import { RuntimeError } from "../errors";
import type { RuntimeTransport } from "../transport";
import { MOCK_FAILING_PROJECTS, MOCK_PROJECT_IDS, MOCK_PROJECTS } from "./fixtures";

/** Knobs the UI may show in mock mode only. */
export interface MockControls {
  /** Share of calls (0..1) that fail with OPERATION_FAILED. */
  failureRate: number;
  readonly knownProjectIds: readonly string[];
}

export interface MockTransport extends RuntimeTransport, MockControls {}

export interface MockTransportOptions {
  /** Label of the window this mock runs in; used for the mock access rule. */
  windowLabel?: string;
  delayMs?: { min: number; max: number };
  failureRate?: number;
  random?: () => number;
  now?: () => number;
  sleep?: (ms: number) => Promise<void>;
}

export function createMockTransport(options: MockTransportOptions = {}): MockTransport {
  const {
    windowLabel = "main",
    delayMs = { min: 150, max: 400 },
    random = Math.random,
    now = Date.now,
    sleep = (ms) => new Promise<void>((resolve) => setTimeout(resolve, ms)),
  } = options;

  const transport: MockTransport = {
    mode: "mock",
    failureRate: options.failureRate ?? 0,
    knownProjectIds: MOCK_PROJECT_IDS,

    async getProjectMetadata({ projectId }): Promise<ProjectMetadata> {
      await sleep(delayMs.min + random() * (delayMs.max - delayMs.min));

      const failing = MOCK_FAILING_PROJECTS[projectId];
      if (failing) throw ipcError(failing, `MOCK: проект «${projectId}» всегда отвечает ошибкой ${failing}.`);

      const project = MOCK_PROJECTS[projectId];
      if (!project) throw ipcError("PROJECT_NOT_FOUND", `MOCK: проект «${projectId}» не найден.`);
      if (project.allowedWindows && !project.allowedWindows.some((label) => label === windowLabel)) {
        throw ipcError("ACCESS_DENIED", `MOCK: окну «${windowLabel}» запрещён доступ к проекту «${projectId}».`);
      }
      if (random() < transport.failureRate) {
        throw ipcError("OPERATION_FAILED", `MOCK: имитированная ошибка операции для «${projectId}».`);
      }

      return { projectId, name: project.name, revision: project.revision, computedAtMs: now() };
    },

    async getDebugStats(): Promise<RuntimeDebugStats> {
      // Deliberately not simulated: fake counters would look like Core output.
      throw new RuntimeError(
        "STATS_UNAVAILABLE_IN_MOCK",
        "Статистика ядра недоступна: включён режим MOCK, Rust Core не подключён.",
      );
    },
  };
  return transport;
}

function ipcError(code: CoreErrorCode, message: string): IpcErrorPayload {
  return { code, message };
}
