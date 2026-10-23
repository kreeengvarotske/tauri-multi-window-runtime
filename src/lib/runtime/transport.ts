import type {
  GetMetadataParams,
  InvalidateProjectParams,
  InvalidateProjectResult,
  ProjectMetadata,
  RuntimeDebugStats,
} from "./contract";

export type RuntimeMode = "tauri" | "mock";

/**
 * The only seam between the SDK and a backend. The mock and Tauri
 * implementations are interchangeable without touching the UI.
 */
export interface RuntimeTransport {
  readonly mode: RuntimeMode;
  getProjectMetadata(params: GetMetadataParams): Promise<ProjectMetadata>;
  getDebugStats(): Promise<RuntimeDebugStats>;
  invalidateProject(params: InvalidateProjectParams): Promise<InvalidateProjectResult>;
  clearCache(): Promise<void>;
}
