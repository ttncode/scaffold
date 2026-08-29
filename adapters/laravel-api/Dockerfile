# syntax=docker/dockerfile:1

FROM composer:2.10.2 AS vendor
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --no-interaction \
    --prefer-dist --optimize-autoloader

FROM php:8.3.21-fpm-alpine AS runtime
RUN apk add --no-cache postgresql-dev \
 && docker-php-ext-install pdo_pgsql opcache
WORKDIR /var/www
COPY --from=vendor /app/vendor ./vendor
COPY . .
COPY docker/opcache.ini /usr/local/etc/php/conf.d/opcache.ini
USER www-data
EXPOSE 9000
# php-fpm speaks fastcgi on this port, not http, so the http probes the
# sibling adapters (nextjs, nestjs) use do not transplant here. the previous
# check, `php -r 'exit(0);'`, only proved the php cli starts — it can never
# fail while the container is actually broken, which is worse than no check
# at all: an orchestrator with no HEALTHCHECK knows it does not know, one
# with an always-green check believes it does. a real check needs php-fpm's
# ping.path probed with cgi-fcgi, which costs a pool config file and a
# package this image does not otherwise need; add both together if this is
# ever deployed behind something that polls container health.
CMD ["php-fpm"]
