import type { CachePolicy, RuntimeDebugStats } from "../lib/runtime";

/** Contract invariant: every accepted call either ran, joined a run or hit the cache. */
export function statsInvariantHolds(stats: RuntimeDebugStats): boolean {
  return stats.requestsReceived === stats.operationsExecuted + stats.coalescedRequests + stats.cacheHits;
}

export function describeCachePolicy(policy: CachePolicy): string {
  switch (policy.kind) {
    case "noStore":
      return "без кэша (noStore)";
    case "forever":
      return "бессрочно (forever)";
    case "ttl":
      return `TTL ${policy.ttlMs} мс`;
    default:
      // Forward compatibility: a new kind from Core is shown as is.
      return JSON.stringify(policy);
  }
}

/**
 * Milliseconds until a cached result expires, judged by its `computedAtMs`.
 * Core stores a result right after computing it, so this matches the TTL
 * boundary within a few milliseconds. `null` means the result never expires
 * by time (forever) or is not cached at all (noStore).
 */
export function cacheExpiresInMs(policy: CachePolicy, computedAtMs: number, now: number): number | null {
  if (policy.kind !== "ttl") return null;
  return Math.max(0, computedAtMs + policy.ttlMs - now);
}
