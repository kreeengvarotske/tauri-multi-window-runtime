import type {
  CacheInvalidatedEvent,
  GetMetadataParams,
  InvalidateProjectResult,
  ProjectMetadata,
  RuntimeDebugStats,
} from "./contract";

/** Stops a subscription. Safe to call more than once. */
export type Unsubscribe = () => void;

export type RuntimeMode = "tauri" | "mock";

/**
 * The only seam between the SDK and a backend. The mock and Tauri
 * implementations are interchangeable without touching the UI.
 */
export interface RuntimeTransport {
  readonly mode: RuntimeMode;
  getProjectMetadata(params: GetMetadataParams): Promise<ProjectMetadata>;
  getDebugStats(): Promise<RuntimeDebugStats>;
  invalidateProject(params: GetMetadataParams): Promise<InvalidateProjectResult>;
  clearCache(): Promise<void>;
  onCacheInvalidated(handler: (event: CacheInvalidatedEvent) => void): Promise<Unsubscribe>;
}
