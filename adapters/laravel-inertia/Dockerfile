# syntax=docker/dockerfile:1

FROM node:24.15.0-alpine@sha256:d1b3b4da11eefd5941e7f0b9cf17783fc99d9c6fc34884a665f40a06dbdfc94f AS assets
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY resources ./resources
COPY vite.config.ts tsconfig.json ./
RUN npm run build

FROM composer:2.10.2@sha256:4d71c3c2109c61d5415544264b59ad4087e4c5b7244481723664138fd36d5040 AS vendor
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --no-interaction \
    --prefer-dist --optimize-autoloader

FROM php:8.3.21-fpm-alpine@sha256:d2170b0f8da574062b289566a05f25ab57173315a356c9f7519b5e444ae96dac AS runtime
RUN apk add --no-cache postgresql-dev \
 && docker-php-ext-install pdo_pgsql opcache
WORKDIR /var/www
COPY --from=vendor /app/vendor ./vendor
COPY --from=assets /app/public/build ./public/build
COPY . .
COPY docker/opcache.ini /usr/local/etc/php/conf.d/opcache.ini
USER www-data
EXPOSE 9000
# php-fpm speaks fastcgi on this port, not http, so the http probes the
# sibling adapters (nextjs, nestjs) use do not transplant here. the obvious
# alternative, `php -r 'exit(0);'`, only proves the php cli starts — it can
# never fail while the container is actually broken, which is worse than no
# check at all: an orchestrator with no HEALTHCHECK knows it does not know,
# one with an always-green check believes it does. a real check needs
# php-fpm's ping.path probed with cgi-fcgi, which costs a pool config file
# and a package this image does not otherwise need; add both together if
# this is ever deployed behind something that polls container health.
CMD ["php-fpm"]
