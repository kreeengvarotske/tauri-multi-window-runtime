import { describe, expect, it } from "vitest";
import { type CatalogRecord, type Response } from "./catalog";
import { createRenderer } from "./renderer";

// The node test environment needs only these DOM operations. Keeping every
// created node also lets the memory regression test count allocations and
// check identity, including nodes that would otherwise have been detached.
class TestText {
  constructor(public data: string) {}
}

class TestElement {
  readonly children: (TestElement | TestText)[] = [];
  hidden = false;

  constructor(readonly tagName: string, readonly ownerDocument: TestDocument) {}

  append(child: TestElement | TestText): void {
    this.children.push(child);
  }
}

class TestDocument {
  readonly elements: TestElement[] = [];
  readonly texts: TestText[] = [];

  createElement(tagName: string): TestElement {
    const element = new TestElement(tagName, this);
    this.elements.push(element);
    return element;
  }

  createTextNode(data: string): TestText {
    const text = new TestText(data);
    this.texts.push(text);
    return text;
  }
}

function harness() {
  const document = new TestDocument();
  const table = document.createElement("table");
  return { document, table, render: createRenderer(table as unknown as HTMLTableElement) };
}

function elements(parent: TestElement): TestElement[] {
  return parent.children.filter((child): child is TestElement => child instanceof TestElement);
}

function visible(table: TestElement): string[][] {
  return elements(table).filter((row) => !row.hidden).map((row) =>
    elements(row).filter((cell) => !cell.hidden).map((cell) => (cell.children[0] as TestText).data),
  );
}

function record(id: number): CatalogRecord {
  return { id, name: `name ${id}`, category: id % 32, priceCents: 1234 + id, createdAt: 1, updatedAt: 2, note: `note ${id}` };
}

function page(records: CatalogRecord[]): Response {
  return { kind: "page", page: { total: records.length, rows: records } };
}

describe("catalog renderer", () => {
  it("allocates no rows or cells for an initially empty response", () => {
    const { document, table, render } = harness();
    render(page([]));
    render({ kind: "get", records: [] });
    render({ kind: "aggregate", totals: [] });
    expect(table.children).toHaveLength(0);
    expect(document.elements).toHaveLength(1);
    expect(document.texts).toHaveLength(0);
  });

  it("preserves the displayed fields, decimal formatting and literal text", () => {
    const { table, render } = harness();
    render(page([{ ...record(7), name: "<b>name</b>", note: "note & <script>text</script>" }]));
    expect(visible(table)).toEqual([["7", "<b>name</b>", "7", "12.41", "note & <script>text</script>"]]);
    render({ kind: "aggregate", totals: [{ category: 7, count: 20, sumCents: 100005 }] });
    expect(visible(table)).toEqual([["7", "20", "1000.05"]]);
    render({ kind: "get", records: [{ ...record(3), priceCents: 5 }] });
    expect(visible(table)).toEqual([["3", "name 3", "3", "0.05", "note 3"]]);
  });

  it("reuses rows, cells and text nodes across page, aggregate, get and empty responses", () => {
    const { document, table, render } = harness();
    const records = Array.from({ length: 100 }, (_, index) => record(index));
    const totals = Array.from({ length: 32 }, (_, category) => ({ category, count: category + 1, sumCents: category * 100 }));
    render(page(records));
    const originalElements = [...document.elements];
    const originalTexts = [...document.texts];

    render({ kind: "aggregate", totals });
    expect(visible(table)).toHaveLength(32);
    expect(visible(table).every((cells) => cells.length === 3)).toBe(true);
    expect(visible(table)[31]).toEqual(["31", "32", "31.00"]);
    // Hidden cells and rows must release their previous field strings.
    for (const row of elements(table)) {
      for (const cell of elements(row)) {
        if (row.hidden || cell.hidden) expect((cell.children[0] as TestText).data).toBe("");
      }
    }

    render({ kind: "get", records: records.slice(40, 60) });
    expect(visible(table)).toHaveLength(20);
    expect(visible(table).every((cells) => cells.length === 5)).toBe(true);
    expect(visible(table)[0]).toEqual(["40", "name 40", "8", "12.74", "note 40"]);
    render(page([]));
    expect(visible(table)).toEqual([]);
    expect(document.texts.every((text) => text.data === "")).toBe(true);

    const responses: Response[] = [page(records), { kind: "aggregate", totals }, { kind: "get", records: records.slice(0, 20) }, page([])];
    for (let index = 0; index < 1000; index += 1) render(responses[index % responses.length]);
    render(page([{ ...record(0), name: "updated", note: "new note" }, ...records.slice(1)]));
    expect(visible(table)).toHaveLength(100);
    expect(visible(table)[0]).toEqual(["0", "updated", "0", "12.34", "new note"]);
    expect(document.elements).toHaveLength(601); // table + 100 rows + 500 cells
    expect(document.texts).toHaveLength(500);
    expect(document.elements.every((element, index) => element === originalElements[index])).toBe(true);
    expect(document.texts.every((text, index) => text === originalTexts[index])).toBe(true);
  });

  it("grows the pool only as needed when aggregates arrive before a full page", () => {
    const { document, table, render } = harness();
    render({ kind: "aggregate", totals: [{ category: 1, count: 2, sumCents: 300 }] });
    expect(document.elements).toHaveLength(5); // table, row, three cells
    expect(document.texts).toHaveLength(3);
    const initialRow = table.children[0];
    const initialTexts = [...document.texts];
    render(page([record(0), record(1)]));
    expect(visible(table)).toHaveLength(2);
    expect(document.elements).toHaveLength(13); // table, two rows, ten cells
    expect(document.texts).toHaveLength(10);
    expect(table.children[0]).toBe(initialRow);
    expect(document.texts.slice(0, 3)).toEqual(initialTexts);
  });

  it("rejects a response above the display limit before allocating its nodes", () => {
    const { document, table, render } = harness();
    expect(() => render(page(Array.from({ length: 101 }, (_, index) => record(index))))).toThrow("at most 100 rows");
    expect(table.children).toHaveLength(0);
    expect(document.elements).toHaveLength(1);
    expect(document.texts).toHaveLength(0);
  });
});
