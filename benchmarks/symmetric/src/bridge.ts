// Main asks the secondary window to run its half of a round. Ported from the
// Runtime Lab bridge (PR #16): Tauri events are not buffered, so main re-sends
// a request until the secondary confirms its id; the secondary runs each id
// once and reports the result under the same id.

import { emitTo } from "@tauri-apps/api/event";
import { WebviewWindow, getCurrentWebviewWindow } from "@tauri-apps/api/webviewWindow";

const SECONDARY = "secondary";
const MAIN = "main";
const REQUEST_EVENT = "bench://request";
const ACK_EVENT = "bench://ack";
const DONE_EVENT = "bench://done";
const REMEMBERED_REQUESTS = 64;

/** How a request that the secondary accepted has ended. Never rejects. */
export interface Completion<R> {
  ok: boolean;
  result?: R;
  error?: string;
}

export interface Accepted<R> {
  readonly requestId: string;
  readonly completed: Promise<Completion<R>>;
}

export interface Bridge<T, R> {
  /** Resolves once the secondary confirmed it started `request`. */
  request(request: T): Promise<Accepted<R>>;
  /** Secondary side: runs `handler` once per request id. */
  serve(handler: (request: T) => Promise<R>): Promise<() => void>;
}

export interface BridgePort {
  peerIsOpen(): Promise<boolean>;
  sendToPeer(event: string, payload: unknown): Promise<void>;
  sendToMain(event: string, payload: unknown): Promise<void>;
  listen(event: string, handler: (payload: unknown) => void): Promise<() => void>;
}

export interface BridgeOptions {
  confirmTimeoutMs?: number;
  retryIntervalMs?: number;
  closedCheckIntervalMs?: number;
}

export function tauriPort(): BridgePort {
  const current = getCurrentWebviewWindow();
  return {
    peerIsOpen: async () => (await WebviewWindow.getByLabel(SECONDARY)) !== null,
    sendToPeer: (event, payload) => emitTo(SECONDARY, event, payload),
    sendToMain: (event, payload) => emitTo(MAIN, event, payload),
    listen: (event, handler) => current.listen(event, (e) => handler(e.payload)),
  };
}

interface RequestMessage<T> {
  requestId: string;
  request: T;
}

interface DoneMessage<R> extends Completion<R> {
  requestId: string;
}

export function createBridge<T, R>(port: BridgePort, options: BridgeOptions = {}): Bridge<T, R> {
  const confirmTimeoutMs = options.confirmTimeoutMs ?? 5_000;
  const retryIntervalMs = options.retryIntervalMs ?? 100;
  const closedCheckIntervalMs = options.closedCheckIntervalMs ?? 500;
  const notOpen = () => new Error("The secondary window is not open.");

  return {
    async request(request) {
      if (!(await port.peerIsOpen())) throw notOpen();
      const requestId = newRequestId();
      let isConfirmed = false;
      let confirm!: () => void;
      const confirmed = new Promise<void>((resolve) => (confirm = resolve));
      let isFinished = false;
      let finish!: (completion: Completion<R>) => void;
      const completed = new Promise<Completion<R>>((resolve) => (finish = resolve));
      let unlistenDone: () => void = () => {};
      const settle = (completion: Completion<R>) => {
        if (isFinished) return;
        isFinished = true;
        unlistenDone();
        finish(completion);
      };

      // Listen before the first send, so a fast reply cannot be missed.
      const unlistenAck = await port.listen(ACK_EVENT, (payload) => {
        if ((payload as { requestId?: string } | null)?.requestId === requestId) {
          isConfirmed = true;
          confirm();
        }
      });
      try {
        unlistenDone = await port.listen(DONE_EVENT, (payload) => {
          const done = payload as DoneMessage<R> | null;
          if (done?.requestId !== requestId) return;
          settle(done.ok === true ? { ok: true, result: done.result } : { ok: false, error: String(done.error ?? "failed") });
        });
        const deadline = Date.now() + confirmTimeoutMs;
        const message: RequestMessage<T> = { requestId, request };
        while (!isConfirmed) {
          if (Date.now() >= deadline) {
            throw new Error(`The secondary window did not confirm the request within ${confirmTimeoutMs} ms; it was not started there.`);
          }
          await port.sendToPeer(REQUEST_EVENT, message);
          await Promise.race([confirmed, delay(Math.min(retryIntervalMs, Math.max(0, deadline - Date.now())))]);
          if (!isConfirmed && !(await port.peerIsOpen())) throw notOpen();
        }
      } catch (error) {
        isFinished = true;
        unlistenDone();
        throw error;
      } finally {
        unlistenAck();
      }

      // A closed window never reports; settle instead of waiting forever.
      void (async () => {
        while (!isFinished) {
          await delay(closedCheckIntervalMs);
          if (!isFinished && !(await port.peerIsOpen().catch(() => false))) {
            settle({ ok: false, error: "the secondary window closed before it reported" });
          }
        }
      })();
      return { requestId, completed };
    },

    serve(handler) {
      const accepted: string[] = [];
      return port.listen(REQUEST_EVENT, (payload) => {
        const message = payload as RequestMessage<T> | null;
        if (typeof message?.requestId !== "string") return;
        const { requestId } = message;
        if (!accepted.includes(requestId)) {
          accepted.push(requestId);
          if (accepted.length > REMEMBERED_REQUESTS) accepted.shift();
          void handler(message.request)
            .then(
              (result): DoneMessage<R> => ({ requestId, ok: true, result }),
              (error: unknown): DoneMessage<R> => ({ requestId, ok: false, error: error instanceof Error ? error.message : String(error) }),
            )
            .then((done) => port.sendToMain(DONE_EVENT, done))
            .catch(() => {});
        }
        // Confirm every delivery, so main stops re-sending even if an earlier
        // confirmation was lost.
        void port.sendToMain(ACK_EVENT, { requestId }).catch(() => {});
      });
    },
  };
}

function newRequestId(): string {
  return typeof crypto?.randomUUID === "function"
    ? crypto.randomUUID()
    : `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
}

export function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
