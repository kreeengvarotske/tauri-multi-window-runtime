import { describe, expect, it } from "vitest";
import fixture from "./fixtures/catalog-small.json";
import { type CatalogRecord, LocalCatalog, type Workload, checksum, fnv1a32, ipcSource, runStep } from "./catalog";

const records = fixture.records as CatalogRecord[];
const workloads = fixture.workloads as Workload[];

describe("checksums", () => {
  it("match the Rust FNV-1a values", () => {
    expect(fnv1a32("")).toBe(0x811c9dc5);
    expect(fnv1a32("a")).toBe(0xe40c292c);
  });

  it("use the same canonical text as Rust", () => {
    const row = { id: 1, name: "kalo", category: 2, priceCents: 300, createdAt: 4, updatedAt: 5, note: "steel bolt" };
    const hex = (text: string) => fnv1a32(text).toString(16).padStart(8, "0");
    expect(checksum({ kind: "page", page: { total: 9, rows: [row] } })).toBe(hex("total=9\n1|kalo|2|300|4|5|steel bolt\n"));
    expect(checksum({ kind: "get", records: [row] })).toBe(hex("1|kalo|2|300|4|5|steel bolt\n"));
    expect(checksum({ kind: "aggregate", totals: [{ category: 0, count: 2, sumCents: 10 }] })).toBe(hex("0|2|10\n"));
  });
});

describe("arm A local catalog", () => {
  it("answers every step of every window with the Rust reference checksum", async () => {
    const local = new LocalCatalog(records);
    expect(local.size).toBe(records.length);
    expect(workloads).toHaveLength(4);
    for (const workload of workloads) {
      expect(workload.steps).toHaveLength(15);
      for (const [index, step] of workload.steps.entries()) {
        const response = await runStep(local, step);
        expect(checksum(response), `window ${workload.windowIndex} step ${index}`).toBe(workload.expected[index]);
      }
    }
  });

  it("refuses a name-sorted category page, like the service", async () => {
    const local = new LocalCatalog(records);
    await expect(local.page({ sort: "name", category: 1, offset: 0, limit: 10 })).rejects.toThrow();
  });

  it("returns empty pages past the end and skips unknown ids", async () => {
    const local = new LocalCatalog(records);
    const page = await local.page({ sort: "price", category: null, offset: 1_000_000, limit: 100 });
    expect(page).toEqual({ total: records.length, rows: [] });
    expect(await local.get([0, 1_000_000])).toEqual([records[0]]);
  });
});

describe("arm B source", () => {
  it("calls the bounded view commands", async () => {
    const calls: [string, unknown][] = [];
    const invoke = async <T>(command: string, args?: Record<string, unknown>) => {
      calls.push([command, args]);
      return (command === "catalog_page" ? { total: 0, rows: [] } : []) as T;
    };
    const source = ipcSource(invoke);
    await source.page({ sort: "name", category: null, offset: 0, limit: 100 });
    await source.aggregate();
    await source.get([1, 2]);
    expect(calls).toEqual([
      ["catalog_page", { query: { sort: "name", category: null, offset: 0, limit: 100 } }],
      ["catalog_aggregate", undefined],
      ["catalog_get", { ids: [1, 2] }],
    ]);
  });
});
