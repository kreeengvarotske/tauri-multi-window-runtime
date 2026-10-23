import type { ProjectMetadata, RuntimeClient, RuntimeMode } from "../lib/runtime";
import { RuntimeError } from "../lib/runtime";

export interface SeriesResult {
  finishedAt: Date;
  mode: RuntimeMode;
  projectId: string;
  sent: number;
  succeeded: number;
  failed: number;
  durationMs: number;
  /**
   * Distinct `computedAtMs` among successful answers. 1 for a series of N means
   * one shared result (coalesced or cached in Core); N means no sharing.
   */
  distinctResults: number;
  errorsByCode: Record<string, number>;
  sample: ProjectMetadata | null;
  lastError: unknown;
}

/**
 * Sends `size` getMetadata calls in the same tick so they overlap in Core.
 * No deduplication here: each call goes through the SDK to the transport.
 */
export async function runSeries(
  runtime: RuntimeClient,
  projectId: string,
  size: number,
  clock: () => number = () => performance.now(),
): Promise<SeriesResult> {
  const started = clock();
  const results = await Promise.allSettled(
    Array.from({ length: size }, () => runtime.projects.getMetadata({ projectId })),
  );
  const durationMs = clock() - started;

  const values: ProjectMetadata[] = [];
  const errorsByCode: Record<string, number> = {};
  let lastError: unknown = null;
  for (const result of results) {
    if (result.status === "fulfilled") {
      values.push(result.value);
    } else {
      const code = result.reason instanceof RuntimeError ? result.reason.code : "UNKNOWN_ERROR";
      errorsByCode[code] = (errorsByCode[code] ?? 0) + 1;
      lastError = result.reason;
    }
  }

  return {
    finishedAt: new Date(),
    mode: runtime.mode,
    projectId,
    sent: size,
    succeeded: values.length,
    failed: size - values.length,
    durationMs,
    distinctResults: new Set(values.map((v) => v.computedAtMs)).size,
    errorsByCode,
    sample: values[0] ?? null,
    lastError,
  };
}
