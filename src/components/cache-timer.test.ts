import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createCacheTimer } from "./cache-timer";

const SAMPLE = { projectId: "demo", name: "Demo", revision: 1, computedAtMs: 10_000 };

describe("cache timer", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("stays hidden until both the policy and a result are known", () => {
    const timer = createCacheTimer({ now: () => 10_000 });
    timer.track(SAMPLE);
    expect(timer.element.hidden).toBe(true);
    timer.setPolicy({ kind: "ttl", ttlMs: 30_000 });
    expect(timer.element.hidden).toBe(false);
  });

  it("counts the TTL down and reports expiry", () => {
    let now = 10_000;
    const timer = createCacheTimer({ now: () => now });
    timer.setPolicy({ kind: "ttl", ttlMs: 30_000 });
    timer.track(SAMPLE);
    expect(timer.element.textContent).toBe("Кэш «demo» истечёт через 30 с.");

    now = 21_500;
    vi.advanceTimersByTime(1000);
    expect(timer.element.textContent).toBe("Кэш «demo» истечёт через 19 с.");

    now = 40_000;
    vi.advanceTimersByTime(1000);
    expect(timer.element.textContent).toContain("истёк");
    expect(vi.getTimerCount()).toBe(0);
  });

  it("reacts to invalidation of its project or of the whole cache only", () => {
    const timer = createCacheTimer({ now: () => 10_000 });
    timer.setPolicy({ kind: "ttl", ttlMs: 30_000 });
    timer.track(SAMPLE);
    timer.invalidated("other");
    expect(timer.element.textContent).toContain("истечёт");
    timer.invalidated(null);
    expect(timer.element.textContent).toContain("сброшен");
    expect(vi.getTimerCount()).toBe(0);

    timer.track(SAMPLE);
    expect(timer.element.textContent).toContain("истечёт");
  });

  it.each([
    [{ kind: "forever" } as const, "до сброса"],
    [{ kind: "noStore" } as const, "не кэшируются"],
  ])("describes %j without a countdown", (policy, text) => {
    const timer = createCacheTimer({ now: () => 10_000 });
    timer.setPolicy(policy);
    timer.track(SAMPLE);
    expect(timer.element.textContent).toContain(text);
    expect(vi.getTimerCount()).toBe(0);
  });
});
