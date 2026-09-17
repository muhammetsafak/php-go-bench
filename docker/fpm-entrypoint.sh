#!/bin/sh
# Applies the run-time sizing of the php-fpm candidate, then starts nginx.
#
#   WORKERS        php-fpm children — one persistent PDO connection each, so
#                  this is also the candidate's database connection ceiling
#   NGINX_WORKERS  nginx worker processes; they live inside the candidate's
#                  own core budget, not next to it
#
# Both default to the values the 2026-09-16 run used, so a run that sets
# neither reproduces that run exactly.
set -e
sed -i "s/__WORKERS__/${WORKERS:-32}/" /usr/local/etc/php-fpm.d/www.conf
sed -i "s/__NGINX_WORKERS__/${NGINX_WORKERS:-2}/" /etc/nginx/nginx.conf
php-fpm --daemonize
exec nginx -g 'daemon off;'
