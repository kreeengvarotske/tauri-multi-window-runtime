import type { Response } from "./catalog";
import { BoundedTextCache } from "./textcache";

// The service returns at most 100 page rows, 32 totals or 20 records.
const MAX_ROWS = 100;

interface Cell {
  element: HTMLTableCellElement;
  text: Text;
}

interface Row {
  element: HTMLTableRowElement;
  cells: Cell[];
}

/** Keeps a bounded set of rows, cells and text nodes for every response. */
export function createRenderer(table: HTMLTableElement, cacheText = false): (response: Response) => void {
  const document = table.ownerDocument;
  const rows: Row[] = [];
  const textCache = cacheText ? new BoundedTextCache() : null;

  function cell(row: Row, index: number, value: string): void {
    let target = row.cells[index];
    if (!target) {
      const element = document.createElement("td");
      const text = document.createTextNode("");
      element.append(text);
      row.element.append(element);
      target = { element, text };
      row.cells.push(target);
    }
    target.element.hidden = false;
    const text = textCache ? textCache.intern(value) : value;
    if (target.text.data !== text) target.text.data = text;
  }

  function clear(cells: Cell[], from: number): void {
    for (let index = from; index < cells.length; index += 1) {
      const target = cells[index];
      target.element.hidden = true;
      if (target.text.data !== "") target.text.data = "";
    }
  }

  return (response) => {
    const count = response.kind === "aggregate"
      ? response.totals.length
      : response.kind === "page" ? response.page.rows.length : response.records.length;
    if (count > MAX_ROWS) throw new Error(`at most ${MAX_ROWS} rows can be rendered`);

    for (let index = 0; index < count; index += 1) {
      let row = rows[index];
      if (!row) {
        const element = document.createElement("tr");
        table.append(element);
        row = { element, cells: [] };
        rows.push(row);
      }
      row.element.hidden = false;
      if (response.kind === "aggregate") {
        const total = response.totals[index];
        cell(row, 0, String(total.category));
        cell(row, 1, String(total.count));
        cell(row, 2, (total.sumCents / 100).toFixed(2));
        clear(row.cells, 3);
      } else {
        const record = response.kind === "page" ? response.page.rows[index] : response.records[index];
        cell(row, 0, String(record.id));
        cell(row, 1, record.name);
        cell(row, 2, String(record.category));
        cell(row, 3, (record.priceCents / 100).toFixed(2));
        cell(row, 4, record.note);
      }
    }
    for (let index = count; index < rows.length; index += 1) {
      rows[index].element.hidden = true;
      clear(rows[index].cells, 0);
    }
  };
}
