import { describe, expect, it } from "vitest";
import { BoundedTextCache } from "./textcache";

describe("bounded display text cache", () => {
  it("preserves text and counts unique UTF-16 payload, including surrogate pairs and empty text", () => {
    const cache = new BoundedTextCache({ maxEntries: 10, maxPayloadBytes: 100 });
    for (const value of ["", "abc", "\u00fc", "\ud83d\ude00", "<script> & \n"]) expect(cache.intern(value)).toBe(value);
    expect(cache.size).toBe(5);
    const bytes = (3 + 1 + 2 + "<script> & \n".length) * 2;
    expect(cache.payloadBytes).toBe(bytes);
    expect(cache.intern(["a", "b", "c"].join(""))).toBe("abc");
    expect(cache.intern("")).toBe("");
    expect(cache.size).toBe(5);
    expect(cache.payloadBytes).toBe(bytes);
  });

  it("evicts the least recently used entry at the entry limit and refreshes hits", () => {
    const cache = new BoundedTextCache({ maxEntries: 2, maxPayloadBytes: 100 });
    cache.intern("a");
    cache.intern("bb");
    cache.intern("a"); // bb is now oldest.
    cache.intern("ccc");
    expect(cache.size).toBe(2);
    expect(cache.payloadBytes).toBe(8); // a + ccc, proving bb was evicted.
    cache.intern("bb");
    expect(cache.size).toBe(2);
    expect(cache.payloadBytes).toBe(10); // ccc + bb: a was evicted next.
  });

  it("evicts multiple entries to fit the payload budget and accepts the exact boundary", () => {
    const cache = new BoundedTextCache({ maxEntries: 10, maxPayloadBytes: 12 });
    cache.intern("a");
    cache.intern("bb");
    cache.intern("ccc");
    expect(cache.payloadBytes).toBe(12);
    cache.intern("ddddd");
    expect(cache.size).toBe(1);
    expect(cache.payloadBytes).toBe(10);
    cache.intern("z");
    expect(cache.size).toBe(2);
    expect(cache.payloadBytes).toBe(12);
    cache.intern("\ud83d\ude00");
    expect(cache.size).toBe(2);
    expect(cache.payloadBytes).toBe(6); // z + the two-code-unit emoji.
  });

  it("never retains oversized text or evicts useful text to make room for it", () => {
    const cache = new BoundedTextCache({ maxEntries: 2, maxPayloadBytes: 6 });
    cache.intern("a");
    cache.intern("bb");
    for (let index = 0; index < 10; index += 1) expect(cache.intern("oversized")).toBe("oversized");
    expect(cache.size).toBe(2);
    expect(cache.payloadBytes).toBe(6);
    cache.intern("ccc");
    expect(cache.size).toBe(1);
    expect(cache.payloadBytes).toBe(6);
  });

  it("defaults to at most 8192 entries and a one MiB UTF-16 payload estimate", () => {
    const cache = new BoundedTextCache();
    for (let index = 0; index < 9000; index += 1) cache.intern(String(index));
    expect(cache.size).toBe(8192);
    expect(cache.payloadBytes).toBeLessThanOrEqual(1024 * 1024);
    cache.intern("x".repeat(512 * 1024));
    expect(cache.size).toBe(1);
    expect(cache.payloadBytes).toBe(1024 * 1024);
    cache.intern("y".repeat(512 * 1024 + 1));
    expect(cache.size).toBe(1);
    expect(cache.payloadBytes).toBe(1024 * 1024);
  });

  it("can disable retention with a zero limit and refuses invalid limits", () => {
    for (const limits of [{ maxEntries: 0 }, { maxPayloadBytes: 0 }]) {
      const cache = new BoundedTextCache(limits);
      expect(cache.intern("value")).toBe("value");
      expect(cache.intern("")).toBe("");
      expect(cache.size).toBe(0);
      expect(cache.payloadBytes).toBe(0);
    }
    for (const limit of [-1, 0.5, Number.NaN, Number.POSITIVE_INFINITY, Number.MAX_SAFE_INTEGER + 1]) {
      expect(() => new BoundedTextCache({ maxEntries: limit })).toThrow(RangeError);
      expect(() => new BoundedTextCache({ maxPayloadBytes: limit })).toThrow(RangeError);
    }
  });
});
