// Window identity and the secondary window. Uses the official WebviewWindow API;
// in a regular browser it falls back to a tab that is clearly marked as such.

import { isTauri } from "@tauri-apps/api/core";
import { WebviewWindow, getCurrentWebviewWindow } from "@tauri-apps/api/webviewWindow";
import { WINDOW_LABELS } from "./runtime/contract";

const SECONDARY_LABEL = WINDOW_LABELS.secondary;

export interface WindowIdentity {
  label: string;
  /** true when running inside a real Tauri WebView. */
  native: boolean;
}

export function getWindowIdentity(): WindowIdentity {
  if (isTauri()) {
    return { label: getCurrentWebviewWindow().label, native: true };
  }
  const label = new URLSearchParams(window.location.search).get("window") ?? WINDOW_LABELS.main;
  return { label, native: false };
}

export type OpenResult = "created" | "focused" | "browser-tab";

let pending: Promise<OpenResult> | null = null;

/**
 * Opens the secondary window or focuses it if it already exists.
 * Concurrent clicks share one in-flight attempt, so the label is never raced.
 */
export function openSecondaryWindow(): Promise<OpenResult> {
  pending ??= open().finally(() => {
    pending = null;
  });
  return pending;
}

async function open(): Promise<OpenResult> {
  if (!isTauri()) {
    const url = new URL(window.location.href);
    url.searchParams.set("window", SECONDARY_LABEL);
    window.open(url.toString(), `runtime-lab-${SECONDARY_LABEL}`);
    return "browser-tab";
  }

  const existing = await WebviewWindow.getByLabel(SECONDARY_LABEL);
  if (existing) {
    await existing.unminimize();
    await existing.show();
    await existing.setFocus();
    return "focused";
  }

  const created = new WebviewWindow(SECONDARY_LABEL, {
    url: "index.html",
    title: "Runtime Lab — secondary",
    width: 900,
    height: 650,
    minWidth: 480,
    minHeight: 400,
  });

  return new Promise<OpenResult>((resolve, reject) => {
    void created.once("tauri://created", () => resolve("created"));
    void created.once<string>("tauri://error", (event) =>
      reject(new Error(`Не удалось создать окно «${SECONDARY_LABEL}»: ${String(event.payload)}`)),
    );
  });
}
