# FrankenPHP candidate in worker mode. Same PHP (8.5.10), same Debian (trixie),
# same php.ini and opcache.ini as the php-fpm candidate.
FROM pgb/php-vendor AS vendor

FROM dunglas/frankenphp:1.12.7-php8.5.10-trixie
RUN install-php-extensions pdo_pgsql
COPY docker/php.ini docker/opcache.ini /usr/local/etc/php/conf.d/
COPY docker/Caddyfile.tmpl /etc/bench/Caddyfile.tmpl
COPY --from=vendor /app /app
COPY apps/php/public /app/public
COPY docker/frankenphp-entrypoint.sh /usr/local/bin/entrypoint
# Overridden per core budget by the capacity run; unset means the four cores
# and 32 workers the 2026-09-16 run used.
ENV GOMAXPROCS=4
EXPOSE 80
CMD ["/usr/local/bin/entrypoint"]
