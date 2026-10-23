// Wire contract with Rust Core: crates/runtime-ipc and src-tauri/src/commands.rs
// (described in docs/frontend-backend-contract.md).
// Field names must match the serde output of the IPC layer (camelCase).

export type CachePolicy =
  | { kind: "noStore" }
  | { kind: "ttl"; ttlMs: number }
  | { kind: "forever" };

export interface ProjectMetadata {
  projectId: string;
  name: string;
  revision: number;
  /** Unix time of the computation, ms. Equal values mean one shared result (cached or coalesced). */
  computedAtMs: number;
}

/**
 * Counters of the shared Rust Core, not of a single WebView.
 * Diagnostic data only; never used as a security control.
 */
export interface RuntimeDebugStats {
  requestsReceived: number;
  operationsExecuted: number;
  coalescedRequests: number;
  cacheHits: number;
  failedRequests: number;
  cachedEntries: number;
  cachePolicy: CachePolicy;
}

export interface GetMetadataParams {
  projectId: string;
}

export interface InvalidateProjectParams {
  projectId: string;
}

export interface InvalidateProjectResult {
  /** false when the project had no cache entry. */
  invalidated: boolean;
}

/** Codes sent by Core (via the IPC layer). */
export type CoreErrorCode =
  | "INVALID_ARGUMENT"
  | "PROJECT_NOT_FOUND"
  | "ACCESS_DENIED"
  | "OPERATION_FAILED"
  | "INTERNAL";

/** Codes produced by the SDK itself; Rust never sends them. */
export type ClientErrorCode =
  | "IPC_UNAVAILABLE"
  | "COMMAND_NOT_FOUND"
  | "UNKNOWN_ERROR"
  | "STATS_UNAVAILABLE_IN_MOCK";

/** Unknown codes from Core are kept as a string. */
export type RuntimeErrorCode = CoreErrorCode | ClientErrorCode | (string & {});

/** Shape of a rejected `invoke` when Core returns an `IpcError`. */
export interface IpcErrorPayload {
  code: string;
  message: string;
}

export const RUNTIME_COMMANDS = {
  getProjectMetadata: "runtime_get_project_metadata",
  getDebugStats: "runtime_get_debug_stats",
  /** Main window only; Core answers ACCESS_DENIED to any other window. */
  invalidateProject: "runtime_invalidate_project",
  /** Main window only; Core answers ACCESS_DENIED to any other window. */
  clearCache: "runtime_clear_cache",
} as const;

export type RuntimeCommandName = (typeof RUNTIME_COMMANDS)[keyof typeof RUNTIME_COMMANDS];

/** Window labels are part of the contract: capabilities and access checks rely on them. */
export const WINDOW_LABELS = { main: "main", secondary: "secondary" } as const;

export type WindowLabel = (typeof WINDOW_LABELS)[keyof typeof WINDOW_LABELS];

export const PROJECT_ID_MAX_LENGTH = 128;
