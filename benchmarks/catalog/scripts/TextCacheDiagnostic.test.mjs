import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createPlan, auditReports } from './TextCacheDiagnostic.mjs';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const plan = () => createPlan('a'.repeat(40), 'b'.repeat(64));
function reports(p) {
  return Object.fromEntries(p.runs.map(run => {
    const windows = run.cell === 'N2D16' ? 2 : 4;
    return [run.name, { schemaVersion: 1, scenario: 'M', passed: true, problems: [],
      config: { scenario: 'M', arm: 'C', windows, dataMib: windows === 2 ? 16 : 64,
        seed: 1, stepIntervalMs: 500, idleBeforeSeconds: 20, warmupSeconds: 30,
        loadSeconds: 120, idleAfterSeconds: 30, textCache: run.mode === 'on', automated: true },
      windows: Object.fromEntries(Array.from({ length: windows }, (_, index) => {
        const label = index === 0 ? 'main' : `w${index}`;
        return [label, { label, windowIndex: index, arm: 'C', passed: true, firstError: null,
          load: { scheduledSteps: 240, completedSteps: 240, failures: 0, mismatches: 0 },
          warmup: { failures: 0, mismatches: 0 } }];
      })),
      totals: { scheduledSteps: windows * 240, completedSteps: windows * 240, failures: 0, mismatches: 0, overruns: 0 } }];
  }));
}
test('schedule has adjacent opposite-mode pairs, fixed cells and all twelve unique names', () => {
  const p = plan();
  assert.equal(p.runs.length, 12);
  assert.equal(new Set(p.runs.map(run => run.name)).size, 12);
  for (let i = 0; i < 12; i += 2) {
    assert.equal(p.runs[i].cell, p.runs[i + 1].cell);
    assert.equal(p.runs[i].pair, p.runs[i + 1].pair);
    assert.notEqual(p.runs[i].mode, p.runs[i + 1].mode);
  }
  assert.equal(auditReports(p, reports(p)).rows.filter(row => row.appPassed).length, 12);
});
test('refuses changed schedule/configuration and incomplete or surplus report sets', () => {
  for (const mutate of [p => p.runs.reverse(), p => p.pauseSeconds++, p => p.runs[0].mode = 'on']) {
    const p = plan(); const r = reports(p); mutate(p);
    assert.throws(() => auditReports(p, r), /Plan differs/);
  }
  const p = plan(); const r = reports(p); delete r[p.runs[0].name];
  assert.throws(() => auditReports(p, r), /Missing or unexpected/);
  const extra = reports(p); extra.replacement = extra[p.runs[0].name];
  assert.throws(() => auditReports(p, extra), /Missing or unexpected/);
});
test('refuses absent/wrong cache modes, wrong arm and mismatched workload', () => {
  const p = plan();
  for (const [key, value] of [['textCache', undefined], ['textCache', 'off'], ['textCache', true], ['arm', 'A'], ['seed', 2], ['windows', 4], ['loadSeconds', 40]]) {
    const r = reports(p); r[p.runs[0].name].config[key] = value;
    assert.throws(() => auditReports(p, r), /mismatch/);
  }
});
test('retains failed and incomplete application runs without replacing them', () => {
  const p = plan(); const r = reports(p);
  r[p.runs[0].name].passed = false; r[p.runs[0].name].problems = ['checksum failure'];
  r[p.runs[1].name].totals.completedSteps--;
  r[p.runs[2].name].totals.overruns = 1;
  const audit = auditReports(p, r);
  assert.equal(audit.rows.length, 12);
  assert.equal(audit.rows.filter(row => !row.appPassed).length, 3);
  assert.ok(audit.rows[0].problems.includes('checksum failure'));
});

test('does not accept successful totals with missing or contradictory window evidence', () => {
  const p = plan();
  for (const mutate of [
    r => { delete r.windows.w1; },
    r => { r.windows.w1.windowIndex = 0; },
    r => { r.windows.w1.load.mismatches = 1; },
    r => { r.windows.w1.warmup.failures = 1; },
    r => { r.windows.w1.passed = false; },
    r => { r.problems = ['unacknowledged failure']; },
    r => { delete r.problems; },
  ]) {
    const r = reports(p); mutate(r[p.runs[0].name]);
    const row = auditReports(p, r).rows[0];
    assert.equal(row.appPassed, false);
    assert.ok(row.problems.length > 0);
  }
});

test('CLI never overwrites an output and rejects a modified plan before writing an audit', () => {
  const dir = mkdtempSync(join(tmpdir(), 'tmwr-text-plan-'));
  const output = join(dir, 'plan.json');
  const tool = fileURLToPath(new URL('./TextCacheDiagnostic.mjs', import.meta.url));
  const invoke = args => spawnSync(process.execPath, [tool, ...args], { encoding: 'utf8' });
  const prepare = ['prepare', '--scenario-revision', 'a'.repeat(40), '--executable-sha256', 'b'.repeat(64), '--out', output];
  assert.equal(invoke(prepare).status, 0);
  const original = readFileSync(output);
  assert.notEqual(invoke(prepare).status, 0);
  assert.deepEqual(readFileSync(output), original);
  // Deliberately invalid digest; report directory is never read on failure.
  const audit = invoke(['audit', '--plan', output, '--plan-sha256', '0'.repeat(64), '--reports-directory', join(dir, 'absent'), '--out', join(dir, 'audit.json')]);
  assert.notEqual(audit.status, 0);
  assert.match(audit.stderr, /Plan SHA-256 mismatch/);
  // Preserve the small fixture for diagnosis, avoiding recursive deletion.
  writeFileSync(join(dir, 'fixture-note.txt'), 'Offline unit-test fixture; no app was started.\n');
});
