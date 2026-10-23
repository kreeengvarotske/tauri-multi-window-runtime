// Mock transport for visual development without Rust Core.
//
// It lives in the JavaScript context of one window: it shares nothing with
// other WebViews and proves nothing about Core behaviour or coalescing.

import {
  RuntimeError,
  type GetMetadataParams,
  type ProjectMetadata,
  type RuntimeDebugStats,
  type RuntimeTransport,
} from "./types";

export interface MockTransport extends RuntimeTransport {
  /** Share of calls (0..1) that fail with a simulated error. */
  failureRate: number;
}

const MIN_DELAY_MS = 150;
const MAX_DELAY_MS = 400;

export function createMockTransport(): MockTransport {
  const transport: MockTransport = {
    mode: "mock",
    failureRate: 0,

    async getProjectMetadata({ projectId }: GetMetadataParams): Promise<ProjectMetadata> {
      await delay(MIN_DELAY_MS + Math.random() * (MAX_DELAY_MS - MIN_DELAY_MS));
      if (Math.random() < transport.failureRate) {
        throw new RuntimeError("MOCK_SIMULATED_FAILURE", `MOCK: имитированная ошибка для «${projectId}»`);
      }
      return {
        projectId,
        name: `Демо-проект ${projectId}`,
        revision: 1,
      };
    },

    async getDebugStats(): Promise<RuntimeDebugStats> {
      throw new RuntimeError(
        "STATS_UNAVAILABLE_IN_MOCK",
        "Статистика ядра недоступна: включён режим MOCK, Rust Core не подключён.",
      );
    },
  };
  return transport;
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
