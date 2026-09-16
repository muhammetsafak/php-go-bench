#!/usr/bin/env node
/**
 * Turns raw oha JSON and cgroup samples into the numbers the report quotes.
 *
 *   node bench/report.mjs <stamp>
 *
 * Throughput is counted, not read: `achieved` is the number of 2xx answers
 * divided by the nominal window. oha's own requestsPerSec divides by the real
 * elapsed time, which grows when stragglers are waited for, and would credit a
 * candidate that answered late with a lower but "cleaner" rate.
 *
 * Estimators:
 *   rate phase    the target is fixed, so the question is how each repetition
 *                 behaved at it: every figure is the MEDIAN of the repetitions,
 *                 with min and max published beside it
 *   ceiling phase capacity on a laptop that cannot be quiesced: interference
 *                 only ever subtracts, so the BEST repetition is the estimator
 *                 (as in php-framework-bench); median and spread sit beside it;
 *                 latency and CPU come from that same best repetition
 *
 * CPU comes from the cgroup usage counter sampled around each run:
 *   cpuMsPerReq   app CPU time divided by requests answered — the "same work,
 *                 fewer resources" figure; the idle seconds around the window
 *                 add (next to) nothing to the counter
 *   avgCores      app CPU seconds divided by the nominal window
 *   rssPeakMiB    peak anonymous memory of the app container
 */
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const stamp = process.argv[2];
if (!stamp) {
  console.error('usage: node bench/report.mjs <stamp>');
  process.exit(1);
}
const dir = join(process.cwd(), 'results', stamp);
const rawDir = join(dir, 'raw');
const meta = JSON.parse(readFileSync(join(dir, 'meta.json'), 'utf8'));
const cfg = meta.config;

const seconds = (d) => {
  const m = /^(\d+(?:\.\d+)?)(ms|s|m)$/.exec(d);
  if (!m) throw new Error(`bad duration ${d}`);
  return +m[1] * { ms: 0.001, s: 1, m: 60 }[m[2]];
};
const RATE_S = seconds(meta.effective.rateDuration);
const CEIL_S = seconds(meta.effective.ceilingDuration);
const PROBE_S = seconds(meta.effective.probeDuration ?? cfg.probe.duration);

const median = (xs) => {
  const s = xs.filter((x) => x != null).sort((a, b) => a - b);
  if (!s.length) return null;
  const mid = s.length >> 1;
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
};
const min = (xs) => (xs.length ? Math.min(...xs) : null);
const max = (xs) => (xs.length ? Math.max(...xs) : null);
const round = (x, d = 0) => (x == null ? null : Math.round(x * 10 ** d) / 10 ** d);
const ms = (s) => (s == null ? null : round(s * 1000, 2));

const readJson = (name) => {
  try { return JSON.parse(readFileSync(join(rawDir, name), 'utf8')); } catch { return null; }
};
const readSamples = (name) => {
  try {
    return readFileSync(join(rawDir, name), 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
  } catch { return []; }
};

function resources(stem, answered, windowS) {
  const s = readSamples(`${stem}.res.jsonl`);
  if (s.length < 2) return { samples: s.length };
  const first = s[0];
  const last = s[s.length - 1];
  const appCpuS = (last.app_cpu - first.app_cpu) / 1e6;
  const dbCpuS = (last.db_cpu - first.db_cpu) / 1e6;
  let peakCores = 0;
  for (let i = 1; i < s.length; i++) {
    const dt = (s[i].t - s[i - 1].t) / 1e9;
    if (dt > 0) peakCores = Math.max(peakCores, (s[i].app_cpu - s[i - 1].app_cpu) / 1e6 / dt);
  }
  return {
    samples: s.length,
    appCpuSeconds: round(appCpuS, 2),
    dbCpuSeconds: round(dbCpuS, 2),
    avgCores: round(appCpuS / windowS, 2),
    peakCores: round(peakCores, 2),
    dbAvgCores: round(dbCpuS / windowS, 2),
    cpuMsPerReq: answered ? round((appCpuS * 1000) / answered, 4) : null,
    dbCpuMsPerReq: answered ? round((dbCpuS * 1000) / answered, 4) : null,
    reqPerCpuSecond: appCpuS > 0 ? round(answered / appCpuS) : null,
    rssPeakMiB: round(Math.max(...s.map((x) => x.app_anon)) / 2 ** 20, 1),
    memPeakMiB: round(Math.max(...s.map((x) => x.app_mem)) / 2 ** 20, 1),
  };
}

function parseRun(name, windowS) {
  const json = readJson(name);
  if (!json?.summary) return { broken: true };
  const codes = json.statusCodeDistribution ?? {};
  let ok = 0;
  let non2xx = 0;
  for (const [code, n] of Object.entries(codes)) (code.startsWith('2') ? (ok += n) : (non2xx += n));
  const errors = Object.values(json.errorDistribution ?? {}).reduce((a, b) => a + b, 0);
  const lp = json.latencyPercentiles ?? {};
  return {
    ok,
    non2xx,
    errors,
    failRate: ok + non2xx + errors ? (non2xx + errors) / (ok + non2xx + errors) : 0,
    achieved: ok / windowS,
    elapsed: json.summary.total,
    p50: ms(lp.p50),
    p90: ms(lp.p90),
    p99: ms(lp.p99),
    p999: ms(lp['p99.9']),
    max: ms(json.summary.slowest),
    ...resources(name.replace(/\.json$/, ''), ok + non2xx, windowS),
  };
}

const RATE = /^rate_([a-z]+)_([a-z]+)_q(\d+)_r(\d+)\.json$/;
const CEIL = /^ceil_([a-z]+)_([a-z]+)_c(\d+)_r(\d+)\.json$/;
const PROBE = /^probe-(rate|ceil)_(rate|ceil)_([a-z]+)_r(\d+)\.json$/;

const rateRuns = [];
const ceilRuns = [];
const probes = [];
for (const name of readdirSync(rawDir).sort()) {
  let m;
  if ((m = RATE.exec(name))) {
    rateRuns.push({ candidate: m[1], scenario: m[2], target: +m[3], rep: +m[4], ...parseRun(name, RATE_S) });
  } else if ((m = CEIL.exec(name))) {
    ceilRuns.push({ candidate: m[1], scenario: m[2], connections: +m[3], rep: +m[4], ...parseRun(name, CEIL_S) });
  } else if ((m = PROBE.exec(name))) {
    const j = readJson(name);
    const ok = j ? Object.entries(j.statusCodeDistribution ?? {}).filter(([c]) => c.startsWith('2')).reduce((a, [, n]) => a + n, 0) : 0;
    probes.push({ kind: m[1], phase: m[2], candidate: m[3], rep: +m[4], rps: j ? round(ok / PROBE_S) : null, p99: ms(j?.latencyPercentiles?.p99) });
  }
}

const candidates = cfg.candidates;
const scenarios = cfg.scenarios.map((s) => s.id);
const pick = (runs, f) => runs.map(f).filter((x) => x != null);
const MET_TOLERANCE = 0.99;
const MAX_FAIL_RATE = 0.001;

const rate = [];
for (const candidate of candidates) {
  for (const scenario of scenarios) {
    const runs = rateRuns.filter((r) => r.candidate === candidate && r.scenario === scenario && !r.broken);
    if (!runs.length) continue;
    const target = runs[0].target;
    const met = runs.filter((r) => r.achieved >= target * MET_TOLERANCE && r.failRate <= MAX_FAIL_RATE).length;
    rate.push({
      candidate,
      scenario,
      target,
      repetitions: runs.length,
      metTarget: met,
      achieved: round(median(pick(runs, (r) => r.achieved))),
      achievedMin: round(min(pick(runs, (r) => r.achieved))),
      achievedMax: round(max(pick(runs, (r) => r.achieved))),
      achievedPct: round((median(pick(runs, (r) => r.achieved)) / target) * 100, 1),
      p50: round(median(pick(runs, (r) => r.p50)), 2),
      p99: round(median(pick(runs, (r) => r.p99)), 2),
      p99Min: min(pick(runs, (r) => r.p99)),
      p99Max: max(pick(runs, (r) => r.p99)),
      p999: round(median(pick(runs, (r) => r.p999)), 2),
      failed: pick(runs, (r) => r.non2xx + r.errors).reduce((a, b) => a + b, 0),
      avgCores: round(median(pick(runs, (r) => r.avgCores)), 2),
      peakCores: round(median(pick(runs, (r) => r.peakCores)), 2),
      cpuMsPerReq: round(median(pick(runs, (r) => r.cpuMsPerReq)), 4),
      dbAvgCores: round(median(pick(runs, (r) => r.dbAvgCores)), 2),
      dbCpuMsPerReq: round(median(pick(runs, (r) => r.dbCpuMsPerReq)), 4),
      rssPeakMiB: round(max(pick(runs, (r) => r.rssPeakMiB)), 1),
    });
  }
}

const ceilingCells = [];
for (const candidate of candidates) {
  for (const scenario of scenarios) {
    for (const connections of [...new Set(ceilRuns.map((r) => r.connections))].sort((a, b) => a - b)) {
      const runs = ceilRuns.filter((r) => r.candidate === candidate && r.scenario === scenario && r.connections === connections && !r.broken);
      if (!runs.length) continue;
      const best = runs.reduce((a, b) => (b.achieved > a.achieved ? b : a));
      const med = median(pick(runs, (r) => r.achieved));
      ceilingCells.push({
        candidate,
        scenario,
        connections,
        repetitions: runs.length,
        rps: round(best.achieved),
        rpsMedian: round(med),
        spreadPct: best.achieved ? round(((best.achieved - med) / best.achieved) * 100, 1) : null,
        p50: best.p50,
        p99: best.p99,
        failed: best.non2xx + best.errors,
        avgCores: best.avgCores,
        cpuMsPerReq: best.cpuMsPerReq,
        reqPerCpuSecond: best.reqPerCpuSecond,
        dbAvgCores: best.dbAvgCores,
        rssPeakMiB: best.rssPeakMiB,
      });
    }
  }
}

const ceiling = [];
for (const candidate of candidates) {
  for (const scenario of scenarios) {
    const cells = ceilingCells.filter((c) => c.candidate === candidate && c.scenario === scenario && c.failed === 0);
    if (!cells.length) continue;
    const top = cells.reduce((a, b) => (b.rps > a.rps ? b : a));
    ceiling.push({ ...top, bestAtConnections: top.connections });
  }
}

const probeSummary = {};
for (const kind of ['rate', 'ceil']) {
  const xs = pick(probes.filter((p) => p.kind === kind), (p) => p.rps);
  probeSummary[kind] = { n: xs.length, min: min(xs), median: round(median(xs)), max: max(xs) };
}

const anomalies = readFileSync(join(dir, 'anomalies.jsonl'), 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));

const summary = {
  stamp,
  generated: new Date().toISOString(),
  estimator: {
    rate: 'median of repetitions (min/max beside it); achieved = 2xx answers / nominal window',
    ceiling: 'best of N repetitions per connection count, median and spread beside it; ceiling = best clean cell over the sweep',
    metTarget: `achieved >= ${MET_TOLERANCE * 100}% of target and failed <= ${MAX_FAIL_RATE * 100}% of requests`,
  },
  meta,
  probe: probeSummary,
  rate,
  ceiling,
  ceilingCells,
  anomalies: anomalies.length,
  runs: { rate: rateRuns, ceiling: ceilRuns, probes },
};
writeFileSync(join(dir, 'summary.json'), JSON.stringify(summary, null, 2) + '\n');

const csvRows = [
  ['phase', 'candidate', 'scenario', 'target_or_connections', 'repetitions', 'rps', 'rps_median_or_min', 'p50_ms', 'p99_ms', 'p999_ms', 'failed', 'avg_cores', 'cpu_ms_per_req', 'db_avg_cores', 'rss_peak_mib', 'met_target'],
  ...rate.map((r) => ['rate', r.candidate, r.scenario, r.target, r.repetitions, r.achieved, r.achievedMin, r.p50, r.p99, r.p999, r.failed, r.avgCores, r.cpuMsPerReq, r.dbAvgCores, r.rssPeakMiB, `${r.metTarget}/${r.repetitions}`]),
  ...ceilingCells.map((c) => ['ceiling', c.candidate, c.scenario, c.connections, c.repetitions, c.rps, c.rpsMedian, c.p50, c.p99, '', c.failed, c.avgCores, c.cpuMsPerReq, c.dbAvgCores, c.rssPeakMiB, '']),
];
writeFileSync(join(dir, 'summary.csv'), csvRows.map((r) => r.join(',')).join('\n') + '\n');

const pad = (x, n) => String(x ?? '–').padStart(n);
console.log(`\n${stamp} — probe at-rate min ${probeSummary.rate.min}/s, flat-out min ${probeSummary.ceil.min}/s, anomalies ${anomalies.length}\n`);
console.log('RATE          scenario  target   achieved   met   p50ms   p99ms  p999ms  cores  cpu-ms/req  db-cores  rssMiB');
for (const r of rate) {
  console.log(`${r.candidate.padEnd(12)}  ${r.scenario.padEnd(8)} ${pad(r.target, 7)} ${pad(r.achieved, 10)} ${pad(`${r.metTarget}/${r.repetitions}`, 5)} ${pad(r.p50, 7)} ${pad(r.p99, 7)} ${pad(r.p999, 7)} ${pad(r.avgCores, 6)} ${pad(r.cpuMsPerReq, 11)} ${pad(r.dbAvgCores, 9)} ${pad(r.rssPeakMiB, 7)}`);
}
console.log('\nCEILING       scenario  conns      rps   median  p50ms   p99ms  cores  cpu-ms/req  req/cpu-s  db-cores  rssMiB');
for (const c of ceiling) {
  console.log(`${c.candidate.padEnd(12)}  ${c.scenario.padEnd(8)} ${pad(c.connections, 6)} ${pad(c.rps, 8)} ${pad(c.rpsMedian, 8)} ${pad(c.p50, 6)} ${pad(c.p99, 7)} ${pad(c.avgCores, 6)} ${pad(c.cpuMsPerReq, 11)} ${pad(c.reqPerCpuSecond, 10)} ${pad(c.dbAvgCores, 9)} ${pad(c.rssPeakMiB, 7)}`);
}
