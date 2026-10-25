import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { type BridgePort, createBridge } from "./bridge";

// Events are not buffered: one emitted before a listener exists is lost.
function fakeBus() {
  const listeners = new Map<string, Set<(payload: unknown) => void>>();
  const sent: { to: string; event: string; payload: unknown }[] = [];
  let peerOpen = true;
  const deliver = (to: string, event: string, payload: unknown) => {
    sent.push({ to, event, payload });
    for (const handler of [...(listeners.get(`${to}/${event}`) ?? [])]) handler(payload);
  };
  const port = (self: "main" | "secondary", registrationDelayMs = 0): BridgePort => ({
    peerIsOpen: async () => peerOpen,
    sendToPeer: async (event, payload) => deliver("secondary", event, payload),
    sendToMain: async (event, payload) => deliver("main", event, payload),
    async listen(event, handler) {
      if (registrationDelayMs > 0) await new Promise((resolve) => setTimeout(resolve, registrationDelayMs));
      const key = `${self}/${event}`;
      if (!listeners.has(key)) listeners.set(key, new Set());
      listeners.get(key)!.add(handler);
      return () => listeners.get(key)?.delete(handler);
    },
  });
  return { port, sent, deliver, listeners, closePeer: () => (peerOpen = false) };
}

beforeEach(() => vi.useFakeTimers());
afterEach(() => vi.useRealTimers());

describe("bridge handshake", () => {
  it("does not lose a request sent while the secondary page is still loading", async () => {
    const bus = fakeBus();
    const main = createBridge<number, number>(bus.port("main"));
    const handler = vi.fn(async (n: number) => n * 2);
    void createBridge<number, number>(bus.port("secondary", 300)).serve(handler);
    const accepted = main.request(21);
    await vi.advanceTimersByTimeAsync(1_000);
    const { completed } = await accepted;
    await expect(completed).resolves.toEqual({ ok: true, result: 42 });
    expect(handler).toHaveBeenCalledTimes(1);
  });

  it("runs a request once however often it is delivered, and stops re-sending after the ack", async () => {
    const bus = fakeBus();
    const main = createBridge<number, number>(bus.port("main"), { retryIntervalMs: 20 });
    const handler = vi.fn(async (n: number) => n);
    await createBridge<number, number>(bus.port("secondary")).serve(handler);
    const accepted = main.request(1);
    await vi.advanceTimersByTimeAsync(500);
    await accepted;
    const sends = bus.sent.filter((e) => e.event === "bench://request").length;
    for (const e of bus.sent.filter((e) => e.to === "secondary")) bus.deliver(e.to, e.event, e.payload);
    await vi.advanceTimersByTimeAsync(500);
    expect(handler).toHaveBeenCalledTimes(1);
    expect(sends).toBe(1);
  });

  it("fails when the secondary never confirms, and a late page does not start the request", async () => {
    const bus = fakeBus();
    const main = createBridge<number, number>(bus.port("main"), { confirmTimeoutMs: 1_000 });
    const outcome = main.request(1).then(() => "resolved", (error: Error) => error.message);
    await vi.advanceTimersByTimeAsync(1_500);
    expect(await outcome).toMatch(/did not confirm/);
    const handler = vi.fn(async (n: number) => n);
    await createBridge<number, number>(bus.port("secondary")).serve(handler);
    await vi.advanceTimersByTimeAsync(1_000);
    expect(handler).not.toHaveBeenCalled();
  });

  it("settles a running request when the secondary closes before it reports", async () => {
    const bus = fakeBus();
    const main = createBridge<number, number>(bus.port("main"), { closedCheckIntervalMs: 100 });
    await createBridge<number, number>(bus.port("secondary")).serve(() => new Promise<number>(() => {}));
    const accepted = main.request(1);
    await vi.advanceTimersByTimeAsync(10);
    const { completed } = await accepted;
    bus.closePeer();
    await vi.advanceTimersByTimeAsync(200);
    await expect(completed).resolves.toMatchObject({ ok: false, error: expect.stringMatching(/closed/) });
  });

  it("reports a failed request and ignores reports for other ids", async () => {
    const bus = fakeBus();
    const main = createBridge<number, number>(bus.port("main"));
    await createBridge<number, number>(bus.port("secondary")).serve(async () => {
      throw new Error("broke");
    });
    const accepted = main.request(1);
    bus.deliver("main", "bench://done", { requestId: "other", ok: true, result: 7 });
    await vi.advanceTimersByTimeAsync(10);
    const { completed } = await accepted;
    await expect(completed).resolves.toEqual({ ok: false, error: "broke" });
  });

  it("rejects at once when the secondary is not open", async () => {
    const bus = fakeBus();
    bus.closePeer();
    await expect(createBridge<number, number>(bus.port("main")).request(1)).rejects.toThrow(/not open/);
    expect(bus.sent).toHaveLength(0);
  });
});
