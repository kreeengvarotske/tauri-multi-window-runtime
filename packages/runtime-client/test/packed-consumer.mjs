import assert from 'node:assert/strict';
import { createCommand, RuntimeCommandError } from 'tmwr-runtime-client';

const read = createCommand(async (command, body) => {
  assert.equal(command, 'page');
  assert.deepEqual(body, { limit: 1 });
  return new TextEncoder().encode('{"items":[{"id":1}]}').buffer;
}, 'page');
assert.deepEqual(await read({ limit: 1 }), { items: [{ id: 1 }] });
assert.ok(RuntimeCommandError.prototype instanceof Error);
console.log('PACKED_CONSUMER_PASSED');
