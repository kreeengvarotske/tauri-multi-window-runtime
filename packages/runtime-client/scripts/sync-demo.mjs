import { readFile, writeFile } from 'node:fs/promises';

const source = new URL('../src/index.js', import.meta.url);
const target = new URL('../../../examples/runtime-adapter-demo/ui/runtime-client.js', import.meta.url);
const normalize = (text) => text.replaceAll('\r\n', '\n');
const banner = '// Generated from packages/runtime-client/src/index.js; run npm run sync-demo there.\n';
const expected = banner + normalize(await readFile(source, 'utf8'));
let actual;
try {
  actual = normalize(await readFile(target, 'utf8'));
} catch (error) {
  if (error.code !== 'ENOENT') throw error;
}
const mode = process.argv[2] ?? '--check';
if (process.argv.length > 3 || !['--check', '--write'].includes(mode)) {
  throw new Error('Use --check or --write');
}
if (actual !== expected) {
  if (mode === '--check') throw new Error('Demo client is missing or stale; run npm run sync-demo');
  await writeFile(target, expected, 'utf8');
}
console.log('DEMO_CLIENT_SYNC_OK');
