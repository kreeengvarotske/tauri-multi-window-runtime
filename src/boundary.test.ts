import { describe, expect, it } from "vitest";

// UI code must reach the backend only through src/lib/runtime/index.ts.
const uiSources = import.meta.glob(["./app.ts", "./components/*.ts", "./state/*.ts", "!./**/*.test.ts"], {
  query: "?raw",
  import: "default",
  eager: true,
}) as Record<string, string>;

describe("UI / backend boundary", () => {
  it("finds UI sources to check", () => {
    expect(Object.keys(uiSources).length).toBeGreaterThan(5);
  });

  it.each(Object.entries(uiSources))("%s does not import Tauri or transport internals", (_, source) => {
    const imports = [...source.matchAll(/from\s+["']([^"']+)["']/g)].map((m) => m[1]);
    for (const path of imports) {
      expect(path).not.toMatch(/^@tauri-apps\//);
      expect(path).not.toMatch(/lib\/runtime\/(tauri|mock|client|contract|errors|transport)/);
    }
  });
});
