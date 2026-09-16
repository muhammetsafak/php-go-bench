# php-fpm candidate: nginx and php-fpm in ONE container, so the four-core,
# 1 GiB budget covers the whole PHP-FPM stack, web server included — Go and
# FrankenPHP serve HTTP themselves and get no extra cores for it.
FROM pgb/php-vendor AS vendor

FROM php:8.5.10-fpm-trixie
RUN apt-get update \
 && apt-get install -y --no-install-recommends nginx libpq5 libpq-dev \
 && docker-php-ext-install pdo_pgsql \
 && apt-get purge -y libpq-dev && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/* /etc/nginx/sites-enabled /usr/local/etc/php-fpm.d/*
COPY docker/php.ini docker/opcache.ini /usr/local/etc/php/conf.d/
COPY docker/fpm-pool.conf /usr/local/etc/php-fpm.d/www.conf
COPY docker/fpm-nginx.conf /etc/nginx/nginx.conf
COPY --from=vendor /app /app
COPY apps/php/public /app/public
EXPOSE 80
CMD ["sh", "-c", "php-fpm --daemonize && exec nginx -g 'daemon off;'"]
