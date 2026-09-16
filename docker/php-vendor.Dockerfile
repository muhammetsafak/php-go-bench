# Shared build stage: composer runs here, never on the host.
FROM composer:2.9.8
WORKDIR /app
COPY apps/php/composer.json apps/php/composer.lock ./
COPY apps/php/src ./src
RUN composer install --no-dev --no-interaction --no-progress --ignore-platform-reqs --classmap-authoritative
