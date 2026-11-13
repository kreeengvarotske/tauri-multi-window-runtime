export interface TextCacheLimits {
  maxEntries?: number;
  maxPayloadBytes?: number;
}

/**
 * Reuses canonical strings for the benchmark's displayed fields.
 * Bytes estimate UTF-16 string payload only (two bytes per code unit), not
 * engine/Map overhead, retained backing storage, DOM allocations or OS RAM.
 */
export class BoundedTextCache {
  private readonly entries = new Map<string, string>();
  private readonly maxEntries: number;
  private readonly maxPayloadBytes: number;
  private retainedPayloadBytes = 0;

  constructor({ maxEntries = 8192, maxPayloadBytes = 1024 * 1024 }: TextCacheLimits = {}) {
    if (!Number.isSafeInteger(maxEntries) || maxEntries < 0
      || !Number.isSafeInteger(maxPayloadBytes) || maxPayloadBytes < 0) {
      throw new RangeError("text cache limits must be non-negative safe integers");
    }
    this.maxEntries = maxEntries;
    this.maxPayloadBytes = maxPayloadBytes;
  }

  get size(): number {
    return this.entries.size;
  }

  get payloadBytes(): number {
    return this.retainedPayloadBytes;
  }

  intern(value: string): string {
    const bytes = value.length * 2;
    if (this.maxEntries === 0 || this.maxPayloadBytes === 0 || bytes > this.maxPayloadBytes) return value;

    const cached = this.entries.get(value);
    if (cached !== undefined) {
      // Delete and reinsert the retained value, so the incoming equal string
      // does not replace the canonical string and the entry becomes newest.
      this.entries.delete(cached);
      this.entries.set(cached, cached);
      return cached;
    }

    while (this.entries.size >= this.maxEntries || this.retainedPayloadBytes + bytes > this.maxPayloadBytes) {
      const oldest = this.entries.keys().next().value;
      if (oldest === undefined) break;
      this.entries.delete(oldest);
      this.retainedPayloadBytes -= oldest.length * 2;
    }
    this.entries.set(value, value);
    this.retainedPayloadBytes += bytes;
    return value;
  }
}
