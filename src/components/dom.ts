// Minimal DOM helper. Text is always set via textContent, never innerHTML,
// so data coming from Core or the user cannot inject markup.

import { RuntimeError } from "../lib/runtime";

type Child = Node | string | null | undefined | false;

export function h<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  props: { class?: string; text?: string; attrs?: Record<string, string> } = {},
  ...children: Child[]
): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  if (props.class) el.className = props.class;
  if (props.text !== undefined) el.textContent = props.text;
  if (props.attrs) {
    for (const [name, value] of Object.entries(props.attrs)) el.setAttribute(name, value);
  }
  for (const child of children) {
    if (child) el.append(child);
  }
  return el;
}

export function panel(title: string, ...children: Child[]): HTMLElement {
  return h("section", { class: "panel" }, h("h2", { class: "panel-title", text: title }), ...children);
}

export function formatMs(ms: number): string {
  return ms < 1000 ? `${Math.round(ms)} мс` : `${(ms / 1000).toFixed(2)} с`;
}

export function errorMessage(error: unknown): string {
  if (error instanceof RuntimeError) return `${error.code}: ${error.message}`;
  return error instanceof Error ? error.message : String(error);
}
