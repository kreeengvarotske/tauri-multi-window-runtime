// Test data for the mock transport. Not Core data: the ids and the access rule
// below exist only to exercise UI states until Core publishes its own fixtures.

import type { CoreErrorCode, WindowLabel } from "../contract";

export interface MockProject {
  name: string;
  revision: number;
  /** Windows allowed to read the project; absent means every window. */
  allowedWindows?: readonly WindowLabel[];
}

export const MOCK_PROJECTS: Readonly<Record<string, MockProject>> = {
  demo: { name: "Demo project", revision: 3 },
  "project-42": { name: "Project 42", revision: 7 },
  "main-only": { name: "Main window only", revision: 1, allowedWindows: ["main"] },
};

/** Ids that always fail with a given Core error code. */
export const MOCK_FAILING_PROJECTS: Readonly<Record<string, CoreErrorCode>> = {
  broken: "OPERATION_FAILED",
  forbidden: "ACCESS_DENIED",
};

export const MOCK_PROJECT_IDS: readonly string[] = [
  ...Object.keys(MOCK_PROJECTS),
  ...Object.keys(MOCK_FAILING_PROJECTS),
  "missing",
];
