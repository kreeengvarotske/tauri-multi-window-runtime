const decoder = new TextDecoder('utf-8', { fatal: true });
const runtimeCodes = new Set([
  'INVALID_ARGUMENT', 'REQUEST_TOO_LARGE', 'RESPONSE_TOO_LARGE',
  'DEADLINE_EXCEEDED', 'OVERLOADED', 'SHUTTING_DOWN', 'OPERATION_FAILED', 'INTERNAL',
]);

/** A stable error envelope returned by the Rust adapter. */
export class RuntimeCommandError extends Error {
  constructor(code, message, command, cause) {
    super(message, { cause });
    this.name = 'RuntimeCommandError';
    this.code = code;
    this.command = command;
  }
}

function responseBytes(response) {
  if (response instanceof ArrayBuffer) return new Uint8Array(response);
  if (ArrayBuffer.isView(response)) {
    return new Uint8Array(response.buffer, response.byteOffset, response.byteLength);
  }
  if (Array.isArray(response) && response.every((byte) => Number.isInteger(byte) && byte >= 0 && byte <= 255)) {
    return Uint8Array.from(response);
  }
  throw new TypeError('Expected a JSON-byte response from the runtime command');
}

/** Bind an existing, capability-controlled Tauri command to its JSON request. */
export function createCommand(invoke, command) {
  if (typeof invoke !== 'function' || typeof command !== 'string' || !command.trim()) {
    throw new TypeError('Expected an invoke function and a nonempty command name');
  }
  return async (request) => {
    let body;
    if (request !== undefined) {
      const json = JSON.stringify(request);
      if (json === undefined) throw new TypeError('Request must be representable as JSON');
      body = JSON.parse(json);
      if (body === null || typeof body !== 'object' || Array.isArray(body)) {
        throw new TypeError('Request must be a JSON object; wrap primitive or array values in an object');
      }
    }
    let response;
    try {
      response = await invoke(command, body);
    } catch (error) {
      if (error && runtimeCodes.has(error.code) && typeof error.message === 'string') {
        throw new RuntimeCommandError(error.code, error.message, command, error);
      }
      throw error;
    }
    return JSON.parse(decoder.decode(responseBytes(response)));
  };
}
