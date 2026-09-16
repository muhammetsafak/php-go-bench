#!/usr/bin/env bash
# Proves every candidate honours the same contract before anything is measured:
# the right status for good, missing, expired, foreign and under-scoped tokens,
# a real row back from GET, a real row written by POST.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ $# -gt 0 ]; then CANDS=("$@"); else CANDS=(go fpm frankenphp); fi

db_running || start_db
fresh_db

valid=$(token valid); readonly_=$(token readonly); expired=$(token expired); foreign=$(token foreign)
body=$(jq -r '.scenarios[] | select(.id=="write") | .body' "$CFG")
fail=0

req() { # method path token [body] -> "status body"
  local m="$1" p="$2" t="$3" b="${4:-}"
  docker run --rm --network "$NET" -e M="$m" -e P="$p" -e T="$t" -e B="$b" pgb/load '
    set -- -s -o /tmp/out -w "%{http_code}" -X "$M"
    [ -n "$T" ] && set -- "$@" -H "Authorization: Bearer $T"
    [ -n "$B" ] && set -- "$@" -H "Content-Type: application/json" --data "$B"
    code=$(curl "$@" "http://app$P"); printf "%s %s" "$code" "$(cat /tmp/out)"'
}

check() { # label expected actual
  local got="${3%% *}"
  if [ "$got" = "$2" ]; then printf '  ok   %-34s %s\n' "$1" "$3"
  else printf '  FAIL %-34s want %s, got %s\n' "$1" "$2" "$3"; fail=1; fi
}

for c in "${CANDS[@]}"; do
  echo "== $c"
  start_app "$c"
  wait_app || { echo "  FAIL never became ready"; docker logs pgb-app 2>&1 | tail -20; fail=1; continue; }
  before=$(psql_ -d bench -c "SELECT count(*) FROM events")
  check "GET /auth valid"                200 "$(req GET /auth "$valid")"
  check "GET /auth no token"             401 "$(req GET /auth "")"
  check "GET /auth expired"              401 "$(req GET /auth "$expired")"
  check "GET /auth foreign key"          401 "$(req GET /auth "$foreign")"
  check "GET /events/1"                  200 "$(req GET /events/1 "$valid")"
  check "GET /events/999999"             200 "$(req GET /events/999999 "$valid")"
  check "GET /events/99999999 (absent)"  404 "$(req GET /events/99999999 "$valid")"
  check "GET /events/abc"                404 "$(req GET /events/abc "$valid")"
  check "GET /events/1 expired"          401 "$(req GET /events/1 "$expired")"
  check "POST /events valid"             201 "$(req POST /events "$valid" "$body")"
  check "POST /events read-only scope"   401 "$(req POST /events "$readonly_" "$body")"
  check "POST /events bad body"          400 "$(req POST /events "$valid" '{"kind":1}')"
  after=$(psql_ -d bench -c "SELECT count(*) FROM events")
  if [ $((after - before)) -eq 1 ]; then echo "  ok   exactly one row written ($before -> $after)"
  else echo "  FAIL row count $before -> $after"; fail=1; fi
  conns=$(psql_ -d postgres -c "SELECT count(*) FROM pg_stat_activity WHERE datname = 'bench'")
  echo "       database connections held: $conns"
  stop_app
done
exit $fail
