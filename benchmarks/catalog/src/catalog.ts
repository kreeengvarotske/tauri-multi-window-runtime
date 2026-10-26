// Types shared with the Rust side, the canonical checksums and the arm A
// catalog (each window's own copy with its own indexes).

export const CATEGORIES = 32;

export interface CatalogRecord {
  id: number;
  name: string;
  category: number;
  priceCents: number;
  createdAt: number;
  updatedAt: number;
  note: string;
}

export type Sort = "name" | "price";

export interface PageQuery {
  sort: Sort;
  category: number | null;
  offset: number;
  limit: number;
}

export interface Page {
  total: number;
  rows: CatalogRecord[];
}

export interface CategoryTotal {
  category: number;
  count: number;
  sumCents: number;
}

export type Step =
  | ({ kind: "page" } & PageQuery)
  | { kind: "aggregate" }
  | { kind: "get"; ids: number[] };

export interface Workload {
  windowIndex: number;
  steps: Step[];
  expected: string[];
}

export type Response =
  | { kind: "page"; page: Page }
  | { kind: "aggregate"; totals: CategoryTotal[] }
  | { kind: "get"; records: CatalogRecord[] };

/** Where a window reads catalog data from; the only difference between arms. */
export interface CatalogSource {
  page(query: PageQuery): Promise<Page>;
  aggregate(): Promise<CategoryTotal[]>;
  get(ids: number[]): Promise<CatalogRecord[]>;
}

export async function runStep(source: CatalogSource, step: Step): Promise<Response> {
  switch (step.kind) {
    case "page":
      return { kind: "page", page: await source.page({ sort: step.sort, category: step.category, offset: step.offset, limit: step.limit }) };
    case "aggregate":
      return { kind: "aggregate", totals: await source.aggregate() };
    case "get":
      return { kind: "get", records: await source.get(step.ids) };
  }
}

// ------------------------------------------------------------- checksums

/** FNV-1a, 32 bit, over ASCII text; the same function as `catalog::fnv1a32`. */
export function fnv1a32(text: string): number {
  let hash = 0x811c9dc5;
  for (let i = 0; i < text.length; i += 1) {
    hash ^= text.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash >>> 0;
}

const hex = (value: number) => value.toString(16).padStart(8, "0");
const line = (r: CatalogRecord) => `${r.id}|${r.name}|${r.category}|${r.priceCents}|${r.createdAt}|${r.updatedAt}|${r.note}\n`;

export function checksum(response: Response): string {
  switch (response.kind) {
    case "page":
      return hex(fnv1a32(`total=${response.page.total}\n` + response.page.rows.map(line).join("")));
    case "aggregate":
      return hex(fnv1a32(response.totals.map((t) => `${t.category}|${t.count}|${t.sumCents}\n`).join("")));
    case "get":
      return hex(fnv1a32(response.records.map(line).join("")));
  }
}

// ------------------------------------------------- arm A: local catalog

function byteCompare(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

/**
 * Arm A: one window's own copy of the catalog with the same indexes the Rust
 * service builds, so both arms answer every step with work proportional to
 * the response.
 */
export class LocalCatalog implements CatalogSource {
  private readonly byName: Uint32Array;
  private readonly byPrice: Uint32Array;
  private readonly byCategoryPrice: Uint32Array[];
  private readonly totals: CategoryTotal[];

  constructor(private readonly records: CatalogRecord[]) {
    const all = Uint32Array.from(records.keys());
    this.byName = all.slice().sort((a, b) => byteCompare(records[a].name, records[b].name) || records[a].id - records[b].id);
    this.byPrice = all.slice().sort((a, b) => records[a].priceCents - records[b].priceCents || records[a].id - records[b].id);
    const buckets: number[][] = Array.from({ length: CATEGORIES }, () => []);
    for (const position of this.byPrice) buckets[records[position].category].push(position);
    this.byCategoryPrice = buckets.map((bucket) => Uint32Array.from(bucket));
    this.totals = Array.from({ length: CATEGORIES }, (_, category) => ({ category, count: 0, sumCents: 0 }));
    for (const record of records) {
      this.totals[record.category].count += 1;
      this.totals[record.category].sumCents += record.priceCents;
    }
  }

  get size(): number {
    return this.records.length;
  }

  async page(query: PageQuery): Promise<Page> {
    let order: Uint32Array;
    if (query.category !== null) {
      if (query.sort !== "price") throw new Error("a category filter is sorted by price only");
      order = this.byCategoryPrice[query.category];
    } else {
      order = query.sort === "name" ? this.byName : this.byPrice;
    }
    const rows = Array.from(order.subarray(query.offset, query.offset + query.limit), (p) => this.records[p]);
    return { total: order.length, rows };
  }

  async aggregate(): Promise<CategoryTotal[]> {
    return this.totals.map((t) => ({ ...t }));
  }

  async get(ids: number[]): Promise<CatalogRecord[]> {
    return ids.flatMap((id) => (id < this.records.length ? [this.records[id]] : []));
  }
}

// --------------------------------------------- arm B: shared Rust service

export type Invoke = <T>(command: string, args?: Record<string, unknown>) => Promise<T>;

export function ipcSource(invoke: Invoke): CatalogSource {
  return {
    page: (query) => invoke<Page>("catalog_page", { query }),
    aggregate: () => invoke<CategoryTotal[]>("catalog_aggregate"),
    get: (ids) => invoke<CatalogRecord[]>("catalog_get", { ids }),
  };
}
