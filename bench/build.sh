#!/usr/bin/env bash
# Builds every image, and mints the key pair and tokens if they are missing.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ -f keys/tokens.json ] || node keys/gen-keys.mjs

docker build -f docker/load.Dockerfile       -t pgb/load       .
docker build -f docker/probe.Dockerfile      -t pgb/probe      .
docker build -f docker/php-vendor.Dockerfile -t pgb/php-vendor .
docker build -f docker/go.Dockerfile         -t pgb/go         .
docker build -f docker/php-fpm.Dockerfile    -t pgb/fpm        .
docker build -f docker/frankenphp.Dockerfile -t pgb/frankenphp .
docker pull -q "$PG_IMAGE" >/dev/null

docker run --rm pgb/load 'oha --version'
for c in go fpm frankenphp; do
  printf '%-11s ' "$c"
  case "$c" in
    go) docker run --rm --entrypoint sh golang:1.27.1-trixie -c 'go version' ;;
    *)  docker run --rm --entrypoint php "pgb/$c" -r 'echo "PHP ", PHP_VERSION, " opcache=", (int) ini_get("opcache.enable"), " jit_buffer=", ini_get("opcache.jit_buffer_size"), PHP_EOL;' ;;
  esac
done
docker run --rm --entrypoint frankenphp pgb/frankenphp version
