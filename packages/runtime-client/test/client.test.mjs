import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createCommand, RuntimeCommandError } from '../src/index.js';

const encode = (value) => new TextEncoder().encode(JSON.stringify(value));

test('sends a JSON object and decodes an ArrayBuffer', async () => {
  const page = createCommand(async (command, body) => {
    assert.equal(command, 'catalog_page');
    assert.deepEqual(body, { query: 'Привет 🌍', limit: 10 });
    return encode({ items: [1, 2] }).buffer;
  }, 'catalog_page');
  assert.deepEqual(await page({ query: 'Привет 🌍', limit: 10 }), { items: [1, 2] });
});

test('void requests have no body; null values stay inside object requests', async () => {
  const bodies = [];
  const call = createCommand(async (_, body) => { bodies.push(body); return encode(null); }, 'note');
  assert.equal(await call(), null);
  assert.equal(await call({ value: null }), null);
  assert.equal(bodies[0], undefined);
  assert.deepEqual(bodies[1], { value: null });
});

test('postMessage JSON serialization preserves application request values', async () => {
  const call = createCommand(async (_, body) => {
    // The locked Tauri fallback turns a Uint8Array into an array before Rust.
    const delivered = JSON.parse(JSON.stringify(body, (_, value) =>
      value instanceof Uint8Array ? [...value] : value));
    assert.deepEqual(delivered, { ids: [7, 8], query: 'text' });
    return [...encode({ ok: true })];
  }, 'page');
  assert.deepEqual(await call({ ids: [7, 8], query: 'text' }), { ok: true });
});

test('byte views respect their offset and length', async () => {
  const padded = new TextEncoder().encode('xx{"ok":true}yy');
  const view = new DataView(padded.buffer, 2, padded.byteLength - 4);
  assert.deepEqual(await createCommand(async () => view, 'view')(), { ok: true });
});

test('fallback byte arrays are decoded without wrapping invalid integers', async () => {
  assert.deepEqual(await createCommand(async () => [...encode([1])], 'view')(), [1]);
  for (const value of [[256], [-1], [1.5], ['123'], {}]) {
    await assert.rejects(createCommand(async () => value, 'view')(), TypeError);
  }
});

test('invalid UTF-8 and malformed JSON are rejected', async () => {
  await assert.rejects(createCommand(async () => new Uint8Array([0xff]), 'view')(), TypeError);
  await assert.rejects(createCommand(async () => new TextEncoder().encode('{'), 'view')(), SyntaxError);
});

test('framework errors expose the stable code, command and original cause', async () => {
  const envelope = { code: 'OVERLOADED', message: 'runtime overloaded' };
  await assert.rejects(createCommand(async () => { throw envelope; }, 'page')(), (error) => {
    assert.ok(error instanceof RuntimeCommandError);
    assert.equal(error.code, 'OVERLOADED');
    assert.equal(error.command, 'page');
    assert.equal(error.message, envelope.message);
    assert.equal(error.cause, envelope);
    return true;
  });
});

test('ACL, transport and unknown future errors keep their original identity', async () => {
  for (const reason of ['command denied', new Error('network'), { code: 'FUTURE_CODE', message: 'future' }, null]) {
    await assert.rejects(createCommand(async () => { throw reason; }, 'page')(), (error) => error === reason);
  }
});

test('unrepresentable requests fail before invoking or retrying a command', async () => {
  let calls = 0;
  const call = createCommand(async () => { calls++; return encode(null); }, 'page');
  const cyclic = {}; cyclic.self = cyclic;
  for (const request of [cyclic, 1n, () => 1, Symbol('value'), null, [7, 8], 'text', 7]) await assert.rejects(call(request), TypeError);
  assert.equal(calls, 0);
});

test('overload does not trigger an implicit retry or retained response cache', async () => {
  let calls = 0;
  const call = createCommand(async () => {
    calls++;
    if (calls === 1) throw { code: 'OVERLOADED', message: 'runtime overloaded' };
    return encode(calls);
  }, 'page');
  await assert.rejects(call(), RuntimeCommandError);
  assert.equal(calls, 1);
  assert.equal(await call(), 2);
  assert.equal(await call(), 3);
});

test('invalid command/client setup is refused immediately', () => {
  assert.throws(() => createCommand(null, 'page'), TypeError);
  assert.throws(() => createCommand(async () => {}, ' '), TypeError);
});
