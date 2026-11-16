# Shared runtime command client

An optional, dependency-free ES module for the Rust adapter's JSON requests
and JSON-byte responses. It works with any frontend that uses Tauri v2. It has no React,
Vue, Svelte or Node runtime dependency and does not replace Tauri permissions.

## Install from a reviewed checkout

Registry publication is not required for this Git preview. From your frontend
project, install the package directory from a reviewed repository checkout:

```sh
npm install /path/to/tauri-multi-window-runtime/packages/runtime-client
```

The package is private to prevent accidental registry publication. A local
package or `npm pack` tarball can still be installed. Pin the checkout and
retain your application's lockfile. Use the two Rust crates at the reviewed
SDK revision; see the [backend quick start](../../examples/runtime-adapter-demo/README.md).

## Call an existing command

```ts
import { invoke } from '@tauri-apps/api/core';
import { createCommand, RuntimeCommandError } from 'tmwr-runtime-client';

interface PageRequest { offset: number; limit: number }
interface Page { total: number; items: { id: number; name: string }[] }

const catalogPage = createCommand<PageRequest, Page>(invoke, 'demo_catalog_page');
const windowNote = createCommand<void, { execution: number }>(invoke, 'demo_window_note');

try {
  const page = await catalogPage({ offset: 0, limit: 10 });
  console.log(page.items);
  console.log(await windowNote());
} catch (error) {
  if (error instanceof RuntimeCommandError && error.code === 'OVERLOADED') {
    // Show an application-specific busy state; no automatic retry runs.
  } else {
    throw error;
  }
}
```

In JavaScript, omit the interfaces and generic arguments. The host supplies
`invoke`; with Tauri's global API, use `window.__TAURI__.core.invoke`.
Commands must be registered by the Rust app and granted by its capabilities.
An IPC command name is not a runtime operation/window/scope selector.

## Behavior and limits

- Requests are snapshotted as plain JSON objects; a void request sends no body.
  Wrap primitive/array values in a Rust request struct and matching JS object.
  Invalid/unrepresentable requests fail before invoke. Object requests work
  through both custom-protocol IPC and the desktop postMessage fallback;
  the fallback would otherwise turn a binary request into an application array.
  The adapter already accepts JSON objects and checks their serialized size.
- ArrayBuffer, byte views and byte arrays decode as strict UTF-8 JSON. Invalid
  bytes or malformed JSON fail rather than returning unchecked replacement text.
- Stable framework error envelopes become `RuntimeCommandError`, retaining
  code, message, command and cause. ACL/transport errors and unknown future
  envelopes are rethrown unchanged.
- No retries, frontend response cache, timeout or cancellation layer is added.
  Rust owns admission, deadlines, cache lifetime and bounded response creation.
- TypeScript types are declared by the application. There is no Rust type
  generation or runtime response-schema validator. Keep types aligned with
  registered Rust commands. Request/response budgets remain server-side.

Development: `npm ci`, `npm test`, `npm run typecheck`. The package tests use
Node's built-in runner; only the development type checker is installed.

The real Tauri demo imports the same client from a distributed copy in its
static assets, so it needs no frontend bundler or npm install to run. After
editing `src/index.js`, run `npm run sync-demo` from this package. CI runs
`npm run check-demo`; it rejects missing/stale copies and tolerates Git's
LF/CRLF checkout conversion. The demo's native self-test exercises this copy
through real WebView IPC, including JSON requests and unchanged error reports.
