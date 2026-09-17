#!/usr/bin/env node
/**
 * Turns the capacity run into the numbers a capacity plan needs.
 *
 *   node bench/capacity-report.mjs <stamp>     # results/capacity-<stamp>
 *
 * The orchestrator only measures; every figure below is derived here, from
 * steps.jsonl (one line per measured point), tuning.jsonl and the raw oha
 * output. Nothing is read back from the log.
 *
 * Estimators, and why each one:
 *
 *   capacity     the MEDIAN of the repetitions. The search inside one
 *                repetition already takes the highest rate that held, so the
 *                repetitions differ only by how the host behaved; the median
 *                is the one that is not decided by the worst or the best
 *                night. min and max sit beside it.
 *   the point    the numbers that describe capacity — p99, CPU per request,
 *                cores in use, memory — come from the measured step AT that
 *                capacity in the repetition that produced the median, not
 *                from an average over the ladder. A figure from a rate the
 *                candidate was never asked to hold describes nothing.
 *   floor, ceil  BEST of the repetitions, as in bench/report.mjs: both are
 *                upper bounds measured on a laptop that cannot be quiesced,
 *                and interference only ever subtracts.
 *   soak         the first window is dropped. It carries the cost of a pool
 *                that has just opened; every other window is the service in
 *                its normal state.
 *
 * CPU per request is the cgroup counter delta divided by answers, so the
 * one-second sampling interval cannot bias it. It is the figure that
 * multiplies: target rate x CPU per request = cores.
 */
import { readdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const stamp = process.argv[2];
if (!stamp) {
  console.error('usage: node bench/capacity-report.mjs <stamp>');
  process.exit(1);
}
const dir = join(process.cwd(), 'results', `capacity-${stamp}`);
const rawDir = join(dir, 'raw');
const meta = JSON.parse(readFileSync(join(dir, 'meta.json'), 'utf8'));
const cfg = meta.config;

/* The orchestrator appends whole JSON values; whether jq wrapped them over
   several lines is not something a reader should care about. */
const lines = (f) => {
  if (!existsSync(join(dir, f))) return [];
  const out = [];
  let buf = '';
  for (const line of readFileSync(join(dir, f), 'utf8').split('\n')) {
    if (!line.trim()) continue;
    buf += line;
    try { out.push(JSON.parse(buf)); buf = ''; } catch { buf += '\n'; }
  }
  if (buf.trim()) throw new Error(`${f}: trailing text that is not a JSON value`);
  return out;
};

const steps = lines('steps.jsonl');
const tuning = lines('tuning.jsonl');
const events = lines('events.jsonl');

const round = (x, d = 0) => (x == null || Number.isNaN(x) ? null : Math.round(x * 10 ** d) / 10 ** d);
const sorted = (xs) => xs.filter((x) => x != null).sort((a, b) => a - b);
const median = (xs) => {
  const s = sorted(xs);
  if (!s.length) return null;
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
};
const min = (xs) => (sorted(xs).length ? sorted(xs)[0] : null);
const max = (xs) => (sorted(xs).length ? sorted(xs)[sorted(xs).length - 1] : null);
const MiB = (b) => round(b / 2 ** 20, 1);

const candidates = cfg.candidates;
const coreBudgets = cfg.cores;
const seconds = (d) => +String(d).replace(/s$/, '');

/* ---------------------------------------------------------------- capacity */

const grid = steps.filter((s) => s.phase === 'grid');
const cellCeil = steps.filter((s) => s.phase === 'cellceiling');

const worst = (p, field) => Math.max(p.read[field] ?? 0, p.write[field] ?? 0);

const describe = (p) => {
  if (!p) return {};
  const answered = p.read.ok + p.write.ok;
  const w = p.durationSec;
  return {
    readP50Ms: p.read.p50ms, readP99Ms: p.read.p99ms,
    writeP50Ms: p.write.p50ms, writeP99Ms: p.write.p99ms,
    serverP99Ms: worst(p, 'fb99ms'),
    cpuUsPerReq: p.cpuUsPerReq,
    dbCpuUsPerReq: p.dbCpuUsPerReq,
    appCores: round(p.resources.appCpuUs / 1e6 / w, 2),
    dbCores: round(p.resources.dbCpuUs / 1e6 / w, 2),
    rssPeakMiB: MiB(p.resources.appAnonPeak),
    answered,
    reqPerCpuSecond: p.resources.appCpuUs > 0 ? round(answered / (p.resources.appCpuUs / 1e6)) : null,
  };
};

/* One row per rate per cell: what the repetitions said, and how they voted.
   A rate is carried when a majority of the repetitions met the service level
   at it — not when the best one did, and not when the median latency did. */
const curves = [];
const capacity = [];
for (const candidate of candidates) {
  for (const cores of coreBudgets) {
    const cell = grid.filter((s) => s.candidate === candidate && s.cores === cores);
    if (!cell.length) continue;
    const rates = [...new Set(cell.map((s) => s.targetRate))].sort((a, b) => a - b);
    const curve = rates.map((rate) => {
      const at = cell.filter((s) => s.targetRate === rate);
      const passed = at.filter((s) => s.pass).length;
      return {
        candidate, cores, rate,
        repetitions: at.length,
        passed,
        carried: passed * 2 > at.length,
        achieved: round(median(at.map((s) => s.achievedTotal))),
        clientP99Ms: round(median(at.map((s) => worst(s, 'p99ms'))), 2),
        serverP99Ms: round(median(at.map((s) => worst(s, 'fb99ms'))), 2),
        p50Ms: round(median(at.map((s) => Math.max(s.read.p50ms, s.write.p50ms))), 2),
        cpuUsPerReq: round(median(at.map((s) => s.cpuUsPerReq)), 2),
        dbCpuUsPerReq: round(median(at.map((s) => s.dbCpuUsPerReq)), 2),
        appCores: round(median(at.map((s) => s.resources.appCpuUs / 1e6 / s.durationSec)), 2),
        failedOn: [...new Set(at.flatMap((s) => s.failedOn ?? []))],
      };
    });
    curves.push(...curve);

    const carried = curve.filter((c) => c.carried);
    const cap = carried.length ? Math.max(...carried.map((c) => c.rate)) : 0;
    const above = curve.filter((c) => c.rate > cap && !c.carried);
    /* The operating point is described by the repetition at that rate which
       actually met the service level — a window that did not is describing
       something else. */
    const at = cell.filter((s) => s.targetRate === cap);
    const point = at.find((s) => s.pass) ?? at[0];
    const ceilRows = cellCeil.filter((s) => s.candidate === candidate && s.cores === cores);

    capacity.push({
      candidate, cores,
      workers: cell[0].workers,
      repetitions: [...new Set(cell.map((s) => s.rep))].length,
      capacity: cap,
      unanimous: carried.length ? curve.find((c) => c.rate === cap).passed === curve.find((c) => c.rate === cap).repetitions : null,
      firstRateNotCarried: above.length ? Math.min(...above.map((c) => c.rate)) : null,
      perCore: cores ? round(cap / cores) : null,
      flatOutRps: ceilRows.length ? max(ceilRows.map((r) => r.totalRps)) : null,
      headroomPct: cap && ceilRows.length ? round((cap / max(ceilRows.map((r) => r.totalRps))) * 100, 1) : null,
      ...describe(point),
    });
  }
}

const cap = (candidate, cores) => capacity.find((c) => c.candidate === candidate && c.cores === cores);

/* How the curve bends: is a fourth core worth as much as the first? */
const scaling = candidates.map((candidate) => {
  const one = cap(candidate, 1)?.capacity;
  const oneFlat = cap(candidate, 1)?.flatOutRps;
  const row = { candidate, base: one };
  for (const cores of coreBudgets) {
    const c = cap(candidate, cores);
    row[`c${cores}`] = c?.capacity ?? null;
    row[`c${cores}Flat`] = c?.flatOutRps ?? null;
    row[`c${cores}PerCore`] = c?.perCore ?? null;
    row[`c${cores}Efficiency`] = one && c?.capacity ? round(c.capacity / (one * cores), 3) : null;
    row[`c${cores}FlatEfficiency`] = oneFlat && c?.flatOutRps ? round(c.flatOutRps / (oneFlat * cores), 3) : null;
  }
  return row;
});

/* What a target costs. Instances, not fractions of a core: you buy machines. */
const TARGETS = [10000, 20000, 30000, 50000, 100000];
const plan = [];
for (const target of TARGETS) {
  for (const cores of coreBudgets) {
    const row = { target, instanceCores: cores };
    for (const candidate of candidates) {
      const c = cap(candidate, cores);
      row[candidate] = c?.capacity ? Math.ceil(target / c.capacity) : null;
      row[`${candidate}Cores`] = c?.capacity ? Math.ceil(target / c.capacity) * cores : null;
    }
    plan.push(row);
  }
}

/* --------------------------------------------------------------- reference */

const floorRuns = [];
const FLOOR = /^floor_c(\d+)_(rate|flat)_r(\d+)\.(read|write)\.json$/;
if (existsSync(rawDir)) {
  for (const name of readdirSync(rawDir).sort()) {
    const m = FLOOR.exec(name);
    if (!m) continue;
    let j;
    try { j = JSON.parse(readFileSync(join(rawDir, name), 'utf8')); } catch { continue; }
    const ok = Object.entries(j.statusCodeDistribution ?? {})
      .filter(([c]) => c.startsWith('2')).reduce((a, [, n]) => a + n, 0);
    floorRuns.push({
      cores: +m[1], kind: m[2], rep: +m[3], half: m[4],
      rps: round(ok / seconds(cfg.floor.duration)),
      p99Ms: round((j.latencyPercentiles?.p99 ?? 0) * 1000, 2),
    });
  }
}
const floor = [];
for (const cores of coreBudgets) {
  for (const kind of ['rate', 'flat']) {
    const reps = [...new Set(floorRuns.filter((f) => f.cores === cores && f.kind === kind).map((f) => f.rep))];
    const totals = reps.map((rep) =>
      floorRuns.filter((f) => f.cores === cores && f.kind === kind && f.rep === rep)
        .reduce((a, b) => a + b.rps, 0));
    if (!totals.length) continue;
    floor.push({
      cores, kind,
      totalRps: kind === 'flat' ? max(totals) : median(totals),
      repetitions: totals.length,
      p99Ms: max(floorRuns.filter((f) => f.cores === cores && f.kind === kind).map((f) => f.p99Ms)),
    });
  }
}

const dbCeilRows = steps.filter((s) => s.phase === 'dbceiling');
const dbCeiling = [...new Set(dbCeilRows.map((r) => r.clients))].sort((a, b) => a - b).map((clients) => {
  const rows = dbCeilRows.filter((r) => r.clients === clients);
  const best = rows.reduce((a, b) => (b.tps > a.tps ? b : a));
  return {
    clients, repetitions: rows.length,
    tps: round(best.tps), tpsMedian: round(median(rows.map((r) => r.tps))),
    dbCores: best.dbCores,
  };
});
const dbCeilingBest = dbCeiling.length ? dbCeiling.reduce((a, b) => (b.tps > a.tps ? b : a)) : null;

/* ------------------------------------------------------------------- tuning */

const tuned = [];
for (const candidate of candidates) {
  for (const cores of coreBudgets) {
    const chosen = tuning.filter((t) => t.chosen && t.candidate === candidate && t.cores === cores).pop();
    const tried = cfg.tune.workers.map((workers) => {
      const rows = tuning.filter((t) => t.phase === 'tune' && t.candidate === candidate && t.cores === cores && t.workers === workers);
      return { workers, bestRps: max(rows.map((r) => r.totalRps)), repetitions: rows.length };
    }).filter((t) => t.bestRps != null);
    if (!tried.length) continue;
    const worst = min(tried.map((t) => t.bestRps));
    tuned.push({
      candidate, cores,
      chosen: chosen?.workers ?? null,
      chosenRps: chosen?.totalRps ?? null,
      spreadPct: worst ? round(((max(tried.map((t) => t.bestRps)) - worst) / worst) * 100, 1) : null,
      tried,
    });
  }
}

/* --------------------------------------------------------------------- soak */

const soakSteps = steps.filter((s) => s.phase === 'soak');
const soak = candidates.map((candidate) => {
  const ws = soakSteps.filter((s) => s.candidate === candidate).sort((a, b) => a.rep - b.rep);
  if (!ws.length) return null;
  const settled = ws.slice(1);                     // the first window opens the pools
  const first = settled[0];
  const last = settled[settled.length - 1];
  const rowsAdded = last?.table?.after?.liveRows != null && ws[0]?.table?.before?.liveRows != null
    ? last.table.after.liveRows - ws[0].table.before.liveRows : null;
  return {
    candidate,
    targetRate: ws[0].targetRate,
    windows: ws.length,
    windowSeconds: ws[0].durationSec,
    held: settled.filter((s) => s.pass).length,
    of: settled.length,
    firstWindowPassed: ws[0].pass,
    achievedMedian: median(settled.map((s) => s.achievedTotal)),
    readP99First: first?.read.p99ms, readP99Last: last?.read.p99ms,
    writeP99First: first?.write.p99ms, writeP99Last: last?.write.p99ms,
    readP99Max: max(settled.map((s) => s.read.p99ms)),
    writeP99Max: max(settled.map((s) => s.write.p99ms)),
    cpuUsPerReqFirst: first?.cpuUsPerReq, cpuUsPerReqLast: last?.cpuUsPerReq,
    dbCpuUsPerReqFirst: first?.dbCpuUsPerReq, dbCpuUsPerReqLast: last?.dbCpuUsPerReq,
    rssPeakMiB: MiB(max(ws.map((s) => s.resources.appAnonPeak))),
    rowsAdded,
    tableStartBytes: ws[0]?.table?.before?.totalBytes ?? null,
    tableEndBytes: last?.table?.after?.totalBytes ?? null,
    bytesPerRow: rowsAdded && last?.table?.after?.totalBytes && ws[0]?.table?.before?.totalBytes
      ? round((last.table.after.totalBytes - ws[0].table.before.totalBytes) / rowsAdded, 1) : null,
    series: ws.map((s) => ({
      window: s.rep, achieved: s.achievedTotal,
      readP99Ms: s.read.p99ms, writeP99Ms: s.write.p99ms,
      cpuUsPerReq: s.cpuUsPerReq, dbCpuUsPerReq: s.dbCpuUsPerReq,
      rows: s.table?.after?.liveRows ?? null,
      totalBytes: s.table?.after?.totalBytes ?? null,
      pass: s.pass,
    })),
  };
}).filter(Boolean);

/* --------------------------------------------------------------- integrity */

const gridFailures = grid.filter((s) => s.read.bad + s.write.bad > 0).length;
const resetDrift = grid.map((s) => s.table?.before?.liveRows).filter((x) => x != null);
const failedOn = {};
for (const s of grid.filter((x) => !x.pass)) {
  for (const why of s.failedOn ?? ['unrecorded']) failedOn[why] = (failedOn[why] ?? 0) + 1;
}
const integrity = {
  measuredPoints: grid.length + soakSteps.length,
  ratesWhereRepetitionsDisagreed: curves.filter((c) => c.passed > 0 && c.passed < c.repetitions).length,
  ratesMeasured: curves.length,
  pointsBySloBreach: failedOn,
  answers: [...grid, ...soakSteps].reduce((a, s) => a + s.read.ok + s.write.ok, 0),
  pointsWithFailedRequests: gridFailures,
  seededRowsBeforeEveryLadderStep: { min: min(resetDrift), max: max(resetDrift) },
  samplerGaps: [...ladder, ...soakSteps].filter((s) => (s.resources?.samples ?? 0) < 3).length,
  events,
};

/* ------------------------------------------------------------------ output */

const summary = {
  stamp,
  generated: new Date().toISOString(),
  question: 'An API that verifies an RS256 bearer token on every request and then reads or writes one row: how much mixed traffic does one core carry, in each runtime?',
  estimator: {
    capacity: 'the highest rate on the grid that met the service level in a majority of the repetitions',
    operatingPoint: 'the measured window at that rate which met the service level',
    latency: 'clientP99 is latency-corrected (it includes time a request was due but not yet sent); serverP99 is time to first byte. Where they part company, the generator was falling behind the schedule the service could no longer keep.',
    floorAndDbCeiling: 'best of the repetitions (upper bounds on a host that cannot be quiesced)',
    soak: 'first window dropped; it carries the cost of a pool that has just opened',
    serviceLevel: `both halves of the mix at >= ${cfg.slo.achievedFraction * 100}% of target, p99 <= ${cfg.slo.p99Ms} ms, no failed request`,
  },
  meta,
  capacity, curves, scaling, plan, tuned, floor, dbCeiling, dbCeilingBest, soak, integrity,
};
writeFileSync(join(dir, 'summary.json'), JSON.stringify(summary, null, 2) + '\n');

const csv = [
  ['candidate', 'cores', 'rate', 'repetitions', 'passed', 'carried', 'achieved', 'client_p99_ms', 'server_p99_ms', 'p50_ms', 'cpu_us_per_req', 'db_cpu_us_per_req', 'app_cores'],
  ...curves.map((c) => [c.candidate, c.cores, c.rate, c.repetitions, c.passed, c.carried, c.achieved, c.clientP99Ms, c.serverP99Ms, c.p50Ms, c.cpuUsPerReq, c.dbCpuUsPerReq, c.appCores]),
];
writeFileSync(join(dir, 'summary.csv'), csv.map((r) => r.join(',')).join('\n') + '\n');

const pad = (x, n) => String(x ?? '-').padStart(n);
const padr = (x, n) => String(x ?? '-').padEnd(n);

console.log(`\ncapacity-${stamp} — ${integrity.measuredPoints} measured points, ${integrity.answers.toLocaleString('en-US')} answers, ${integrity.pointsWithFailedRequests} with a failed request\n`);
console.log('CAPACITY      cores  pool  carried  /core  flat-out  used%  clientp99  serverp99  cpu-us/req  db-us/req  cores-used  rssMiB');
for (const c of capacity) {
  console.log(`${padr(c.candidate, 12)} ${pad(c.cores, 6)} ${pad(c.workers, 4)} ${pad(c.capacity, 8)} ${pad(c.perCore, 6)} ${pad(c.flatOutRps, 9)} ${pad(c.headroomPct, 6)} ${pad(Math.max(c.readP99Ms ?? 0, c.writeP99Ms ?? 0), 10)} ${pad(c.serverP99Ms, 10)} ${pad(c.cpuUsPerReq, 11)} ${pad(c.dbCpuUsPerReq, 10)} ${pad(c.appCores, 11)} ${pad(c.rssPeakMiB, 7)}`);
}
console.log('\nCURVE         cores    rate  votes  achieved  clientp99  serverp99  cpu-us/req  carried');
for (const c of curves) {
  console.log(`${padr(c.candidate, 12)} ${pad(c.cores, 6)} ${pad(c.rate, 7)} ${pad(`${c.passed}/${c.repetitions}`, 6)} ${pad(c.achieved, 9)} ${pad(c.clientP99Ms, 10)} ${pad(c.serverP99Ms, 10)} ${pad(c.cpuUsPerReq, 11)}  ${c.carried ? 'yes' : ''}`);
}
console.log('\nSCALING       ' + coreBudgets.map((n) => `${n}c`.padStart(8)).join('') + '   ' + coreBudgets.map((n) => `eff${n}c`.padStart(8)).join(''));
for (const s of scaling) {
  console.log(`${padr(s.candidate, 12)}  ` + coreBudgets.map((n) => pad(s[`c${n}`], 7)).join(' ') + '   ' + coreBudgets.map((n) => pad(s[`c${n}Efficiency`], 7)).join(' '));
}
console.log('\nTUNING        cores  chosen  spread%  tried (workers:rps)');
for (const t of tuned) {
  console.log(`${padr(t.candidate, 12)} ${pad(t.cores, 6)} ${pad(t.chosen, 7)} ${pad(t.spreadPct, 8)}  ${t.tried.map((x) => `${x.workers}:${x.bestRps}`).join('  ')}`);
}
console.log('\nFLOOR (no application code)        DB CEILING (pgbench, no HTTP)');
for (let i = 0; i < Math.max(floor.length, dbCeiling.length); i++) {
  const f = floor[i];
  const d = dbCeiling[i];
  console.log(`${padr(f ? `${f.cores}c ${f.kind.padEnd(4)} ${f.totalRps}/s` : '', 34)} ${d ? `${pad(d.clients, 3)} clients  ${pad(d.tps, 7)} tps  ${d.dbCores} cores` : ''}`);
}
if (soak.length) {
  console.log('\nSOAK          rate     held     achieved  p99 r/w first -> last      cpu-us/req      rows added   bytes/row');
  for (const s of soak) {
    console.log(`${padr(s.candidate, 12)} ${pad(s.targetRate, 6)}  ${pad(`${s.held}/${s.of}`, 6)} ${pad(s.achievedMedian, 10)}  ${pad(s.readP99First, 6)}/${pad(s.writeP99First, 6)} -> ${pad(s.readP99Last, 6)}/${pad(s.writeP99Last, 6)}  ${pad(s.cpuUsPerReqFirst, 6)} -> ${pad(s.cpuUsPerReqLast, 6)}  ${pad(s.rowsAdded, 10)}  ${pad(s.bytesPerRow, 9)}`);
  }
}
console.log('\nPLAN (instances of N cores needed for a target rate)');
console.log('target    cores/instance  ' + candidates.map((c) => c.padStart(12)).join(''));
for (const p of plan) {
  console.log(`${pad(p.target, 7)}   ${pad(p.instanceCores, 12)}    ` + candidates.map((c) => pad(p[c], 12)).join(''));
}
console.log('');
