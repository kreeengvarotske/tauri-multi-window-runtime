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
