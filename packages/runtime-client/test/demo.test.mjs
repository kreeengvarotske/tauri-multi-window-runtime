import { test } from 'node:test';
import assert from 'node:assert/strict';

test('the real demo uses object requests and preserves error envelopes in events and UI', async () => {
  const previous = Object.fromEntries(['window', 'document', 'location'].map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
  const envelope = { code: 'OVERLOADED', message: 'runtime overloaded' };
  const calls = [];
  const elements = Object.fromEntries(['#page', '#note', '#out'].map((key) => [key, {}]));
  let finish;
  const reported = new Promise((resolve) => { finish = resolve; });
  globalThis.document = { querySelector: (key) => elements[key] };
  globalThis.location = { search: '?self-test=main' };
  globalThis.window = {
    __TAURI__: {
      core: { invoke: async (command, request) => {
        calls.push({ command, request });
        if (command === 'demo_catalog_page') throw envelope;
        return new TextEncoder().encode('{"catalogExecutions":1}').buffer;
      } },
      event: { emit: async (name, payload) => {
        assert.equal(name, 'demo://self-test-main');
        finish(JSON.parse(JSON.stringify(payload)));
      } },
    },
  };
  let timer;
  try {
    await import('../../../examples/runtime-adapter-demo/ui/main.js');
    const payload = await Promise.race([
      reported,
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Demo did not emit its report')), 1000); }),
    ]);
    assert.deepEqual(calls[0], { command: 'demo_catalog_page', request: { offset: 15, limit: 3 } });
    assert.deepEqual(payload.page.error, envelope);
    assert.deepEqual(payload.stats.ok, { catalogExecutions: 1 });
    await elements['#page'].onclick();
    assert.deepEqual(JSON.parse(elements['#out'].textContent), envelope);
  } finally {
    clearTimeout(timer);
    for (const [key, descriptor] of Object.entries(previous)) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor);
      else delete globalThis[key];
    }
  }
});
