// Collect subsystem accounting from one isolated, app-owned browser endpoint.
// This adds tracing overhead. It does not launch an app or measure a RAM saving.
import { openSync, writeFileSync, closeSync, existsSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';

const errorText = error => error instanceof Error ? error.message : String(error);
const MAX_OUTPUT_BYTES = 32 * 1024 * 1024;
const ALLOWED_METHODS = new Set(['Tracing.start', 'Tracing.requestMemoryDump', 'Tracing.end']);

export function browserSocket(raw, port) {
  const url = new URL(raw);
  if (url.protocol !== 'ws:' || !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)
      || Number(url.port) !== port || url.username || url.password || url.search || url.hash
      || !/^\/devtools\/browser\/[a-zA-Z0-9-]+$/.test(url.pathname)) {
    throw new Error('Refused endpoint outside the supplied loopback browser port');
  }
  url.hostname = '127.0.0.1';
  return url.href;
}

export function traceParameters() {
  return {
    transferMode: 'ReportEvents',
    tracingBackend: 'chrome',
    bufferUsageReportingInterval: 1000,
    traceConfig: {
      recordMode: 'recordUntilFull', traceBufferSizeInKb: 8192,
      includedCategories: ['disabled-by-default-memory-infra'], excludedCategories: ['*'],
      enableSampling: false, enableSystrace: false,
      memoryDumpConfig: { triggers: [] },
    },
  };
}

/** The client owns only this fresh browser's CDP connection, never a global OS trace. */
export async function collectMemoryInfra(client, {
  samples = 10, intervalMs = 5000, write, shouldStop = () => false, sleep = delay,
  completionTimeoutMs = 5000,
} = {}) {
  if (!Number.isInteger(samples) || samples < 1 || samples > 12
      || !Number.isInteger(intervalMs) || intervalMs < 5000 || intervalMs > 10000
      || typeof write !== 'function') throw new Error('Invalid collection limits or writer');
  const summary = { diagnosticOnly: true, success: false, started: false, traceComplete: false,
    requestedSamples: samples, stoppedEarly: false,
    dataLossOccurred: false, bufferLimitReached: false, traceEvents: 0, memoryDumpEvents: 0,
    dumps: [], errors: [] };
  let complete;
  const completed = new Promise(resolveComplete => { complete = resolveComplete; });
  const unsubscribe = client.subscribe(event => {
    try {
      if (event.method === 'Tracing.dataCollected') {
        if (!Array.isArray(event.params?.value)) throw new Error('Malformed trace event batch');
        summary.traceEvents += event.params.value.length;
        summary.memoryDumpEvents += event.params.value.filter(record => {
          const dumps = record?.args?.dumps;
          return record?.ph === 'v' && typeof record.cat === 'string'
            && record.cat.split(',').includes('disabled-by-default-memory-infra')
            && ['allocators', 'process_totals'].some(key => dumps?.[key]
              && typeof dumps[key] === 'object' && !Array.isArray(dumps[key])
              && Object.keys(dumps[key]).length > 0);
        }).length;
        write({ kind: 'trace-events', events: event.params.value });
      } else if (event.method === 'Tracing.tracingComplete') {
        summary.traceComplete = true;
        complete();
        if (typeof event.params?.dataLossOccurred !== 'boolean') throw new Error('Missing trace data-loss flag');
        summary.dataLossOccurred = event.params.dataLossOccurred;
      } else if (event.method === 'Tracing.bufferUsage') {
        if (Math.max(event.params?.percentFull ?? 0, event.params?.value ?? 0) >= 0.95) {
          summary.bufferLimitReached = true;
        }
      }
    } catch (error) { summary.errors.push(errorText(error)); }
  });
  try {
    if (shouldStop()) throw new Error('Stop marker exists before tracing');
    await client.send('Tracing.start', traceParameters());
    summary.started = true;
    for (let index = 0; index < samples; index++) {
      if (shouldStop() || summary.errors.length || summary.bufferLimitReached) break;
      const requestedAt = new Date().toISOString();
      const dump = await client.send('Tracing.requestMemoryDump', {
        deterministic: false, levelOfDetail: 'detailed',
      });
      const record = { requestedAt, completedAt: new Date().toISOString(), ...dump };
      summary.dumps.push(record);
      write({ kind: 'dump-request', ...record });
      if (dump.success !== true || typeof dump.dumpGuid !== 'string' || !dump.dumpGuid) {
        throw new Error('Memory dump was refused or has no GUID');
      }
      if (index + 1 < samples) {
        for (let remaining = intervalMs; remaining > 0 && !shouldStop(); remaining -= 100) {
          if (summary.errors.length || summary.bufferLimitReached) break;
          await sleep(Math.min(100, remaining));
        }
      }
    }
  } catch (error) { summary.errors.push(errorText(error)); }
  finally {
    // A rejected start may mean somebody else owns tracing. Never end their trace.
    if (summary.started) {
      let timer;
      try {
        await client.send('Tracing.end', {});
        await Promise.race([completed, new Promise((_, reject) => {
          timer = setTimeout(() => reject(new Error('Trace flush timed out')), completionTimeoutMs);
        })]);
      } catch (error) { summary.errors.push(errorText(error)); }
      finally { clearTimeout(timer); }
    }
    unsubscribe();
  }
  summary.stoppedEarly = summary.dumps.length < samples;
  if (summary.traceComplete && summary.memoryDumpEvents === 0) {
    summary.errors.push('No memory accounting events were delivered');
  }
  summary.success = summary.started && summary.traceComplete && summary.dumps.length > 0
    && summary.memoryDumpEvents > 0 && !summary.dataLossOccurred && !summary.bufferLimitReached
    && summary.errors.length === 0;
  return summary;
}

async function connect(port) {
  const response = await fetch(`http://127.0.0.1:${port}/json/version`, {
    redirect: 'error', signal: AbortSignal.timeout(3000),
  });
  if (!response.ok) throw new Error(`Browser discovery HTTP ${response.status}`);
  const version = await response.json();
  const socket = new WebSocket(browserSocket(version.webSocketDebuggerUrl, port));
  const pending = new Map();
  const listeners = new Set();
  let nextId = 0;
  const fail = error => {
    for (const item of pending.values()) { clearTimeout(item.timer); item.reject(error); }
    pending.clear();
  };
  socket.addEventListener('message', event => {
    try {
      if (typeof event.data !== 'string' || event.data.length > MAX_OUTPUT_BYTES) {
        throw new Error('Non-text or oversized CDP frame');
      }
      const message = JSON.parse(event.data);
      if (message.id !== undefined) {
        const item = pending.get(message.id);
        if (!item) return;
        pending.delete(message.id); clearTimeout(item.timer);
        if (message.error) item.reject(new Error(JSON.stringify(message.error)));
        else item.resolve(message.result ?? {});
      } else { for (const listener of listeners) listener(message); }
    } catch (error) { fail(error); socket.close(); }
  });
  socket.addEventListener('close', () => fail(new Error('Browser socket closed')));
  socket.addEventListener('error', () => fail(new Error('Browser socket error')));
  await new Promise((resolveOpen, rejectOpen) => {
    const timer = setTimeout(() => { socket.close(); rejectOpen(new Error('Browser socket open timed out')); }, 3000);
    socket.addEventListener('open', () => { clearTimeout(timer); resolveOpen(); }, { once: true });
    socket.addEventListener('error', () => { clearTimeout(timer); rejectOpen(new Error('Browser socket open failed')); }, { once: true });
    socket.addEventListener('close', () => { clearTimeout(timer); rejectOpen(new Error('Browser socket closed before open')); }, { once: true });
  });
  return {
    subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener); },
    send(method, params) {
      if (!ALLOWED_METHODS.has(method)) return Promise.reject(new Error('Method is not allowed'));
      if (socket.readyState !== WebSocket.OPEN) return Promise.reject(new Error('Browser socket is not open'));
      return new Promise((resolveCommand, rejectCommand) => {
        const id = ++nextId;
        const timer = setTimeout(() => { pending.delete(id); rejectCommand(new Error(`${method} timed out`)); }, 3000);
        pending.set(id, { resolve: resolveCommand, reject: rejectCommand, timer });
        try { socket.send(JSON.stringify({ id, method, params })); }
        catch (error) { clearTimeout(timer); pending.delete(id); rejectCommand(error); }
      });
    },
    close() { fail(new Error('Collector closed')); socket.close(); },
    version: { browser: version.Browser, protocol: version['Protocol-Version'] },
  };
}

async function main(args) {
  const options = {};
  for (let index = 0; index < args.length; index += 2) {
    const key = args[index];
    if (!['--port', '--out', '--stop-file'].includes(key) || options[key] || !args[index + 1]) {
      throw new Error('Use --port PORT --out NEW.jsonl --stop-file MARKER (owned test browser only)');
    }
    options[key] = args[index + 1];
  }
  const port = Number(options['--port']);
  if (!Number.isInteger(port) || port < 1 || port > 65535 || !options['--out'] || !options['--stop-file']) {
    throw new Error('A port, new output file and stop marker path are required');
  }
  const output = resolve(options['--out']);
  const stopFile = resolve(options['--stop-file']);
  if (output === stopFile || `${output}.summary.json` === stopFile || existsSync(stopFile)) {
    throw new Error('Stop marker must be absent and separate from outputs');
  }
  const summaryPath = `${output}.summary.json`;
  if (existsSync(output) || existsSync(summaryPath)) throw new Error('Refused to overwrite diagnostic output');
  mkdirSync(dirname(output), { recursive: true });
  const fd = openSync(output, 'wx');
  let client;
  let bytes = 0;
  let summary;
  const write = record => {
    const line = JSON.stringify({ timestamp: new Date().toISOString(), ...record }) + '\n';
    const size = Buffer.byteLength(line);
    if (bytes + size > MAX_OUTPUT_BYTES) throw new Error('Trace output exceeded 32 MiB');
    writeFileSync(fd, line); bytes += size;
  };
  try {
    client = await connect(port);
    write({ kind: 'start', diagnosticOnly: true, version: client.version, port,
      methods: [...ALLOWED_METHODS], forceGc: false, outputLimitBytes: MAX_OUTPUT_BYTES });
    summary = await collectMemoryInfra(client, { write, shouldStop: () => existsSync(stopFile) });
  } catch (error) { summary = { diagnosticOnly: true, success: false, errors: [errorText(error)] }; }
  finally { client?.close(); closeSync(fd); }
  const summaryFd = openSync(summaryPath, 'wx');
  try { writeFileSync(summaryFd, JSON.stringify({ ...summary, bytes }, null, 2) + '\n'); }
  finally { closeSync(summaryFd); }
  process.stdout.write(JSON.stringify({ output, summaryPath, success: summary.success }) + '\n');
  if (!summary.success) process.exitCode = 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main(process.argv.slice(2)).catch(error => { console.error(errorText(error)); process.exitCode = 1; });
}
