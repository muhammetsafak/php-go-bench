#!/usr/bin/env bash
# Capacity run: how much mixed OAuth2 traffic one core carries.
#
# The question this answers is not "which language is faster". It is the one a
# capacity plan needs: an API that verifies an RS256 bearer token on every
# request and then reads or writes one row — how many cores does each runtime
# need to carry a given rate, and where does the rate stop being about the
# runtime at all?
#
# Differences from bench/run.sh (the 2026-09-16 run), on purpose:
#   * the load is MIXED, not one scenario at a time: two open-loop generators
#     run against the same candidate at the same instant, one reading and one
#     writing, 50/50, each with its own access token
#   * the candidate's core budget is an axis (1, 2, 4), not a constant
#   * every candidate is given its best pool size at every core budget first
#     (phase "tune"), so no result rests on a number that happened to suit one
#     of them
#   * capacity is defined by a service level, not by a saturation point: the
#     highest rate at which both halves of the mix arrive in full, under a p99
#     budget, with no failed request
#
# Phases:
#   floor      an nginx that runs no application code, on the same cores
#   dbceiling  pgbench inserting the same row with no HTTP and no token
#   tune       pool size per candidate per core budget
#   ladder     the capacity itself — exponential search, then bisection
#   soak       the winner's rate held for twenty minutes
#
#   ./bench/capacity.sh --all        every phase, in that order
#   ./bench/capacity.sh --ladder     one phase
#   ./bench/capacity.sh --smoke      a few minutes, to check the harness
#
# Everything derived lives in bench/capacity-report.mjs; this script only
# measures and records.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODE="${1:---all}"
STAMP="${STAMP:-$(date -u +%Y-%m-%d)}"
OUT="$ROOT/results/capacity-$STAMP"
RAW="$OUT/raw"
CAP=bench/capacity.json

read -r -a CANDS <<< "${CANDS:-$(jq -r '.candidates | join(" ")' $CAP)}"
read -r -a CORES <<< "${CORES:-$(jq -r '.cores | join(" ")' $CAP)}"
read -r -a TUNE_WORKERS <<< "$(jq -r '.tune.workers | join(" ")' $CAP)"
read -r -a DB_CLIENTS <<< "$(jq -r '.dbCeiling.clients | join(" ")' $CAP)"

SLO_P99=$(jq -r .slo.p99Ms $CAP)
SLO_FRAC=$(jq -r .slo.achievedFraction $CAP)

L_START=$(jq -r .ladder.startRate $CAP)
L_MAX=$(jq -r .ladder.maxRate $CAP)
L_REFINE=$(jq -r .ladder.refinements $CAP)
L_GRAIN=$(jq -r .ladder.granularity $CAP)
L_DUR="${L_DUR:-$(jq -r .ladder.duration $CAP)}"
L_CONNS=$(jq -r .ladder.connectionsPerGenerator $CAP)
L_REPS="${L_REPS:-$(jq -r .ladder.repetitions $CAP)}"
WARMUP="${WARMUP:-$(jq -r .ladder.warmupSeconds $CAP)}"
COOL=$(jq -r .ladder.cooldownSeconds $CAP)

T_DUR="${T_DUR:-$(jq -r .tune.duration $CAP)}"
T_CONNS=$(jq -r .tune.connectionsPerGenerator $CAP)
T_REPS="${T_REPS:-$(jq -r .tune.repetitions $CAP)}"
D_JOBS=$(jq -r .dbCeiling.jobs $CAP)
F_DUR="${F_DUR:-$(jq -r .floor.duration $CAP)}"
F_CONNS=$(jq -r .floor.connectionsPerGenerator $CAP)
F_RATE=$(jq -r .floor.rate $CAP)
F_REPS="${F_REPS:-$(jq -r .floor.repetitions $CAP)}"
D_DUR="${D_DUR:-$(jq -r .dbCeiling.duration $CAP)}"
D_REPS="${D_REPS:-$(jq -r .dbCeiling.repetitions $CAP)}"
S_WINDOWS="${S_WINDOWS:-$(jq -r .soak.windows $CAP)}"
S_WDUR="${S_WDUR:-$(jq -r .soak.windowDuration $CAP)}"
S_FRAC=$(jq -r .soak.fractionOfCapacity $CAP)
S_CORES=$(jq -r .soak.cores $CAP)
S_CONNS=$(jq -r .soak.connectionsPerGenerator $CAP)

MEM_LOAD=$(jq -r .budget.load.memory $CAP)
CPUS_LOAD=$(jq -r .budget.load.cpus $CAP)

if [ "$MODE" = "--smoke" ]; then
  L_DUR=6s; L_REPS=1; L_REFINE=1; L_MAX=12000; WARMUP=3
  T_DUR=6s; T_REPS=1; F_DUR=5s; F_REPS=1; D_DUR=6s; D_REPS=1
  S_WINDOWS=2; S_WDUR=10s
  TUNE_WORKERS=(16 32); DB_CLIENTS=(32); CORES=(1 4)
fi

READ_PATH=$(jq -r .mix.read.path $CAP)
WRITE_PATH=$(jq -r .mix.write.path $CAP)
WRITE_BODY=$(jq -r .mix.write.body $CAP)
TOK_READ=$(jq -r '.pool[0]' keys/tokens.json)
TOK_WRITE=$(jq -r '.pool[1]' keys/tokens.json)

secs() { echo "${1%s}"; }

# The two generators meet at one instant, and that instant has to be in the
# clock of the VM they run in, not of macOS. The offset is measured once and
# deliberately includes container start-up latency, which can only push the
# rendezvous later — never into the past.
CLOCK_OFFSET_NS=0
measure_clock_offset() {
  local host vm
  host=$(date -u +%s)000000000
  vm=$(docker run --rm pgb/load 'date +%s%N' 2>/dev/null || echo "")
  if [ -n "$vm" ]; then
    CLOCK_OFFSET_NS=$(( vm - host ))
    log "VM clock is $(( CLOCK_OFFSET_NS / 1000000 )) ms ahead of the host (start-up latency included)"
  fi
}
log2() { log "$*"; echo "[$(date -u +%H:%M:%S)] $*" >> "$OUT/run.log"; }
note() { echo "$1" >> "$OUT/events.jsonl"; }

# ---------------------------------------------------------------- generators

# One oha container. It parks until START_AT so that the two halves of the mix
# begin within about ten milliseconds of each other rather than however long a
# container takes to start.
gen() { # <outfile> <name> <url> <method> <body> <random> <conns> <dur> <rate> <token> <start_at>
  local out="$1" name="$2"
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run --rm --name "$name" --network "$NET" \
    --cpuset-cpus "$CPUS_LOAD" --memory "$MEM_LOAD" --ulimit nofile=65536:65536 \
    -e URL="$3" -e M="$4" -e BODY="$5" -e RND="$6" -e C="$7" -e D="$8" -e Q="$9" \
    -e TOKEN="${10}" -e START_AT="${11}" \
    pgb/load '
      set -- -z "$D" -c "$C" -w -t 10s --no-tui --output-format json --disable-color \
             -m "$M" -H "Authorization: Bearer $TOKEN"
      [ "$Q" != 0 ] && set -- "$@" -q "$Q" --latency-correction
      [ -n "$BODY" ] && set -- "$@" -T application/json -d "$BODY"
      [ "$RND" = true ] && set -- "$@" --rand-regex-url
      n=$(date +%s%N)
      [ $(( (START_AT - n) / 1000000000 )) -gt 10 ] && START_AT=0
      while [ "$(date +%s%N)" -lt "$START_AT" ]; do sleep 0.01; done
      exec oha "$@" "$URL"' > "$out" 2>/dev/null
}

sampler_start() {
  docker rm -f pgb-sampler >/dev/null 2>&1 || true
  docker run -d --name pgb-sampler --cpuset-cpus "$CPUS_LOAD" --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:ro \
    pgb/load "sampler $(container_id pgb-app) $(container_id pgb-db) 1" >/dev/null 2>&1 || true
}

sampler_stop() { # <outfile>
  docker stop -t 0 pgb-sampler >/dev/null 2>&1 || true
  docker logs pgb-sampler > "$1" 2>/dev/null || true
  docker rm -f pgb-sampler >/dev/null 2>&1 || true
}

# The measurement itself: both halves of the mix, same window, same instant.
# rate 0 means closed loop (flat out); any other rate is split 50/50 and driven
# open loop with latency correction, so a candidate that falls behind shows it
# as queueing delay instead of quietly slowing the generator down.
mix() { # <stem> <host> <rate> <conns> <dur> [sample:yes|no]
  local stem="$1" host="$2" rate="$3" conns="$4" dur="$5" sample="${6:-yes}"
  local rr=0 wr=0 start_at p1 p2
  if [ "$rate" -gt 0 ]; then rr=$(( rate / 2 )); wr=$(( rate - rr )); fi
  start_at=$(( $(date -u +%s) * 1000000000 + CLOCK_OFFSET_NS + 3000000000 ))
  [ "$sample" = yes ] && sampler_start
  gen "$RAW/$stem.read.json"  pgb-gen-read  "http://$host$READ_PATH"  GET  ""            true  "$conns" "$dur" "$rr" "$TOK_READ"  "$start_at" &
  p1=$!
  gen "$RAW/$stem.write.json" pgb-gen-write "http://$host$WRITE_PATH" POST "$WRITE_BODY" false "$conns" "$dur" "$wr" "$TOK_WRITE" "$start_at" &
  p2=$!
  wait "$p1" || true
  wait "$p2" || true
  [ "$sample" = yes ] && sampler_stop "$RAW/$stem.res.jsonl"
  return 0
}

# --------------------------------------------------------------- derivation

half() { # <file> -> {ok,bad,p50ms,p95ms,p99ms,rps}
  jq -c '{
    ok:    ([(.statusCodeDistribution // {}) | to_entries[] | select(.key | startswith("2")) | .value] | add // 0),
    bad:   (([(.statusCodeDistribution // {}) | to_entries[] | select(.key | startswith("2") | not) | .value] | add // 0)
            + ([(.errorDistribution // {}) | to_entries[] | .value] | add // 0)),
    p50ms: (((.latencyPercentiles.p50 // 0) * 1000 * 1000 | round) / 1000),
    p95ms: (((.latencyPercentiles.p95 // 0) * 1000 * 1000 | round) / 1000),
    p99ms: (((.latencyPercentiles.p99 // 0) * 1000 * 1000 | round) / 1000),
    rps:   (.summary.requestsPerSec // 0)
  }' "$1" 2>/dev/null || echo '{"ok":0,"bad":-1,"p50ms":0,"p95ms":0,"p99ms":0,"rps":0}'
}

# CPU microseconds the candidate and the database burned during a run, read as
# counter deltas so the one-second sampling interval does not matter, plus the
# peak anonymous memory of the candidate.
res() { # <res.jsonl>
  jq -s -c 'if length < 2 then {appCpuUs:0, dbCpuUs:0, appAnonPeak:0, samples:length}
            else {appCpuUs: (.[-1].app_cpu - .[0].app_cpu),
                  dbCpuUs:  (.[-1].db_cpu  - .[0].db_cpu),
                  appAnonPeak: (map(.app_anon) | max),
                  samples: length} end' "$1" 2>/dev/null || echo '{"appCpuUs":0,"dbCpuUs":0,"appAnonPeak":0,"samples":0}'
}

# psql runs inside the database container, so the SQL travels on stdin.
relsize() {
  local o
  o=$(psql_ -d bench < db/relsize.sql 2>/dev/null | head -1 || true)
  if [ -n "$o" ] && jq -e . <<< "$o" >/dev/null 2>&1; then echo "$o"; else echo '{}'; fi
}

# One measured point, written to steps.jsonl whatever the outcome.
# Echoes "pass" or "fail" on stdout.
point() { # <stem> <phase> <cand> <cores> <workers> <rate> <dur> <conns> <rep>
  local stem="$1" phase="$2" cand="$3" cores="$4" workers="$5" rate="$6" dur="$7" conns="$8" rep="$9"
  local d; d=$(secs "$dur")
  local before after r w rs verdict
  before=$(relsize)
  mix "$stem" app "$rate" "$conns" "$dur"
  after=$(relsize)
  r=$(half "$RAW/$stem.read.json")
  w=$(half "$RAW/$stem.write.json")
  rs=$(res "$RAW/$stem.res.jsonl")
  local rec
  rec=$(jq -n --arg stem "$stem" --arg phase "$phase" --arg cand "$cand" \
    --argjson cores "$cores" --argjson workers "$workers" --argjson rate "$rate" \
    --argjson dur "$d" --argjson conns "$conns" --argjson rep "$rep" \
    --argjson read "$r" --argjson write "$w" --argjson resrc "$rs" \
    --argjson before "$before" --argjson after "$after" \
    --argjson sloP99 "$SLO_P99" --argjson sloFrac "$SLO_FRAC" \
    --arg at "$(date -u +%FT%TZ)" '
    ($read.ok / $dur) as $ra | ($write.ok / $dur) as $wa |
    (if $rate > 0 then ($rate / 2 | floor) else 0 end) as $rt |
    (if $rate > 0 then ($rate - ($rate / 2 | floor)) else 0 end) as $wt |
    {stem:$stem, phase:$phase, candidate:$cand, cores:$cores, workers:$workers,
     targetRate:$rate, durationSec:$dur, connectionsPerGen:$conns, rep:$rep, at:$at,
     read:  ($read  + {target:$rt, achieved:(($ra*100|round)/100)}),
     write: ($write + {target:$wt, achieved:(($wa*100|round)/100)}),
     achievedTotal: ((($ra + $wa)*100|round)/100),
     resources: $resrc,
     cpuUsPerReq: (if ($read.ok + $write.ok) > 0
                   then (($resrc.appCpuUs / ($read.ok + $write.ok) * 100 | round) / 100) else null end),
     dbCpuUsPerReq: (if ($read.ok + $write.ok) > 0
                   then (($resrc.dbCpuUs / ($read.ok + $write.ok) * 100 | round) / 100) else null end),
     table: {before:$before, after:$after},
     pass: ($rate > 0
            and $read.bad == 0 and $write.bad == 0
            and $ra >= ($rt * $sloFrac) and $wa >= ($wt * $sloFrac)
            and $read.p99ms <= $sloP99 and $write.p99ms <= $sloP99)}')
  echo "$rec" >> "$OUT/steps.jsonl"
  verdict=$(jq -r 'if .pass then "pass" else "fail" end' <<< "$rec")
  log2 "  $stem  target=$rate got=$(jq -r .achievedTotal <<< "$rec")/s  p99 r/w=$(jq -r .read.p99ms <<< "$rec")/$(jq -r .write.p99ms <<< "$rec") ms  bad=$(( $(jq -r .read.bad <<< "$rec") + $(jq -r .write.bad <<< "$rec") ))  cpu/req=$(jq -r '.cpuUsPerReq // "-"' <<< "$rec")µs  -> $verdict"
  echo "$verdict"
}

# --------------------------------------------------------------- block setup

reset_events() { psql_ -d bench < db/reset.sql >/dev/null 2>&1 || true; }

# A template copy occasionally loses a race with a connection that has not gone
# away yet. Three tries, then the cell is skipped and said so — an overnight run
# does not end because one copy failed.
fresh_db_safe() {
  local i
  for i in 1 2 3; do
    if fresh_db >/dev/null 2>&1; then return 0; fi
    log2 "  fresh_db failed (attempt $i)"
    sleep 4
  done
  note "{\"error\":\"fresh-db-failed\",\"at\":\"$(date -u +%FT%TZ)\"}"
  return 1
}

warm() { # a few seconds of the same mix, discarded: opcache, worker PDOs, pgx statement cache
  mix warmup app 0 32 "${WARMUP}s" no >/dev/null 2>&1 || true
  rm -f "$RAW/warmup.read.json" "$RAW/warmup.write.json"
  reset_events
}

open_cell() { # <cand> <cores> <workers>
  stop_app
  fresh_db_safe || return 1
  start_app_sized "$1" "$2" "$3"
  if ! wait_app; then
    note "{\"error\":\"never-ready\",\"candidate\":\"$1\",\"cores\":$2,\"workers\":$3}"
    docker logs pgb-app > "$RAW/never-ready_$1_c$2_w$3.log" 2>&1 || true
    stop_app
    return 1
  fi
  warm
}

# ------------------------------------------------------------------- phases

phase_floor() {
  log2 "== floor: nginx with no application code, per core budget"
  local c rep cpus
  for c in "${CORES[@]}"; do
    case "$c" in 1) cpus=0 ;; 2) cpus=0-1 ;; 3) cpus=0-2 ;; 4) cpus=0-3 ;; esac
    for rep in $(seq 1 "$F_REPS"); do
      docker rm -f pgb-probe >/dev/null 2>&1 || true
      docker run -d --name pgb-probe --network "$NET" --network-alias probe \
        --cpuset-cpus "$cpus" --memory "$MEM_APP" --ulimit nofile=65536:65536 pgb/probe >/dev/null
      sleep 2
      mix "floor_c${c}_rate_r$rep" probe "$F_RATE" "$F_CONNS" "$F_DUR" no
      sleep 1
      mix "floor_c${c}_flat_r$rep" probe 0 "$F_CONNS" "$F_DUR" no
      docker rm -f pgb-probe >/dev/null 2>&1 || true
      log2 "  floor cores=$c rep=$rep at-rate=$(jq -r '.summary.requestsPerSec|floor' "$RAW/floor_c${c}_rate_r$rep.read.json" 2>/dev/null)+$(jq -r '.summary.requestsPerSec|floor' "$RAW/floor_c${c}_rate_r$rep.write.json" 2>/dev/null)/s flat=$(jq -r '.summary.requestsPerSec|floor' "$RAW/floor_c${c}_flat_r$rep.read.json" 2>/dev/null)+$(jq -r '.summary.requestsPerSec|floor' "$RAW/floor_c${c}_flat_r$rep.write.json" 2>/dev/null)/s"
    done
  done
}

phase_dbceiling() {
  log2 "== dbceiling: pgbench INSERT, no HTTP, no token"
  local cl rep out tps
  stop_app
  for rep in $(seq 1 "$D_REPS"); do
    for cl in "${DB_CLIENTS[@]}"; do
      fresh_db_safe || continue
      out="$RAW/dbceil_c${cl}_r$rep.txt"
      local b4 af
      b4=$(docker exec pgb-db awk '$1=="usage_usec"{print $2}' /sys/fs/cgroup/cpu.stat 2>/dev/null || echo 0)
      docker run --rm --network "$NET" --cpuset-cpus "$CPUS_LOAD" --memory "$MEM_LOAD" \
        -e PGPASSWORD=bench -v "$ROOT/db:/sql:ro" --entrypoint pgbench "$PG_IMAGE" \
        -h db -U postgres -d bench -n -f /sql/pgbench-insert.sql -c "$cl" -j "$D_JOBS" \
        -T "$(secs "$D_DUR")" -P 5 > "$out" 2>&1 || true
      af=$(docker exec pgb-db awk '$1=="usage_usec"{print $2}' /sys/fs/cgroup/cpu.stat 2>/dev/null || echo 0)
      tps=$(awk '/^tps = /{print $3; exit}' "$out")
      jq -n --argjson clients "$cl" --argjson rep "$rep" --arg tps "${tps:-0}" \
        --argjson cpuUs "$(( af - b4 ))" --argjson dur "$(secs "$D_DUR")" --argjson jobs "$D_JOBS" \
        '{phase:"dbceiling", clients:$clients, jobs:$jobs, rep:$rep, tps:($tps|tonumber),
          dbCpuUs:$cpuUs, dbCores: (($cpuUs / 1000000 / $dur * 100 | round) / 100)}' >> "$OUT/steps.jsonl"
      log2 "  pgbench clients=$cl rep=$rep tps=${tps:-?} dbCores=$(awk -v b="$b4" -v a="$af" -v d="$(secs "$D_DUR")" 'BEGIN{printf "%.2f", (a-b)/1e6/d}')"
    done
  done
}

phase_tune() {
  log2 "== tune: pool size per candidate per core budget"
  local cand c wk trep r w best bestn total sum stem
  : > "$OUT/tuning.jsonl"
  for c in "${CORES[@]}"; do
    for cand in "${CANDS[@]}"; do
      best=0; bestn=32
      for wk in "${TUNE_WORKERS[@]}"; do
        sum=0
        for trep in $(seq 1 "$T_REPS"); do
          stem="tune_${cand}_c${c}_w${wk}_r${trep}"
          open_cell "$cand" "$c" "$wk" || continue
          mix "$stem" app 0 "$T_CONNS" "$T_DUR"
          r=$(half "$RAW/$stem.read.json")
          w=$(half "$RAW/$stem.write.json")
          total=$(jq -n --argjson r "$r" --argjson w "$w" --argjson d "$(secs "$T_DUR")" \
            'if ($r.bad + $w.bad) > 0 then 0 else (($r.ok + $w.ok) / $d | floor) end')
          jq -n --arg cand "$cand" --argjson cores "$c" --argjson workers "$wk" \
            --argjson rep "$trep" --argjson read "$r" --argjson write "$w" --argjson total "$total" \
            '{phase:"tune", candidate:$cand, cores:$cores, workers:$workers, rep:$rep,
              read:$read, write:$write, totalRps:$total}' >> "$OUT/tuning.jsonl"
          log2 "  tune $cand cores=$c workers=$wk rep=$trep -> $total/s (p99 r/w $(jq -r .p99ms <<< "$r")/$(jq -r .p99ms <<< "$w") ms)"
          if [ "$total" -gt "$sum" ]; then sum=$total; fi
          stop_app
        done
        log2 "  tune $cand cores=$c workers=$wk best=$sum/s"
        if [ "$sum" -gt "$best" ]; then best=$sum; bestn=$wk; fi
      done
      jq -n --arg cand "$cand" --argjson cores "$c" --argjson workers "$bestn" --argjson rps "$best" \
        '{chosen:true, candidate:$cand, cores:$cores, workers:$workers, totalRps:$rps}' >> "$OUT/tuning.jsonl"
      log2 "  -> $cand cores=$c uses $bestn workers"
    done
  done
}

chosen_workers() { # <cand> <cores>
  jq -r --arg c "$1" --argjson n "$2" \
    'select(.chosen == true and .candidate == $c and .cores == $n) | .workers' \
    "$OUT/tuning.jsonl" 2>/dev/null | tail -1
}

round_to() { echo $(( ( ($1 + $2 / 2) / $2 ) * $2 )); }

# Exponential search for the bracket, then bisection inside it. Every point is
# a full 30 s open-loop run against a table that was put back to its seeded
# size first, so no step inherits the rows the previous one wrote.
phase_ladder() {
  log2 "== ladder: the highest rate that meets the service level"
  local cand c rep wk rate lo hi i mid v
  for rep in $(seq 1 "$L_REPS"); do
    for c in "${CORES[@]}"; do
      for cand in "${CANDS[@]}"; do
        wk=$(chosen_workers "$cand" "$c"); wk=${wk:-32}
        log2 "ladder rep=$rep $cand cores=$c workers=$wk"
        open_cell "$cand" "$c" "$wk" || continue
        lo=0; hi=0; rate=$L_START
        while :; do
          reset_events
          v=$(point "lad_${cand}_c${c}_r${rep}_q${rate}" ladder "$cand" "$c" "$wk" "$rate" "$L_DUR" "$L_CONNS" "$rep")
          sleep "$COOL"
          if [ "$v" = pass ]; then
            lo=$rate
            [ "$rate" -ge "$L_MAX" ] && break
            rate=$(( rate * 2 ))
            [ "$rate" -gt "$L_MAX" ] && rate=$L_MAX
          else
            hi=$rate; break
          fi
        done
        if [ "$hi" -ne 0 ]; then
          for i in $(seq 1 "$L_REFINE"); do
            mid=$(round_to $(( (lo + hi) / 2 )) "$L_GRAIN")
            if [ "$mid" -le "$lo" ] || [ "$mid" -ge "$hi" ]; then break; fi
            reset_events
            v=$(point "lad_${cand}_c${c}_r${rep}_q${mid}" ladder "$cand" "$c" "$wk" "$mid" "$L_DUR" "$L_CONNS" "$rep")
            sleep "$COOL"
            if [ "$v" = pass ]; then lo=$mid; else hi=$mid; fi
          done
        fi
        jq -n --arg cand "$cand" --argjson cores "$c" --argjson workers "$wk" \
          --argjson rep "$rep" --argjson cap "$lo" --argjson firstFail "$hi" \
          '{phase:"capacity", candidate:$cand, cores:$cores, workers:$workers, rep:$rep,
            capacity:$cap, firstFailingRate:$firstFail}' >> "$OUT/steps.jsonl"
        log2 "  == $cand cores=$c rep=$rep capacity=$lo/s (first failure at ${hi:-none})"
        stop_app
      done
    done
  done
}

median_capacity() { # <cand> <cores>
  jq -s -r --arg c "$1" --argjson n "$2" \
    '[.[] | select(.phase == "capacity" and .candidate == $c and .cores == $n) | .capacity]
     | sort | if length == 0 then 0 else .[(length - 1) / 2 | floor] end' "$OUT/steps.jsonl"
}

# Twenty consecutive one-minute windows at nine tenths of the measured
# capacity, with nothing reset in between: the table grows the whole time, as
# it would in production. oha is restarted every window because it keeps every
# result in memory.
phase_soak() {
  log2 "== soak: $S_WINDOWS x $S_WDUR at ${S_FRAC} of capacity, $S_CORES cores"
  local cand cap rate wk i
  for cand in "${CANDS[@]}"; do
    cap=$(median_capacity "$cand" "$S_CORES")
    if [ "${cap:-0}" -le 0 ]; then log2 "  no capacity for $cand, skipping soak"; continue; fi
    rate=$(round_to "$(printf '%.0f' "$(echo "$cap $S_FRAC" | awk '{print $1 * $2}')")" "$L_GRAIN")
    wk=$(chosen_workers "$cand" "$S_CORES"); wk=${wk:-32}
    log2 "soak $cand rate=$rate/s workers=$wk"
    open_cell "$cand" "$S_CORES" "$wk" || continue
    for i in $(seq 1 "$S_WINDOWS"); do
      point "soak_${cand}_w$(printf '%02d' "$i")" soak "$cand" "$S_CORES" "$wk" "$rate" "$S_WDUR" "$S_CONNS" "$i" >/dev/null
    done
    stop_app
  done
}

write_meta() {
  jq -n \
    --arg stamp "$STAMP" --arg mode "$MODE" --arg started "$(date -u +%FT%TZ)" \
    --arg cpu "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)" \
    --arg hostCores "$(sysctl -n hw.ncpu 2>/dev/null || echo unknown)" \
    --arg macos "$(sw_vers -productVersion 2>/dev/null || echo unknown)" \
    --argjson docker "$(docker info --format '{"dockerVersion":"{{.ServerVersion}}","kernel":"{{.KernelVersion}}","os":"{{.OperatingSystem}}","arch":"{{.Architecture}}","vcpus":{{.NCPU}},"memoryBytes":{{.MemTotal}}}')" \
    --arg oha "$(docker run --rm pgb/load 'oha --version')" \
    --arg go "$(docker run --rm --entrypoint sh golang:1.27.1-trixie -c 'go version')" \
    --arg php "$(docker run --rm --entrypoint php pgb/fpm -r 'echo PHP_VERSION, " ", PHP_ZTS ? "ZTS" : "NTS";')" \
    --arg phpZts "$(docker run --rm --entrypoint php pgb/frankenphp -r 'echo PHP_VERSION, " ", PHP_ZTS ? "ZTS" : "NTS";')" \
    --arg franken "$(docker run --rm --entrypoint frankenphp pgb/frankenphp version)" \
    --arg nginx "$(docker run --rm --entrypoint nginx pgb/fpm -v 2>&1)" \
    --arg pg "$(psql_ -d postgres -c 'SHOW server_version')" \
    --arg pgx "$(awk '$1 == "github.com/jackc/pgx/v5" {print $2}' apps/go/go.mod)" \
    --arg gojwt "$(awk '$1 == "github.com/golang-jwt/jwt/v5" {print $2}' apps/go/go.mod)" \
    --arg phpjwt "$(jq -r '.packages[] | select(.name == "firebase/php-jwt") | .version' apps/php/composer.lock)" \
    --slurpfile config "$CAP" \
    '{stamp:$stamp, mode:$mode, started:$started,
      host:{cpu:$cpu, cores:($hostCores|tonumber? // $hostCores), macos:$macos, docker:$docker},
      versions:{oha:$oha, go:$go, phpFpm:$php, phpFrankenphp:$phpZts, frankenphp:$franken,
                nginx:$nginx, postgres:$pg, pgx:$pgx, golangJwt:$gojwt, firebasePhpJwt:$phpjwt},
      config:$config[0]}' > "$OUT/meta.json"
}

main() {
  mkdir -p "$RAW"
  touch "$OUT/run.log"
  [ -f "$OUT/steps.jsonl" ] || : > "$OUT/steps.jsonl"
  [ -f "$OUT/events.jsonl" ] || : > "$OUT/events.jsonl"
  [ -f keys/tokens.json ] || { log "FATAL: run ./bench/build.sh first"; exit 1; }
  trap 'docker rm -f pgb-app pgb-probe pgb-sampler pgb-gen-read pgb-gen-write >/dev/null 2>&1 || true' EXIT

  start_db
  measure_clock_offset
  [ -f "$OUT/meta.json" ] || write_meta
  log2 "results -> $OUT  (mode $MODE)"

  run_phase() { log2 "--- $1"; "$1" || { log2 "!!! $1 failed (exit $?), continuing"; note "{\"error\":\"phase-failed\",\"phase\":\"$1\"}"; }; }

  case "$MODE" in
    --all|--smoke)
      run_phase phase_floor
      run_phase phase_dbceiling
      run_phase phase_tune
      run_phase phase_ladder
      run_phase phase_soak ;;
    --floor)     phase_floor ;;
    --dbceiling) phase_dbceiling ;;
    --tune)      phase_tune ;;
    --ladder)    phase_ladder ;;
    --soak)      phase_soak ;;
    *) log "unknown mode $MODE"; exit 2 ;;
  esac

  jq --arg t "$(date -u +%FT%TZ)" --arg mode "$MODE" \
     '.finished = ((.finished // []) + [{mode:$mode, at:$t}])' "$OUT/meta.json" \
     > "$OUT/meta.json.tmp" && mv "$OUT/meta.json.tmp" "$OUT/meta.json"
  docker rm -f pgb-db >/dev/null 2>&1 || true
  log2 "done"
}

main
