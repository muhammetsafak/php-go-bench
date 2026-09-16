#!/bin/sh
# cgroup sampler. Runs inside the load image with the VM's cgroup tree mounted
# read-only, and prints one JSON line per interval for the app and db
# containers:
#   t          monotonic-ish wall clock of the VM, nanoseconds
#   *_cpu      cumulative CPU time, microseconds (cpu.stat usage_usec)
#   *_mem      memory.current, bytes (includes page cache)
#   *_anon     anonymous memory from memory.stat, bytes (≈ RSS)
# CPU is read as a counter, not as a percentage, so the CPU seconds spent over a
# run are exact regardless of the sampling interval.
set -u
APP="/sys/fs/cgroup/docker/$1"
DB="/sys/fs/cgroup/docker/$2"
INTERVAL="${3:-1}"
cpu()  { awk '$1=="usage_usec"{print $2}' "$1/cpu.stat" 2>/dev/null || echo 0; }
anon() { awk '$1=="anon"{print $2}' "$1/memory.stat" 2>/dev/null || echo 0; }
mem()  { cat "$1/memory.current" 2>/dev/null || echo 0; }
while :; do
  printf '{"t":%s,"app_cpu":%s,"app_mem":%s,"app_anon":%s,"db_cpu":%s,"db_mem":%s,"db_anon":%s}\n' \
    "$(date +%s%N)" "$(cpu "$APP")" "$(mem "$APP")" "$(anon "$APP")" \
    "$(cpu "$DB")" "$(mem "$DB")" "$(anon "$DB")"
  sleep "$INTERVAL"
done
