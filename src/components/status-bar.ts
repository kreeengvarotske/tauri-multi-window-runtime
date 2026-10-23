import type { RuntimeMode } from "../lib/runtime/client";
import type { WindowIdentity } from "../lib/windows";
import { h } from "./dom";

export function createStatusBar(mode: RuntimeMode, identity: WindowIdentity): HTMLElement {
  const badges = h(
    "div",
    { class: "badges" },
    badge("Режим", mode.toUpperCase(), mode === "mock" ? "warn" : "ok"),
    badge("Окно", identity.label, "neutral"),
    !identity.native && badge("Среда", "браузер", "neutral"),
  );

  const header = h(
    "header",
    { class: "status-bar" },
    h(
      "div",
      { class: "titles" },
      h("h1", { text: "Tauri Multi-Window Runtime" }),
      h("p", { class: "subtitle", text: "Runtime Lab" }),
    ),
    badges,
  );

  if (mode !== "mock") return header;

  const banner = h(
    "div",
    { class: "banner banner-warn", attrs: { role: "status" } },
    h("strong", { text: "MOCK-режим. " }),
    "Данные генерирует JavaScript этого окна, Rust Core не подключён. " +
      "Результаты не являются тестом производительности или корректности Core " +
      "и не подтверждают многооконную дедупликацию.",
  );
  return h("div", {}, header, banner);
}

function badge(label: string, value: string, tone: "ok" | "warn" | "neutral"): HTMLElement {
  return h("span", { class: `badge badge-${tone}` }, h("span", { class: "badge-label", text: label }), value);
}
