#!/usr/bin/env bash
# Orchestrator for the PHP vs Go benchmark.
#
# Protocol, in one place so the report can quote it:
#   * app, PostgreSQL and the load generator sit on disjoint cpusets
#     (4 + 4 + 4 of the Docker VM's 12 vCPUs); one candidate runs at a time
#   * every block starts from a byte-identical, prewarmed copy of a
#     1,000,000-row table and a fresh candidate container
#   * before each block, a reference nginx that runs no application code is
#     put on the candidate's four cores and driven at the target rate: if the
#     generator cannot hit the target against it, no candidate could either,
#     and the block says so
#   * candidate order is reshuffled every repetition
#   * phase "rate": open loop, oha -q <target> --latency-correction, so latency
#     is measured from the moment a request was due (no coordinated omission)
#   * every request has a 10 s timeout; a request still open at the end of the
#     window is waited for (oha -w), so no answer is silently dropped
#   * phase "ceiling": closed loop, a connection sweep; capacity = best of N
#   * a cgroup sampler records the app's and the database's CPU counter and
#     memory for every run; CPU seconds come from counters, not percentages
#   * raw oha JSON and sampler output are kept verbatim; report.mjs derives
#     every number
#
#   ./bench/run.sh --all            both phases (≈ 1 h 45 min)
#   ./bench/run.sh --rate           phase A only
#   ./bench/run.sh --ceiling        phase B only
#   ./bench/run.sh --smoke          5-second version of both, one repetition
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODE="${1:---all}"
STAMP="${STAMP:-$(date -u +%Y-%m-%d)}"
OUT="$ROOT/results/$STAMP"
RAW="$OUT/raw"

read -r -a CANDS <<< "${CANDS:-$(jq -r '.candidates | join(" ")' $CFG)}"
read -r -a SCENS <<< "$(jq -r '[.scenarios[].id] | join(" ")' $CFG)"

RATE_CONNS=$(jq -r .rate.connections $CFG)
RATE_DUR="${RATE_DUR:-$(jq -r .rate.duration $CFG)}"
RATE_REPS="${RATE_REPS:-$(jq -r .rate.repetitions $CFG)}"
WARMUP="${WARMUP:-$(jq -r .rate.warmupSeconds $CFG)}"
RATE_COOL=$(jq -r .rate.cooldownSeconds $CFG)
read -r -a CEIL_CONNS <<< "${CEIL_CONNS:-$(jq -r '.ceiling.connections | join(" ")' $CFG)}"
CEIL_DUR="${CEIL_DUR:-$(jq -r .ceiling.duration $CFG)}"
CEIL_REPS="${CEIL_REPS:-$(jq -r .ceiling.repetitions $CFG)}"
CEIL_COOL=$(jq -r .ceiling.cooldownSeconds $CFG)
PROBE_RATE=$(jq -r .probe.rate $CFG)
PROBE_CONNS=$(jq -r .probe.connections $CFG)
PROBE_DUR="${PROBE_DUR:-$(jq -r .probe.duration $CFG)}"

if [ "$MODE" = "--smoke" ]; then
  RATE_DUR=5s RATE_REPS=1 CEIL_DUR=5s CEIL_REPS=1 WARMUP=2 PROBE_DUR=5s
  CEIL_CONNS=(64)
fi

TOKEN="$(token valid)"
scen() { jq -r --arg id "$1" --arg k "$2" '.scenarios[] | select(.id == $id) | .[$k] // ""' $CFG; }
target() { jq -r --arg id "$1" '.rate.targets[$id]' $CFG; }

anomaly() { echo "$1" >> "$OUT/anomalies.jsonl"; log "ANOMALY $1"; }

# One oha invocation. Everything that could contain quotes or braces travels as
# an environment variable, never through shell interpolation.
#   oha_run <outfile> <url> <method> <body> <random:true|false> <conns> <duration> [rate]
oha_run() {
  local out="$1" url="$2" method="$3" body="$4" random="$5" conns="$6" dur="$7" rate="${8:-}"
  docker run --rm --network "$NET" --cpuset-cpus "$CPUS_LOAD" --memory "$MEM_LOAD" \
    --ulimit nofile=65536:65536 \
    -e URL="$url" -e M="$method" -e BODY="$body" -e RND="$random" \
    -e C="$conns" -e D="$dur" -e Q="$rate" -e TOKEN="$TOKEN" \
    pgb/load '
      set -- -z "$D" -c "$C" -w -t 10s --no-tui --output-format json --disable-color \
             -m "$M" -H "Authorization: Bearer $TOKEN"
      [ -n "$Q" ] && set -- "$@" -q "$Q" --latency-correction
      [ -n "$BODY" ] && set -- "$@" -T application/json -d "$BODY"
      [ "$RND" = true ] && set -- "$@" --rand-regex-url
      exec oha "$@" "$URL"' > "$out" 2>/dev/null
}

scenario_run() { # <outfile> <scenario> <conns> <duration> [rate]
  local sc="$2"
  oha_run "$1" "http://app$(scen "$sc" path)" "$(scen "$sc" method)" "$(scen "$sc" body)" \
    "$(scen "$sc" randomPath)" "$3" "$4" "${5:-}"
}

sampler_start() {
  docker rm -f pgb-sampler >/dev/null 2>&1 || true
  docker run -d --name pgb-sampler --cpuset-cpus "$CPUS_LOAD" --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:ro \
    pgb/load "sampler $(container_id pgb-app) $(container_id pgb-db) 1" >/dev/null
}

sampler_stop() { # <outfile>
  docker stop -t 0 pgb-sampler >/dev/null 2>&1 || true
  docker logs pgb-sampler > "$1" 2>/dev/null || true
  docker rm -f pgb-sampler >/dev/null 2>&1 || true
}

# Measured run of one scenario against the running candidate, with sampling
# and a status check. A run with non-2xx answers or transport errors is kept
# (it is part of the result) and flagged.
measure() { # <file-stem> <cand> <scenario> <conns> <duration> [rate]
  local stem="$1" cand="$2" sc="$3" file="$RAW/$1.json"
  sampler_start
  if ! scenario_run "$file" "$sc" "$4" "$5" "${6:-}"; then
    anomaly "{\"run\":\"$stem\",\"error\":\"oha-failed\"}"
  fi
  sampler_stop "$RAW/$stem.res.jsonl"
  local bad
  bad=$(jq '([.statusCodeDistribution | to_entries[] | select(.key | startswith("2") | not) | .value] | add // 0)
            + ([.errorDistribution // {} | to_entries[] | .value] | add // 0)' "$file" 2>/dev/null || echo "?")
  if [ "$bad" != "0" ]; then
    anomaly "{\"run\":\"$stem\",\"failed\":\"$bad\",\"statuses\":$(jq -c .statusCodeDistribution "$file" 2>/dev/null || echo null),\"errors\":$(jq -c '.errorDistribution // {}' "$file" 2>/dev/null || echo null)}"
  fi
  log "  $stem  rps=$(jq -r '.summary.requestsPerSec | floor' "$file" 2>/dev/null) p99=$(jq -r '.latencyPercentiles.p99 * 1000 | . * 100 | floor / 100' "$file" 2>/dev/null)ms failed=$bad"
}

# Reference nginx on the candidate's cores: what the generator and the network
# can carry right now, at the target rate and flat out.
probe() { # <phase> <cand> <rep>
  docker rm -f pgb-probe >/dev/null 2>&1 || true
  docker run -d --name pgb-probe --network "$NET" --network-alias probe \
    --cpuset-cpus "$CPUS_APP" --memory "$MEM_APP" --ulimit nofile=65536:65536 pgb/probe >/dev/null
  sleep 2
  oha_run "$RAW/probe-rate_$1_$2_r$3.json" http://probe/ GET "" false "$PROBE_CONNS" "$PROBE_DUR" "$PROBE_RATE" || true
  oha_run "$RAW/probe-ceil_$1_$2_r$3.json" http://probe/ GET "" false "$PROBE_CONNS" "$PROBE_DUR" || true
  docker rm -f pgb-probe >/dev/null 2>&1 || true
  log "  probe: at-rate=$(jq -r '.summary.requestsPerSec | floor' "$RAW/probe-rate_$1_$2_r$3.json" 2>/dev/null)/s flat-out=$(jq -r '.summary.requestsPerSec | floor' "$RAW/probe-ceil_$1_$2_r$3.json" 2>/dev/null)/s"
}

# Opens every PHP worker's persistent connection, fills opcache and the Go
# pool's statement cache. Its traffic is discarded.
warm() {
  local sc
  for sc in "${SCENS[@]}"; do
    scenario_run /dev/null "$sc" 64 "${WARMUP}s" || true
  done
}

# Fresh database, reference probe, fresh candidate, warm-up. Returns non-zero
# if the candidate never became ready.
open_block() { # <phase> <cand> <rep>
  log "$1 rep $3 — $2"
  stop_app
  fresh_db
  probe "$1" "$2" "$3"
  start_app "$2"
  if ! wait_app; then
    anomaly "{\"phase\":\"$1\",\"candidate\":\"$2\",\"rep\":$3,\"error\":\"never-ready\"}"
    docker logs pgb-app > "$RAW/never-ready_$1_$2_r$3.log" 2>&1 || true
    stop_app
    return 1
  fi
  warm
}

close_block() { # <phase> <cand> <rep>
  docker logs pgb-app > "$RAW/app_$1_$2_r$3.log" 2>&1 || true
  [ -s "$RAW/app_$1_$2_r$3.log" ] || rm -f "$RAW/app_$1_$2_r$3.log"
  stop_app
}

shuffled() { printf '%s\n' "${CANDS[@]}" | awk 'BEGIN{srand('"$1"')} {print rand() "\t" $0}' | sort -k1,1n | cut -f2; }

phase_rate() {
  local rep cand sc q
  for rep in $(seq 1 "$RATE_REPS"); do
    for cand in $(shuffled "$rep"); do
      open_block rate "$cand" "$rep" || continue
      # write last: it is the only scenario that changes the table
      for sc in "${SCENS[@]}"; do
        q=$(target "$sc")
        measure "rate_${cand}_${sc}_q${q}_r${rep}" "$cand" "$sc" "$RATE_CONNS" "$RATE_DUR" "$q"
        sleep "$RATE_COOL"
      done
      close_block rate "$cand" "$rep"
    done
  done
}

phase_ceiling() {
  local rep cand sc c
  for rep in $(seq 1 "$CEIL_REPS"); do
    for cand in $(shuffled "$((rep + 100))"); do
      open_block ceil "$cand" "$rep" || continue
      for sc in "${SCENS[@]}"; do
        for c in "${CEIL_CONNS[@]}"; do
          measure "ceil_${cand}_${sc}_c${c}_r${rep}" "$cand" "$sc" "$c" "$CEIL_DUR"
          sleep "$CEIL_COOL"
        done
      done
      close_block ceil "$cand" "$rep"
    done
  done
}

write_meta() {
  local host
  host=$(docker info --format '{"dockerVersion":"{{.ServerVersion}}","kernel":"{{.KernelVersion}}","os":"{{.OperatingSystem}}","arch":"{{.Architecture}}","vcpus":{{.NCPU}},"memoryBytes":{{.MemTotal}}}')
  jq -n \
    --arg stamp "$STAMP" --arg mode "$MODE" \
    --arg started "$(date -u +%FT%TZ)" \
    --arg cpu "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)" \
    --arg hostCores "$(sysctl -n hw.ncpu 2>/dev/null || echo unknown)" \
    --arg macos "$(sw_vers -productVersion 2>/dev/null || echo unknown)" \
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
    --argjson docker "$host" \
    --slurpfile config "$CFG" \
    --argjson overrides "$(jq -n --arg rd "$RATE_DUR" --arg rr "$RATE_REPS" --arg cd "$CEIL_DUR" --arg cr "$CEIL_REPS" --arg cc "${CEIL_CONNS[*]}" --arg pd "$PROBE_DUR" \
        '{rateDuration:$rd, rateRepetitions:($rr|tonumber), ceilingDuration:$cd, ceilingRepetitions:($cr|tonumber), ceilingConnections:($cc|split(" ")|map(tonumber)), probeDuration:$pd}')" \
    '{stamp:$stamp, mode:$mode, started:$started,
      host:{cpu:$cpu, cores:($hostCores|tonumber? // $hostCores), macos:$macos, docker:$docker},
      versions:{oha:$oha, go:$go, phpFpm:$php, phpFrankenphp:$phpZts, frankenphp:$franken, nginx:$nginx, postgres:$pg,
                pgx:$pgx, golangJwt:$gojwt, firebasePhpJwt:$phpjwt},
      config:$config[0], effective:$overrides}' > "$OUT/meta.json"
}

main() {
  mkdir -p "$RAW"
  [ -f "$OUT/anomalies.jsonl" ] || : > "$OUT/anomalies.jsonl"
  [ -f keys/tokens.json ] || { log "FATAL: run ./bench/build.sh first"; exit 1; }
  trap 'docker rm -f pgb-app pgb-probe pgb-sampler >/dev/null 2>&1 || true' EXIT

  start_db
  write_meta
  log "results → $OUT"

  case "$MODE" in
    --all|--smoke) phase_rate; phase_ceiling ;;
    --rate) phase_rate ;;
    --ceiling) phase_ceiling ;;
    *) log "unknown mode $MODE"; exit 2 ;;
  esac

  jq --arg t "$(date -u +%FT%TZ)" '. + {finished:$t}' "$OUT/meta.json" > "$OUT/meta.json.tmp" && mv "$OUT/meta.json.tmp" "$OUT/meta.json"
  docker rm -f pgb-db >/dev/null 2>&1 || true
  log "done — raw output in $RAW"
}

main
