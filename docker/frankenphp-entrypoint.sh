#!/bin/sh
# Applies the run-time sizing of the FrankenPHP candidate.
#
#   WORKERS  worker scripts — one PDO connection each, so this is also the
#            candidate's database connection ceiling. FrankenPHP requires the
#            thread pool to be strictly larger than the worker count.
#
# Defaults to the value the 2026-09-16 run used.
set -e
W="${WORKERS:-32}"
sed -e "s/__WORKERS__/$W/" -e "s/__THREADS__/$((W + 1))/" \
    /etc/bench/Caddyfile.tmpl > /etc/bench/Caddyfile
exec frankenphp run --config /etc/bench/Caddyfile
