import type { InvalidateProjectResult, ProjectMetadata, RuntimeDebugStats, RuntimeTransport } from "../lib/runtime";
import { createMockTransport, type MockTransportOptions } from "../lib/runtime/mock/mock-transport";

/** Mock transport without delays, for fast deterministic tests. */
export function instantMock(options: MockTransportOptions = {}) {
  let t = 1_000;
  return createMockTransport({ sleep: () => Promise.resolve(), random: () => 0.5, now: () => t++, ...options });
}

export const SAMPLE_STATS: RuntimeDebugStats = {
  requestsReceived: 50,
  operationsExecuted: 1,
  coalescedRequests: 49,
  cacheHits: 0,
  failedRequests: 0,
  cachedEntries: 1,
  cachePolicy: { kind: "ttl", ttlMs: 30000 },
};

/** Stands in for Core in tauri mode: one shared result per series, like coalescing would give. */
export function fakeCoreTransport(stats: RuntimeDebugStats = SAMPLE_STATS): RuntimeTransport & { calls: number } {
  const transport = {
    mode: "tauri" as const,
    calls: 0,
    async getProjectMetadata({ projectId }: { projectId: string }): Promise<ProjectMetadata> {
      transport.calls++;
      return { projectId, name: "Shared", revision: 1, computedAtMs: 42 };
    },
    async getDebugStats() {
      return stats;
    },
    async invalidateProject(): Promise<InvalidateProjectResult> {
      return { invalidated: true };
    },
    async clearCache(): Promise<void> {},
  };
  return transport;
}

export function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

/** Lets pending promise callbacks and DOM updates run. */
export const flush = () => new Promise<void>((resolve) => setTimeout(resolve, 0));
