import { createCommand, RuntimeCommandError, type Invoke } from 'tmwr-runtime-client';

// Match the Tauri invoke shape without adding a runtime dependency on its package.
declare function invoke<T>(command: string, args?: Record<string, unknown> | number[] | ArrayBuffer | Uint8Array): Promise<T>;
const transport: Invoke = invoke;
interface PageRequest { offset: number; limit: number }
interface Page { total: number; items: { id: number; name: string }[] }
const page = createCommand<PageRequest, Page>(transport, 'catalog_page');
const result: Promise<Page> = page({ offset: 0, limit: 10 });
void result;
// @ts-expect-error A bounded page request is required.
page();
// @ts-expect-error Wrong request type.
page({ offset: '0', limit: 10 });
// @ts-expect-error Response types are retained.
const wrong: Promise<number> = page({ offset: 0, limit: 10 });
void wrong;
const note = createCommand<void, { value: string }>(invoke, 'window_note');
const noArgs: Promise<{ value: string }> = note();
void noArgs;
// @ts-expect-error Requests must be objects or omitted, not primitive roots.
createCommand<string, Page>(invoke, 'page');
const array = createCommand<number[], Page>(invoke, 'page');
// @ts-expect-error Root arrays must be wrapped in a request object.
array([1, 2]);
const optional = createCommand<PageRequest | undefined, Page>(invoke, 'page');
optional({ offset: 0, limit: 10 });
optional(undefined);
// @ts-expect-error A void command does not accept arbitrary data.
note({ label: 'other-window' });
function onError(error: unknown) {
  if (error instanceof RuntimeCommandError && error.code === 'OVERLOADED') {
    const command: string = error.command;
    void command;
  }
}
void onError;
