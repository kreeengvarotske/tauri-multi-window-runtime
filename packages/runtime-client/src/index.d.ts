/** Compatible with Tauri v2's invoke; the host application supplies it. */
export type Invoke = (command: string, body?: Record<string, unknown>) => Promise<unknown>;

export type RuntimeErrorCode =
  | 'INVALID_ARGUMENT' | 'REQUEST_TOO_LARGE' | 'RESPONSE_TOO_LARGE'
  | 'DEADLINE_EXCEEDED' | 'OVERLOADED' | 'SHUTTING_DOWN'
  | 'OPERATION_FAILED' | 'INTERNAL';

export class RuntimeCommandError extends Error {
  readonly code: RuntimeErrorCode;
  readonly command: string;
  readonly cause: unknown;
  constructor(code: RuntimeErrorCode, message: string, command: string, cause?: unknown);
}

export type Command<Request, Response> = [Request] extends [readonly unknown[]]
  ? never
  : [Request] extends [void]
  ? (request?: Request) => Promise<Response>
  : (request: Request) => Promise<Response>;

/** Types are developer-declared; Rust remains responsible for validation and authorization. */
export function createCommand<Request extends object | void = void, Response = unknown>(
  invoke: Invoke,
  command: string,
): Command<Request, Response>;
