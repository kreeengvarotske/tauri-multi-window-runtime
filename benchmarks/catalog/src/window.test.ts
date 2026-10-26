import { describe, expect, it } from "vitest";
import { type CatalogSource, type Page, type Workload, checksum } from "./catalog";
import { type CatalogConfig, type Plan, type WindowDeps, buildReport, runWindow, runWorkload, sampleHeap, setupSource } from "./window";

const page: Page = { total: 0, rows: [] };

function clock(start = 1_000_000) {
  let t = start;
  return {
    get t() {
      return t;
    },
    advance: (ms: number) => (t += ms),
    deps: (overrides: Partial<WindowDeps> = {}): WindowDeps => ({
      invoke: async () => {
        throw new Error("unexpected invoke");
      },
      label: "main",
      now: () => t,
      unixNow: () => t,
      sleep: async (ms) => void (t += ms),
      jsHeapBytes: () => 1000,
      ...overrides,
    }),
  };
}

function config(arm: "A" | "B" = "B"): CatalogConfig {
  return {
    scenario: "M", arm, armName: arm, dataMib: 0, seed: 1, windows: 2, stepIntervalMs: 500,
    idleBeforeSeconds: 1, warmupSeconds: 1, loadSeconds: 2, idleAfterSeconds: 1, records: 0, rustDataBytes: 0, automated: true,
  };
}

const workload: Workload = {
  windowIndex: 0,
  steps: [{ kind: "page", sort: "name", category: null, offset: 0, limit: 100 }, { kind: "aggregate" }],
  expected: [checksum({ kind: "page", page }), checksum({ kind: "aggregate", totals: [] })],
};

function plan(start: number): Plan {
  return { idleBeforeAtMs: start, warmupAtMs: start + 1000, loadAtMs: start + 2000, loadEndMs: start + 4000, idleAfterEndMs: start + 5000 };
}

function source(c: ReturnType<typeof clock>, latencyMs = 10, fail = -1): CatalogSource & { calls: number } {
  const s = {
    calls: 0,
    async page() {
      s.calls += 1;
      c.advance(latencyMs);
      if (s.calls === fail) throw new Error("boom");
      return page;
    },
    async aggregate() {
      s.calls += 1;
      c.advance(latencyMs);
      return [];
    },
    async get() {
      return [];
    },
  };
  return s;
}

describe("runWorkload", () => {
  it("runs warm-up and load steps at a fixed cadence and checks every response", async () => {
    const c = clock();
    const p = plan(c.t);
    const result = await runWorkload(source(c), workload, p, 500, c.deps());
    expect(result.warmup).toHaveLength(2);
    expect(result.load).toHaveLength(4);
    expect(result.load.every((s) => s.ok && !s.mismatch && s.latencyMs === 10)).toBe(true);
    expect(result.overruns).toBe(0);
    const report = buildReport(config(), "main", 0, { timeToFirstPageMs: 1, loadMs: null, indexMs: null, records: null }, p, result, []);
    expect(report.load).toMatchObject({ scheduledSteps: 4, completedSteps: 4, failures: 0, mismatches: 0 });
    expect(report.passed).toBe(true);
  });

  it("counts overruns, failures and wrong checksums, and fails the window", async () => {
    const c = clock();
    const p = plan(c.t);
    const slow = await runWorkload(source(c, 700), workload, p, 500, c.deps());
    expect(slow.overruns).toBeGreaterThan(0);

    const c2 = clock();
    const failing = await runWorkload(source(c2, 10, 3), workload, plan(c2.t), 500, c2.deps());
    expect(failing.firstError).toBe("boom");
    const report = buildReport(config(), "w1", 1, { timeToFirstPageMs: 1, loadMs: null, indexMs: null, records: null }, plan(1_000_000), failing, []);
    expect(report.load.failures).toBe(1);
    expect(report.passed).toBe(false);

    const c3 = clock();
    const wrong = { ...workload, expected: ["00000000", workload.expected[1]] };
    const mismatched = await runWorkload(source(c3), wrong, plan(c3.t), 500, c3.deps());
    expect(mismatched.load.filter((s) => s.mismatch)).toHaveLength(2);
  });
});

describe("sampleHeap", () => {
  it("samples once a second until the end and skips unsupported readings", async () => {
    const c = clock();
    expect(await sampleHeap(c.deps(), c.t + 3000)).toHaveLength(3);
    const c2 = clock();
    expect(await sampleHeap(c2.deps({ jsHeapBytes: () => null }), c2.t + 3000)).toEqual([]);
  });

  it("averages only the load-phase samples", () => {
    const p = plan(0);
    const samples = [
      { atMs: 1500, usedBytes: 1 },
      { atMs: 2000, usedBytes: 10 },
      { atMs: 3999, usedBytes: 20 },
      { atMs: 4000, usedBytes: 1000 },
    ];
    const report = buildReport(config(), "main", 0, { timeToFirstPageMs: 1, loadMs: null, indexMs: null, records: null }, p, { warmup: [], load: [], overruns: 0, firstError: null }, samples);
    expect(report.heap.loadAvgBytes).toBe(15);
  });
});

describe("setupSource", () => {
  it("arm A loads and indexes its own copy; arm B reads its first page over IPC", async () => {
    const c = clock();
    const records = [{ id: 0, name: "ka", category: 0, priceCents: 1, createdAt: 1, updatedAt: 1, note: "n" }];
    const commands: string[] = [];
    const invoke = async <T>(command: string) => {
      commands.push(command);
      c.advance(5);
      return (command === "catalog_load" ? records : page) as T;
    };
    const a = await setupSource(config("A"), c.deps({ invoke }), c.t);
    expect(a.setup).toMatchObject({ loadMs: 5, records: 1 });
    expect(await a.source.get([0])).toEqual(records);
    const b = await setupSource(config("B"), c.deps({ invoke }), c.t);
    expect(b.setup).toMatchObject({ loadMs: null, records: null, timeToFirstPageMs: 5 });
    expect(commands).toEqual(["catalog_load", "catalog_page"]);
  });
});

describe("runWindow", () => {
  it("reports ready, waits for the plan and reports the whole run", async () => {
    const c = clock();
    const p = plan(c.t + 1000);
    let polls = 0;
    const invoke = async <T>(command: string): Promise<T> => {
      switch (command) {
        case "catalog_page":
          c.advance(2);
          return page as T;
        case "catalog_aggregate":
          return [] as T;
        case "catalog_ready":
          return ["main"] as T;
        case "catalog_plan":
          polls += 1;
          return (polls < 3 ? null : p) as T;
        case "catalog_workload":
          return workload as T;
        default:
          throw new Error(command);
      }
    };
    const report = await runWindow(config("B"), c.deps({ invoke }), c.t);
    expect(polls).toBe(3);
    expect(report.passed).toBe(true);
    expect(report.load.completedSteps).toBe(4);
    expect(report.heap.supported).toBe(true);
    expect(c.t).toBeGreaterThanOrEqual(p.idleAfterEndMs);
  });
});
