# FrankenPHP candidate in worker mode. Same PHP (8.5.10), same Debian (trixie),
# same php.ini and opcache.ini as the php-fpm candidate.
FROM pgb/php-vendor AS vendor

FROM dunglas/frankenphp:1.12.7-php8.5.10-trixie
RUN install-php-extensions pdo_pgsql
COPY docker/php.ini docker/opcache.ini /usr/local/etc/php/conf.d/
COPY docker/Caddyfile /etc/bench/Caddyfile
COPY --from=vendor /app /app
COPY apps/php/public /app/public
ENV GOMAXPROCS=4
EXPOSE 80
CMD ["frankenphp", "run", "--config", "/etc/bench/Caddyfile"]
