// Contracts shared with Rust Core. This file is the single source of types
// for the frontend; field names must match the serde output of the Core.

export interface ProjectMetadata {
  projectId: string;
  name: string;
  revision: number;
}

/**
 * Diagnostic counters of the shared Rust Core (not of a single WebView).
 * Diagnostic data only; never used as a security control.
 */
export interface RuntimeDebugStats {
  /** Calls of the operation accepted by Core. */
  requestsReceived: number;
  /** Operation executions actually started. */
  operationExecutions: number;
  /** Requests that joined an operation already in flight. */
  coalescedRequests: number;
  /** Operations running right now. */
  inFlightOperations: number;
}

export interface GetMetadataParams {
  projectId: string;
}

export type RuntimeMode = "tauri" | "mock";

/** Tauri command names agreed with Rust Core. */
export const RuntimeCommand = {
  getProjectMetadata: "runtime_get_project_metadata",
  getDebugStats: "runtime_get_debug_stats",
} as const;

export type RuntimeCommandName = (typeof RuntimeCommand)[keyof typeof RuntimeCommand];

export type RuntimeErrorCode =
  /** Tauri IPC is not available (e.g. the page is opened in a regular browser). */
  | "IPC_UNAVAILABLE"
  /** Core has not registered the command (yet). */
  | "COMMAND_NOT_FOUND"
  /** Core diagnostics are not available in mock mode. */
  | "STATS_UNAVAILABLE_IN_MOCK"
  /** Error simulated by the mock client. */
  | "MOCK_SIMULATED_FAILURE"
  /** Invalid input rejected by the SDK before reaching the transport. */
  | "INVALID_ARGUMENT"
  /** Any error returned by Core; the Core-provided code is kept in `coreCode`. */
  | "CORE_ERROR"
  | "UNKNOWN";

export class RuntimeError extends Error {
  readonly code: RuntimeErrorCode;
  readonly command: RuntimeCommandName | null;
  /** Error code reported by Rust Core, if it sent a structured error. */
  readonly coreCode: string | null;
  readonly originalError: unknown;

  constructor(
    code: RuntimeErrorCode,
    message: string,
    options: { command?: RuntimeCommandName | null; coreCode?: string | null; originalError?: unknown } = {},
  ) {
    super(message);
    this.name = "RuntimeError";
    this.code = code;
    this.command = options.command ?? null;
    this.coreCode = options.coreCode ?? null;
    this.originalError = options.originalError;
  }
}

/**
 * Transport used by the SDK. The SDK depends only on this interface, so the
 * mock and Tauri implementations are interchangeable without touching the UI.
 */
export interface RuntimeTransport {
  readonly mode: RuntimeMode;
  getProjectMetadata(params: GetMetadataParams): Promise<ProjectMetadata>;
  getDebugStats(): Promise<RuntimeDebugStats>;
}
