import { test } from 'node:test';
import assert from 'node:assert/strict';
import { browserSocket, traceParameters, collectMemoryInfra } from './MemoryInfraDiagnostic.mjs';
import { mkdtempSync, writeFileSync, readFileSync, unlinkSync, rmdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

function fake({ startError = false, failedDump = false, dataLoss = false, noFlush = false,
  malformed = false, fullBuffer = false, metadataOnly = false } = {}) {
  let listener;
  const calls = [];
  const client = {
    subscribe(callback) { listener = callback; return () => { listener = null; }; },
    async send(method, params) {
      calls.push({ method, params });
      if (method === 'Tracing.start' && startError) throw new Error('Tracing already in progress');
      if (method === 'Tracing.requestMemoryDump') {
        if (fullBuffer) listener({ method: 'Tracing.bufferUsage', params: { percentFull: 0.99 } });
        return { success: !failedDump, dumpGuid: 'abc123' };
      }
      if (method === 'Tracing.end' && !noFlush) {
        listener({ method: 'Tracing.dataCollected', params: { value: malformed ? {} : [
          metadataOnly ? { pid: 123, ph: 'M', name: 'process_name', args: { name: 'Renderer' } }
            : { pid: 123, ph: 'v', cat: 'disabled-by-default-memory-infra', args: { dumps: {
              allocators: { blink_gc: { attrs: { size: { type: 'scalar', units: 'bytes', value: '1000' } } } },
            } } },
        ] } });
        listener({ method: 'Tracing.tracingComplete', params: { dataLossOccurred: dataLoss } });
      }
      return {};
    },
  };
  return { client, calls };
}

test('accepts only the supplied loopback browser endpoint', () => {
  assert.equal(browserSocket('ws://localhost:9222/devtools/browser/abc-123', 9222),
    'ws://127.0.0.1:9222/devtools/browser/abc-123');
  for (const url of ['ws://example.com:9222/devtools/browser/abc',
    'ws://127.0.0.1:9223/devtools/browser/abc', 'ws://127.0.0.1:9222/devtools/page/abc',
    'ws://user:pass@127.0.0.1:9222/devtools/browser/abc',
    'ws://127.0.0.1:9222/devtools/browser/abc?redirect=elsewhere']) {
    assert.throws(() => browserSocket(url, 9222), /Refused/);
  }
});

test('uses bounded memory-only browser tracing and explicitly avoids deterministic GC', async () => {
  const { client, calls } = fake(); const records = [];
  const result = await collectMemoryInfra(client, { samples: 2, write: x => records.push(x), sleep: async () => {} });
  assert.equal(result.success, true);
  assert.equal(result.dumps.length, 2);
  assert.equal(result.traceEvents, 1);
  assert.equal(result.stoppedEarly, false);
  assert.equal(traceParameters().tracingBackend, 'chrome');
  assert.deepEqual(calls.map(x => x.method), ['Tracing.start', 'Tracing.requestMemoryDump', 'Tracing.requestMemoryDump', 'Tracing.end']);
  for (const call of calls.filter(x => x.method === 'Tracing.requestMemoryDump')) {
    assert.deepEqual(call.params, { deterministic: false, levelOfDetail: 'detailed' });
  }
  assert.equal(traceParameters().traceConfig.traceBufferSizeInKb, 8192);
  assert.deepEqual(traceParameters().traceConfig.includedCategories, ['disabled-by-default-memory-infra']);
  assert.equal(records.filter(x => x.kind === 'trace-events').length, 1);
});

test('does not stop somebody else\'s trace after a rejected start', async () => {
  const { client, calls } = fake({ startError: true });
  const result = await collectMemoryInfra(client, { write() {} });
  assert.equal(result.success, false);
  assert.equal(result.started, false);
  assert.deepEqual(calls.map(x => x.method), ['Tracing.start']);
});

test('flushes an owned trace after a failed dump and retains the failure', async () => {
  const { client, calls } = fake({ failedDump: true });
  const result = await collectMemoryInfra(client, { write() {} });
  assert.equal(result.success, false);
  assert.equal(result.traceComplete, true);
  assert.match(result.errors.join(), /refused/);
  assert.equal(calls.at(-1).method, 'Tracing.end');
});

test('data loss, a nearly full buffer, malformed batches and writer failures cannot pass', async () => {
  for (const options of [{ dataLoss: true }, { fullBuffer: true }, { malformed: true }, {}]) {
    const { client } = fake(options);
    const result = await collectMemoryInfra(client, { samples: 1,
      write() { if (Object.keys(options).length === 0) throw new Error('Disk full'); } });
    assert.equal(result.success, false);
  }
});

test('a missing trace flush times out instead of reporting a complete profile', async () => {
  const { client } = fake({ noFlush: true });
  const result = await collectMemoryInfra(client, { samples: 1, write() {}, completionTimeoutMs: 10 });
  assert.equal(result.success, false);
  assert.equal(result.traceComplete, false);
  assert.match(result.errors.join(), /flush timed out/);
});

test('successful dump replies and trace metadata cannot substitute for memory accounting', async () => {
  const { client } = fake({ metadataOnly: true });
  const result = await collectMemoryInfra(client, { samples: 1, write() {} });
  assert.equal(result.traceComplete, true);
  assert.equal(result.dumps[0].success, true);
  assert.equal(result.success, false);
  assert.match(result.errors.join(), /No memory accounting/);
});

test('stops between samples and refuses to start when a stop marker already exists', async () => {
  let stopped = false;
  const { client, calls } = fake();
  const result = await collectMemoryInfra(client, { samples: 3, shouldStop: () => stopped,
    write(record) { if (record.kind === 'dump-request') stopped = true; } });
  assert.equal(result.success, true);
  assert.equal(result.dumps.length, 1);
  assert.equal(result.stoppedEarly, true);
  assert.equal(calls.at(-1).method, 'Tracing.end');
  const before = fake();
  const refused = await collectMemoryInfra(before.client, { write() {}, shouldStop: () => true });
  assert.equal(refused.success, false);
  assert.equal(before.calls.length, 0);
});

test('CLI preserves existing output bytes and never connects when output already exists', () => {
  const directory = mkdtempSync(join(tmpdir(), 'catalog-memoryinfra-test-'));
  const output = join(directory, 'profile.jsonl');
  try {
    writeFileSync(output, 'existing evidence\n');
    const result = spawnSync(process.execPath, [fileURLToPath(new URL('./MemoryInfraDiagnostic.mjs', import.meta.url)),
      '--port', '1', '--out', output, '--stop-file', join(directory, 'stop')], { encoding: 'utf8', timeout: 5000 });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /Refused to overwrite/);
    assert.equal(readFileSync(output, 'utf8'), 'existing evidence\n');
  } finally { unlinkSync(output); rmdirSync(directory); }
});
