// Entry point of the runtime layer for UI code. Components import from here
// only, never from `./tauri/*`, `./mock/*` or `@tauri-apps/api`.

export { createRuntimeClient, createRuntimeFromEnv, type RuntimeClient, type RuntimeSetup } from "./client";
export { RuntimeError } from "./errors";
export type { MockControls } from "./mock/mock-transport";
export type { RuntimeMode, RuntimeTransport } from "./transport";
export {
  RUNTIME_COMMANDS,
  WINDOW_LABELS,
  type CachePolicy,
  type GetMetadataParams,
  type InvalidateProjectResult,
  type ProjectMetadata,
  type RuntimeDebugStats,
  type RuntimeErrorCode,
} from "./contract";
