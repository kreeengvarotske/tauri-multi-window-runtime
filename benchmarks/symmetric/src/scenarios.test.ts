import { describe, expect, it } from "vitest";
import { expectedDelta, keysFor } from "./scenarios";

describe("scenarios", () => {
  it("uses one shared key in S2 and S4 and distinct keys across both windows in S3", () => {
    expect(new Set([...keysFor("S2", "main", 10), ...keysFor("S2", "secondary", 10)]).size).toBe(1);
    expect(new Set([...keysFor("S3", "main", 10), ...keysFor("S3", "secondary", 10)]).size).toBe(20);
    expect(keysFor("S1", "secondary", 1)).toEqual([]);
  });

  it("expects plain to run every request and runtime to save work only where it may", () => {
    expect(expectedDelta("plain", "S4", 3, 10)).toMatchObject({ operationsExecuted: 20, cacheHits: 0 });
    expect(expectedDelta("runtime", "S2", 1, 10)).toMatchObject({ operationsExecuted: 1, coalescedRequests: 19 });
    expect(expectedDelta("runtime", "S3", 1, 10)).toMatchObject({ operationsExecuted: 20, coalescedRequests: 0 });
    expect(expectedDelta("runtime", "S4", 1, 10)).toMatchObject({ operationsExecuted: 1, coalescedRequests: 19 });
    expect(expectedDelta("runtime", "S4", 2, 10)).toMatchObject({ operationsExecuted: 0, cacheHits: 20 });
    expect(expectedDelta("runtime", "S1", 1, 1)).toMatchObject({ requestsReceived: 1, operationsExecuted: 1, coalescedRequests: 0 });
  });
});
