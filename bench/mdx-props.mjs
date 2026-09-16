#!/usr/bin/env node
/**
 * Turns summary.json into the prop blocks the report's MDX components take,
 * so no number is retyped by hand between the measurement and the page.
 *
 *   node bench/mdx-props.mjs <stamp>
 */
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const stamp = process.argv[2];
if (!stamp) {
  console.error('usage: node bench/mdx-props.mjs <stamp>');
  process.exit(1);
}
const { rate, ceiling } = JSON.parse(readFileSync(join(process.cwd(), 'results', stamp, 'summary.json'), 'utf8'));

const ORDER = ['go', 'frankenphp', 'fpm'];
const LABEL = { go: 'Go', frankenphp: 'FrankenPHP (worker)', fpm: 'PHP-FPM' };
const SCEN = { auth: 'Yalnız token doğrulama', read: 'Doğrulama + okuma', write: 'Doğrulama + yazma' };
const SCENARIOS = ['auth', 'read', 'write'];

const trNum = (n, d = 0) =>
  n == null ? '—' : n.toLocaleString('tr-TR', { minimumFractionDigits: d, maximumFractionDigits: d });
const arr = (xs) => `[${xs.map((x) => (x == null ? 'null' : x)).join(', ')}]`;
const strArr = (xs) => `[${xs.map((x) => `'${x}'`).join(', ')}]`;
const find = (rows, c, s) => rows.find((r) => r.candidate === c && r.scenario === s);
const series = (rows, f, round = (x) => x) =>
  ORDER.map((c) => `    { label: '${LABEL[c]}', data: ${arr(SCENARIOS.map((s) => round(f(find(rows, c, s)))))} },`).join('\n');

console.log('/* ---- ceiling: best clean rps per scenario ---- */');
console.log(`labels={${strArr(SCENARIOS.map((s) => SCEN[s]))}}
series={[
${series(ceiling, (r) => r?.rps)}
]}`);

console.log('\n/* ---- rate phase: achieved rate vs target ---- */');
console.log(`targets: ${SCENARIOS.map((s) => `${s}=${find(rate, 'go', s)?.target}`).join(' ')}`);
console.log(`series={[
${series(rate, (r) => r?.achieved)}
]}`);

console.log('\n/* ---- rate phase: app CPU microseconds per request ---- */');
console.log(`series={[
${series(rate, (r) => r?.cpuMsPerReq, (x) => (x == null ? null : Math.round(x * 1000)))}
]}`);

console.log('\n/* ---- rate phase: app cores in use ---- */');
console.log(`series={[
${series(rate, (r) => r?.avgCores)}
]}`);

console.log('\n/* ---- peak RSS (MiB), rate phase ---- */');
console.log(`series={[
${series(rate, (r) => r?.rssPeakMiB, (x) => (x == null ? null : Math.round(x)))}
]}`);

console.log('\n/* ---- rate matrix ---- */');
console.log(`rows={[`);
for (const s of SCENARIOS) {
  for (const c of ORDER) {
    const r = find(rate, c, s);
    if (!r) continue;
    const met = r.metTarget === r.repetitions ? 'evet' : r.metTarget === 0 ? 'hayır' : `${r.metTarget}/${r.repetitions}`;
    const lat = r.metTarget === r.repetitions ? [trNum(r.p50, 2), trNum(r.p99, 2)] : ['kuyruk', 'kuyruk'];
    console.log(`    { label: '${SCEN[s]} · ${LABEL[c]}', cells: ['${trNum(r.target)}', '${trNum(r.achieved)}', '${met}', '${lat[0]}', '${lat[1]}', '${trNum(r.avgCores, 2)}', '${trNum(r.cpuMsPerReq * 1000)}', '${trNum(r.dbAvgCores, 2)}', '${trNum(r.rssPeakMiB)}'] },`);
  }
}
console.log(`]}`);

console.log('\n/* ---- ceiling matrix ---- */');
console.log(`rows={[`);
for (const s of SCENARIOS) {
  for (const c of ORDER) {
    const r = find(ceiling, c, s);
    if (!r) continue;
    console.log(`    { label: '${SCEN[s]} · ${LABEL[c]}', cells: ['${trNum(r.rps)}', '${trNum(r.rpsMedian)}', '${r.connections}', '${trNum(r.p99, 2)}', '${trNum(r.avgCores, 2)}', '${trNum(r.reqPerCpuSecond)}', '${trNum(r.rssPeakMiB)}'] },`);
  }
}
console.log(`]}`);
