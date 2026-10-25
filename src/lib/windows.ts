// Window identity and the secondary window. Uses the official WebviewWindow API;
// in a regular browser it falls back to a tab that is clearly marked as such.

import { isTauri } from "@tauri-apps/api/core";
import { emitTo } from "@tauri-apps/api/event";
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

/** A series that the main window asks the secondary window to run at the same time. */
export interface SeriesRequest {
  projectId: string;
  size: number;
}

/** How a series that the secondary window accepted has ended. */
export interface SeriesCompletion {
  /** false when the series failed to run or the window closed before it reported. */
  ok: boolean;
  /** Why the series did not finish normally. */
  error?: string;
}

/** A series that the secondary window has confirmed it started. */
export interface SecondarySeries {
  readonly requestId: string;
  /**
   * Settles once the secondary reports that this series has finished, or once
   * the window is found closed. It never rejects, and a report about another
   * request id does not settle it.
   */
  readonly completed: Promise<SeriesCompletion>;
}

/** Window-to-window channel for running one series in both windows. */
export interface WindowBridge {
  /**
   * Asks the secondary window to start a series and resolves once it has
   * confirmed that it accepted the request. Rejects if it is not open, closes
   * meanwhile, or does not confirm in time.
   */
  requestSeriesInSecondary(request: SeriesRequest): Promise<SecondarySeries>;
  /**
   * Runs `handler` once per request when the main window asks this window to
   * start a series. When the handler returns a promise, main is told the series
   * has finished after it settles.
   */
  onSeriesRequest(handler: (request: SeriesRequest) => void | Promise<unknown>): Promise<() => void>;
}

export interface WindowBridgeOptions {
  /** How long main waits for the secondary to confirm a request. */
  confirmTimeoutMs?: number;
  /** How often main re-sends a request that has not been confirmed yet. */
  retryIntervalMs?: number;
  /** How often main checks that the secondary is still open while a series runs there. */
  closedCheckIntervalMs?: number;
}

// Frontend-only events between our own windows; Core is not involved.
// Events are not buffered: one sent before the other window has registered its
// listener is lost, and `tauri://created` fires before that window's page has
// loaded. So main re-sends a request until the secondary confirms it, and each
// request carries an id: the secondary starts a series once per id, and main
// accepts only the confirmation of the request it is waiting for. When the
// series ends, the secondary reports it under the same id.
const SERIES_EVENT = "lab://run-series";
const SERIES_ACK_EVENT = "lab://run-series-ack";
const SERIES_DONE_EVENT = "lab://run-series-done";
const BROWSER_CHANNEL = "runtime-lab";
const DEFAULT_CONFIRM_TIMEOUT_MS = 5_000;
const DEFAULT_RETRY_INTERVAL_MS = 100;
const DEFAULT_CLOSED_CHECK_INTERVAL_MS = 500;
const REMEMBERED_REQUESTS = 64;

interface SeriesMessage {
  requestId: string;
  request: SeriesRequest;
}

interface SeriesAck {
  requestId: string;
}

interface SeriesDone extends SeriesCompletion {
  requestId: string;
}

/** The minimum each environment provides for the handshake. */
interface BridgePort {
  peerIsOpen(): Promise<boolean>;
  sendToPeer(event: string, payload: unknown): Promise<void>;
  sendToMain(event: string, payload: unknown): Promise<void>;
  listen(event: string, handler: (payload: unknown) => void): Promise<() => void>;
}

export function createWindowBridge(options: WindowBridgeOptions = {}): WindowBridge {
  return createHandshakeBridge(isTauri() ? tauriPort() : browserPort(), options);
}

function tauriPort(): BridgePort {
  const current = getCurrentWebviewWindow();
  return {
    async peerIsOpen() {
      return (await WebviewWindow.getByLabel(SECONDARY_LABEL)) !== null;
    },
    sendToPeer: (event, payload) => emitTo(SECONDARY_LABEL, event, payload),
    sendToMain: (event, payload) => emitTo(WINDOW_LABELS.main, event, payload),
    listen: (event, handler) => current.listen(event, (e) => handler(e.payload)),
  };
}

function browserPort(): BridgePort {
  // Browser fallback: tabs of the same origin talk over BroadcastChannel.
  const channel = new BroadcastChannel(BROWSER_CHANNEL);
  const post = async (type: string, payload: unknown) => channel.postMessage({ type, payload });
  return {
    peerIsOpen: async () => true,
    sendToPeer: post,
    sendToMain: post,
    async listen(type, handler) {
      const listener = (event: MessageEvent) => {
        if (event.data?.type === type) handler(event.data.payload);
      };
      channel.addEventListener("message", listener);
      return () => channel.removeEventListener("message", listener);
    },
  };
}

function createHandshakeBridge(port: BridgePort, options: WindowBridgeOptions): WindowBridge {
  const confirmTimeoutMs = options.confirmTimeoutMs ?? DEFAULT_CONFIRM_TIMEOUT_MS;
  const retryIntervalMs = options.retryIntervalMs ?? DEFAULT_RETRY_INTERVAL_MS;
  const closedCheckIntervalMs = options.closedCheckIntervalMs ?? DEFAULT_CLOSED_CHECK_INTERVAL_MS;
  const notOpen = () => new Error(`Окно «${SECONDARY_LABEL}» не открыто. Сначала нажмите «Открыть второе окно».`);

  return {
    async requestSeriesInSecondary(request) {
      if (!(await port.peerIsOpen())) throw notOpen();

      const requestId = newRequestId();
      let confirm!: () => void;
      const confirmed = new Promise<void>((resolve) => (confirm = resolve));
      let isConfirmed = false;
      let finish!: (completion: SeriesCompletion) => void;
      let isFinished = false;
      const completed = new Promise<SeriesCompletion>((resolve) => (finish = resolve));

      // Listen before the first send, so a fast confirmation or completion
      // cannot be missed.
      const unlistenAck = await port.listen(SERIES_ACK_EVENT, (payload) => {
        if ((payload as SeriesAck | null)?.requestId === requestId) {
          isConfirmed = true;
          confirm();
        }
      });
      let unlistenDone: () => void = () => {};
      const settle = (completion: SeriesCompletion) => {
        if (isFinished) return;
        isFinished = true;
        unlistenDone();
        finish(completion);
      };
      try {
        unlistenDone = await port.listen(SERIES_DONE_EVENT, (payload) => {
          const done = payload as SeriesDone | null;
          if (done?.requestId !== requestId) return;
          settle(done.ok === true ? { ok: true } : { ok: false, error: String(done.error ?? "серия завершилась с ошибкой") });
        });
        const deadline = Date.now() + confirmTimeoutMs;
        const message: SeriesMessage = { requestId, request };
        while (!isConfirmed) {
          if (Date.now() >= deadline) {
            throw new Error(
              `Окно «${SECONDARY_LABEL}» не подтвердило запуск серии за ${confirmTimeoutMs} мс. ` +
                "Серия в нём не запущена; дождитесь загрузки окна и повторите.",
            );
          }
          await port.sendToPeer(SERIES_EVENT, message);
          await Promise.race([confirmed, delay(Math.min(retryIntervalMs, Math.max(0, deadline - Date.now())))]);
          if (!isConfirmed && !(await port.peerIsOpen())) throw notOpen();
        }
      } catch (error) {
        // Nothing was confirmed, so nobody waits for a completion.
        isFinished = true;
        unlistenDone();
        throw error;
      } finally {
        unlistenAck();
      }

      // A closed window never reports; its requests that already reached Core
      // still finish there, which the benchmark checks through Core counters.
      void (async () => {
        while (!isFinished) {
          await delay(closedCheckIntervalMs);
          if (!isFinished && !(await port.peerIsOpen().catch(() => false))) {
            settle({ ok: false, error: `окно «${SECONDARY_LABEL}» закрыто до завершения серии` });
          }
        }
      })();
      return { requestId, completed };
    },

    onSeriesRequest(handler) {
      const accepted: string[] = [];
      return port.listen(SERIES_EVENT, (payload) => {
        const message = payload as SeriesMessage | null;
        if (typeof message?.requestId !== "string" || !message.request) return;
        const { requestId } = message;
        if (!accepted.includes(requestId)) {
          // A handler that throws has not started the series: no confirmation,
          // so main reports the failure instead of assuming it is running.
          const started = handler(message.request);
          accepted.push(requestId);
          if (accepted.length > REMEMBERED_REQUESTS) accepted.shift();
          void Promise.resolve(started).then(
            () => ({ requestId, ok: true }),
            (error: unknown) => ({ requestId, ok: false, error: error instanceof Error ? error.message : String(error) }),
          ).then((done: SeriesDone) => port.sendToMain(SERIES_DONE_EVENT, done)).catch(() => {});
        }
        // Confirm every delivery, so main stops re-sending even if an earlier
        // confirmation was lost.
        const ack: SeriesAck = { requestId };
        void port.sendToMain(SERIES_ACK_EVENT, ack).catch(() => {});
      });
    },
  };
}

function newRequestId(): string {
  return typeof crypto?.randomUUID === "function"
    ? crypto.randomUUID()
    : `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
