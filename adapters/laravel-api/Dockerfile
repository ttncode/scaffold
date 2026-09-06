# syntax=docker/dockerfile:1

FROM composer:2.10.2@sha256:4d71c3c2109c61d5415544264b59ad4087e4c5b7244481723664138fd36d5040 AS vendor
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --no-interaction \
    --prefer-dist --optimize-autoloader

# FrankenPHP, because php-fpm speaks FastCGI and this stack has no web server
# in front of it: nothing served HTTP at all, and compose published a dead
# port. Documented as a first-class server in laravel.com/docs/13.x/deployment,
# part of the PHP Foundation since May 2025, and what Laravel Cloud runs.
# Alpine specifically: services/mongodb/drivers/laravel.sh emits `apk add`.
FROM dunglas/frankenphp:1.12.7-php8.3-alpine@sha256:049b8d8356efceb93c91ed42866de890534310bcef4ad4dde902029e4a0d20c3 AS runtime
RUN docker-php-ext-install opcache
# @SERVICE_SETUP@
WORKDIR /var/www
COPY --from=vendor /app/vendor ./vendor
COPY . .
COPY docker/opcache.ini /usr/local/etc/php/conf.d/opcache.ini
# :8080 is how frankenphp listens on an unprivileged port and declines to
# provision TLS, which belongs to whatever proxy this lands behind.
ENV SERVER_NAME=:8080
# Caddy writes here and will not start if it may not. The app tree needs the
# same: COPY runs as root, the server runs as www-data, and the first request
# that compiles a blade view or writes a log fails without this.
ENV XDG_CONFIG_HOME=/config XDG_DATA_HOME=/data
RUN mkdir -p /config /data \
 && chown -R www-data:www-data /config /data \
      /var/www/storage /var/www/bootstrap/cache
USER www-data
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s \
  CMD wget -qO- http://localhost:8080/up || exit 1
# CMD replaces the base image's default args entirely rather than extending
# them, and those args are what point frankenphp at the Caddyfile that
# defines the :8080 site block; without them it starts only the admin API on
# 127.0.0.1:2019 and nothing ever listens on 8080.
CMD ["frankenphp", "run", "--config", "/etc/frankenphp/Caddyfile", "--adapter", "caddyfile"]
