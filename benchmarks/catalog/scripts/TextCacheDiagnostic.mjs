// Offline preparation/application-report audit only. Never starts an app.
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { isDeepStrictEqual } from 'node:util';

export function createPlan(scenarioRevision, executableSha256) {
  if (!/^[a-f0-9]{40}$/.test(scenarioRevision ?? '')) throw new Error('A full lowercase scenario SHA is required');
  if (!/^[a-f0-9]{64}$/.test(executableSha256 ?? '')) throw new Error('A lowercase executable SHA-256 is required');
  const pairs = [['N2D16', 'off'], ['N4D64', 'on'], ['N2D16', 'on'], ['N4D64', 'off'], ['N2D16', 'off'], ['N4D64', 'on']];
  return {
    kind: 'text-cache-diagnostic', version: 1, scenarioRevision, executableSha256,
    arm: 'C', seed: 1, stepIntervalMs: 500, idleBeforeSeconds: 20,
    warmupSeconds: 30, loadSeconds: 120, idleAfterSeconds: 30, pauseSeconds: 30,
    runs: pairs.flatMap(([cell, first], index) => [first, first === 'off' ? 'on' : 'off'].map((mode, position) => ({
      seq: index * 2 + position + 1, pair: index + 1, cell, mode,
      name: `${cell}-pair${index + 1}-${mode}`,
    }))),
  };
}

export function auditReports(plan, reports) {
  if (!isDeepStrictEqual(plan, createPlan(plan?.scenarioRevision, plan?.executableSha256))) {
    throw new Error('Plan differs from the reviewed diagnostic schedule or configuration');
  }
  const expectedNames = plan.runs.map(run => run.name).sort();
  if (!isDeepStrictEqual(Object.keys(reports).sort(), expectedNames)) throw new Error('Missing or unexpected report names');
  const rows = plan.runs.map(run => {
    const report = reports[run.name];
    const config = report?.config;
    const windows = run.cell === 'N2D16' ? 2 : 4;
    const expected = { scenario: 'M', arm: 'C', windows, dataMib: run.cell === 'N2D16' ? 16 : 64,
      seed: plan.seed, stepIntervalMs: plan.stepIntervalMs, idleBeforeSeconds: plan.idleBeforeSeconds,
      warmupSeconds: plan.warmupSeconds, loadSeconds: plan.loadSeconds, idleAfterSeconds: plan.idleAfterSeconds,
      textCache: run.mode === 'on', automated: true };
    if (report?.schemaVersion !== 1 || report?.scenario !== 'M') throw new Error(`${run.name}: report schema/scenario mismatch`);
    for (const [key, value] of Object.entries(expected)) {
      if (config?.[key] !== value) throw new Error(`${run.name}: config.${key} mismatch`);
    }
    if (typeof report.passed !== 'boolean') throw new Error(`${run.name}: missing application pass flag`);
    const total = report.totals;
    const scheduled = windows * plan.loadSeconds * 1000 / plan.stepIntervalMs;
    const appPassed = report.passed && total?.scheduledSteps === scheduled && total?.completedSteps === scheduled
      && total?.failures === 0 && total?.mismatches === 0 && total?.overruns === 0;
    return { ...run, appPassed, problems: Array.isArray(report.problems) ? report.problems : [] };
  });
  return { kind: 'text-cache-application-audit', scenarioRevision: plan.scenarioRevision,
    executableSha256: plan.executableSha256, rows,
    limitation: 'Application configuration/correctness audit only. Does not verify actual executable bytes, environment, monitor validity, RAM or CPU. No performance conclusion.' };
}

function main(args) {
  const command = args.shift();
  const allowed = command === 'prepare' ? ['scenario-revision', 'executable-sha256', 'out']
    : command === 'audit' ? ['plan', 'plan-sha256', 'reports-directory', 'out'] : [];
  if (!allowed.length) throw new Error('Use prepare or audit; this tool never launches applications');
  const options = {};
  while (args.length) {
    const option = args.shift();
    if (!option.startsWith('--')) throw new Error(`Expected --option, got ${option}`);
    const key = option.slice(2);
    if (!allowed.includes(key) || Object.hasOwn(options, key) || !args.length) throw new Error(`Invalid/duplicate option: ${key}`);
    options[key] = args.shift();
  }
  if (allowed.some(key => !options[key])) throw new Error(`Required: ${allowed.map(key => `--${key}`).join(' ')}`);
  let result;
  if (command === 'prepare') result = createPlan(options['scenario-revision'], options['executable-sha256']);
  else {
    const bytes = readFileSync(options.plan);
    const actual = createHash('sha256').update(bytes).digest('hex');
    if (actual !== options['plan-sha256']) throw new Error('Plan SHA-256 mismatch');
    const reports = Object.fromEntries(readdirSync(options['reports-directory']).filter(name => name.endsWith('.json'))
      .map(name => [name.slice(0, -5), JSON.parse(readFileSync(join(options['reports-directory'], name), 'utf8'))]));
    result = auditReports(JSON.parse(bytes.toString('utf8')), reports);
  }
  const content = JSON.stringify(result, null, 2) + '\n';
  writeFileSync(options.out, content, { encoding: 'utf8', flag: 'wx' });
  console.log(`Written ${resolve(options.out)}; SHA-256 ${createHash('sha256').update(content).digest('hex')}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try { main(process.argv.slice(2)); } catch (error) { console.error(error.message); process.exitCode = 1; }
}
