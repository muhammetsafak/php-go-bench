# Shared by build.sh, verify.sh and run.sh.
# shellcheck shell=bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

NET=pgbnet
CFG=bench/scenarios.json
PG_IMAGE=postgres:17.11-alpine

CPUS_APP="${CPUS_APP:-$(jq -r .budget.app.cpus $CFG)}"
CPUS_DB="${CPUS_DB:-$(jq -r .budget.db.cpus $CFG)}"
CPUS_LOAD="${CPUS_LOAD:-$(jq -r .budget.load.cpus $CFG)}"
MEM_APP=$(jq -r .budget.app.memory $CFG)
MEM_DB=$(jq -r .budget.db.memory $CFG)
MEM_LOAD=$(jq -r .budget.load.memory $CFG)
DB_CONNS=$(jq -r .budget.dbConnections $CFG)

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
psql_() { docker exec -i pgb-db psql -v ON_ERROR_STOP=1 -qtAX -U postgres "$@"; }

token() { jq -r ".$1" keys/tokens.json; }

ensure_network() { docker network create "$NET" >/dev/null 2>&1 || true; }

# One PostgreSQL for the whole run. Settings are explicit because defaults are
# a variable too; synchronous_commit stays ON — a write that is not durable is
# not the write the question is about.
start_db() {
  ensure_network
  docker rm -f pgb-db >/dev/null 2>&1 || true
  log "starting $PG_IMAGE on cpus $CPUS_DB"
  docker run -d --name pgb-db --network "$NET" --network-alias db \
    --cpuset-cpus "$CPUS_DB" --memory "$MEM_DB" --shm-size 1g \
    -e POSTGRES_PASSWORD=bench \
    "$PG_IMAGE" \
    -c max_connections=100 \
    -c shared_buffers=512MB \
    -c effective_cache_size=1GB \
    -c work_mem=16MB \
    -c maintenance_work_mem=256MB \
    -c max_wal_size=4GB \
    -c checkpoint_timeout=15min \
    -c random_page_cost=1.1 >/dev/null
  until docker exec pgb-db pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
  sleep 3
  until docker exec pgb-db pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
  log "seeding template (1,000,000 rows)"
  psql_ -d postgres -c "CREATE DATABASE seed" >/dev/null
  docker exec -i pgb-db psql -v ON_ERROR_STOP=1 -qX -U postgres -d seed < db/schema.sql >/dev/null
  psql_ -d postgres -c "UPDATE pg_database SET datistemplate = true WHERE datname = 'seed'" >/dev/null
}

db_running() { [ "$(docker inspect -f '{{.State.Running}}' pgb-db 2>/dev/null)" = "true" ]; }

# Byte-identical copy of the template, pulled into shared_buffers, then a
# checkpoint so no candidate inherits another's WAL flush.
fresh_db() {
  psql_ -d postgres -c "DROP DATABASE IF EXISTS bench WITH (FORCE)" >/dev/null
  psql_ -d postgres -c "CREATE DATABASE bench TEMPLATE seed" >/dev/null
  psql_ -d bench -c "SELECT pg_prewarm('events'), pg_prewarm('events_pkey')" >/dev/null
  psql_ -d postgres -c "CHECKPOINT" >/dev/null
}

stop_app() { docker rm -f pgb-app >/dev/null 2>&1 || true; }

start_app() {
  local cand="$1"
  stop_app
  docker run -d --name pgb-app --network "$NET" --network-alias app \
    --cpuset-cpus "$CPUS_APP" --memory "$MEM_APP" --memory-swap "$MEM_APP" \
    --ulimit nofile=65536:65536 \
    -v "$ROOT/keys:/keys:ro" \
    -e DB_HOST=db -e DB_NAME=bench -e DB_USER=postgres -e DB_PASS=bench -e DB_MAX_CONNS="$DB_CONNS" \
    "pgb/$cand" >/dev/null
}

# The candidate on a chosen core budget and a chosen pool size. The pool size
# is one number for all three: Go's pgx pool, php-fpm's children (one
# persistent PDO each) and FrankenPHP's workers (one PDO each) — so the
# database connection ceiling is the same whatever the candidate is. nginx, for
# the php-fpm candidate only, lives inside the same cpuset.
#
#   start_app_sized <candidate> <cores> <workers>
start_app_sized() {
  local cand="$1" cores="$2" workers="$3" cpus nginx
  case "$cores" in
    1) cpus=0 ;; 2) cpus=0-1 ;; 3) cpus=0-2 ;; 4) cpus=0-3 ;;
    *) log "FATAL: no cpuset defined for $cores cores"; return 2 ;;
  esac
  [ "$cores" -ge 4 ] && nginx=2 || nginx=1
  stop_app
  docker run -d --name pgb-app --network "$NET" --network-alias app \
    --cpuset-cpus "$cpus" --memory "$MEM_APP" --memory-swap "$MEM_APP" \
    --ulimit nofile=65536:65536 \
    -v "$ROOT/keys:/keys:ro" \
    -e GOMAXPROCS="$cores" -e WORKERS="$workers" -e NGINX_WORKERS="$nginx" \
    -e DB_HOST=db -e DB_NAME=bench -e DB_USER=postgres -e DB_PASS=bench \
    -e DB_MAX_CONNS="$workers" \
    "pgb/$cand" >/dev/null
}

# Waits until the candidate answers /auth with 200.
wait_app() {
  local tok; tok="$(token valid)"
  for _ in $(seq 1 60); do
    if docker run --rm --network "$NET" pgb/load \
        "curl -s -f -o /dev/null -H 'Authorization: Bearer $tok' http://app/auth" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

container_id() { docker inspect -f '{{.Id}}' "$1"; }
