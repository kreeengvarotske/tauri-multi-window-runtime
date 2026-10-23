import { describe, expect, it } from "vitest";
import { createRuntimeClient } from "../lib/runtime";
import { SAMPLE_STATS, fakeCoreTransport, instantMock } from "../test/fakes";
import { runSeries } from "./series";
import { describeCachePolicy, statsInvariantHolds } from "./stats";

describe("runSeries", () => {
  it("counts successes and distinct results", async () => {
    const result = await runSeries(createRuntimeClient(instantMock()), "demo", 10);
    expect(result).toMatchObject({ sent: 10, succeeded: 10, failed: 0, distinctResults: 10, mode: "mock" });
    expect(result.sample?.projectId).toBe("demo");
  });

  it("shows one shared result when the backend coalesces", async () => {
    const result = await runSeries(createRuntimeClient(fakeCoreTransport()), "demo", 50);
    expect(result.distinctResults).toBe(1);
  });

  it("groups failures by error code", async () => {
    const result = await runSeries(createRuntimeClient(instantMock()), "missing", 3);
    expect(result).toMatchObject({ succeeded: 0, failed: 3, errorsByCode: { PROJECT_NOT_FOUND: 3 }, sample: null });
    expect(result.lastError).toMatchObject({ code: "PROJECT_NOT_FOUND" });
  });

  it("measures duration with the given clock", async () => {
    let t = 0;
    const result = await runSeries(createRuntimeClient(instantMock()), "demo", 1, () => (t += 25));
    expect(result.durationMs).toBe(25);
  });
});

describe("stats helpers", () => {
  it("checks the contract invariant", () => {
    expect(statsInvariantHolds(SAMPLE_STATS)).toBe(true);
    expect(statsInvariantHolds({ ...SAMPLE_STATS, cacheHits: 5 })).toBe(false);
  });

  it("describes every cache policy kind", () => {
    expect(describeCachePolicy({ kind: "noStore" })).toContain("noStore");
    expect(describeCachePolicy({ kind: "forever" })).toContain("forever");
    expect(describeCachePolicy({ kind: "ttl", ttlMs: 30000 })).toBe("TTL 30000 мс");
  });
});
