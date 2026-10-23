import { describe, expect, it } from "vitest";
import { RUNTIME_COMMANDS } from "./contract";
import { RuntimeError, normalizeRuntimeError } from "./errors";

const cmd = RUNTIME_COMMANDS.getProjectMetadata;

describe("normalizeRuntimeError", () => {
  it("keeps an IpcError code and message from Core", () => {
    const error = normalizeRuntimeError(cmd, { code: "PROJECT_NOT_FOUND", message: "Project 'x' not found" });
    expect(error).toBeInstanceOf(RuntimeError);
    expect(error.code).toBe("PROJECT_NOT_FOUND");
    expect(error.message).toBe("Project 'x' not found");
    expect(error.command).toBe(cmd);
  });

  it("passes unknown Core codes through as is", () => {
    expect(normalizeRuntimeError(cmd, { code: "RATE_LIMITED", message: "slow down" }).code).toBe("RATE_LIMITED");
  });

  it("recognizes Tauri's missing-command string", () => {
    const error = normalizeRuntimeError(cmd, `Command ${cmd} not found`);
    expect(error.code).toBe("COMMAND_NOT_FOUND");
    expect(error.message).toContain(cmd);
  });

  it("does not treat an unrelated 'not found' string as a missing command", () => {
    expect(normalizeRuntimeError(cmd, "Project demo not found").code).toBe("UNKNOWN_ERROR");
  });

  it("wraps anything else as UNKNOWN_ERROR and keeps the original in cause", () => {
    const raw = { weird: true };
    const error = normalizeRuntimeError(cmd, raw);
    expect(error.code).toBe("UNKNOWN_ERROR");
    expect(error.cause).toBe(raw);
  });

  it("returns an existing RuntimeError unchanged", () => {
    const original = new RuntimeError("IPC_UNAVAILABLE", "no ipc");
    expect(normalizeRuntimeError(cmd, original)).toBe(original);
  });
});
