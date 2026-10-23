import type { RuntimeCommandName, RuntimeErrorCode } from "./contract";

export class RuntimeError extends Error {
  readonly code: RuntimeErrorCode;
  readonly command: RuntimeCommandName | null;

  constructor(
    code: RuntimeErrorCode,
    message: string,
    options: { command?: RuntimeCommandName | null; cause?: unknown } = {},
  ) {
    super(message, { cause: options.cause });
    this.name = "RuntimeError";
    this.code = code;
    this.command = options.command ?? null;
  }
}

/**
 * Turns whatever a rejected call carries into a RuntimeError (contract, section 7):
 * an `{ code, message }` object is an IpcError from Core; a Tauri string about
 * the missing command is COMMAND_NOT_FOUND; anything else is UNKNOWN_ERROR.
 */
export function normalizeRuntimeError(command: RuntimeCommandName, error: unknown): RuntimeError {
  if (error instanceof RuntimeError) return error;

  if (isRecord(error) && typeof error.code === "string" && typeof error.message === "string") {
    return new RuntimeError(error.code, error.message, { command, cause: error });
  }

  const raw = describe(error);
  if (/not found/i.test(raw) && raw.includes(command)) {
    return new RuntimeError(
      "COMMAND_NOT_FOUND",
      `Rust Core не предоставляет команду \`${command}\`. Проверьте, что Core собран из ветки с этой командой. (${raw})`,
      { command, cause: error },
    );
  }

  return new RuntimeError("UNKNOWN_ERROR", `Неожиданная ошибка в \`${command}\`: ${raw}`, { command, cause: error });
}

function describe(error: unknown): string {
  if (typeof error === "string") return error;
  if (error instanceof Error) return error.message;
  try {
    return JSON.stringify(error) ?? String(error);
  } catch {
    return String(error);
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
