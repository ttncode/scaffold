# syntax=docker/dockerfile:1

FROM composer:2.10.2@sha256:4d71c3c2109c61d5415544264b59ad4087e4c5b7244481723664138fd36d5040 AS vendor
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --no-interaction \
    --prefer-dist --optimize-autoloader

# FrankenPHP: php-fpm speaks FastCGI and nothing fronts it.
# Alpine: the mongodb driver emits `apk add`.
FROM dunglas/frankenphp:1.12.7-php8.3-alpine@sha256:049b8d8356efceb93c91ed42866de890534310bcef4ad4dde902029e4a0d20c3 AS runtime
RUN docker-php-ext-install opcache
# @SERVICE_SETUP@
WORKDIR /var/www
COPY --from=vendor /app/vendor ./vendor
COPY . .
COPY docker/opcache.ini /usr/local/etc/php/conf.d/opcache.ini
# A bare port: unprivileged, and no TLS, which belongs to the proxy in front.
ENV SERVER_NAME=:8080
# Nothing reads storage/logs in a container; the readiness probe logs failures.
ENV LOG_CHANNEL=stderr
# Caddy will not start without writable config and data dirs, and www-data
# must write storage/ and bootstrap/cache/ that COPY left owned by root.
ENV XDG_CONFIG_HOME=/config XDG_DATA_HOME=/data
RUN mkdir -p /config /data \
 && chown -R www-data:www-data /config /data \
      /var/www/storage /var/www/bootstrap/cache
USER www-data
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s \
  CMD wget -qO- http://localhost:8080/up || exit 1
# The base image's args, restated: CMD replaces them, and without the Caddyfile
# only the admin API starts and nothing listens on 8080.
CMD ["frankenphp", "run", "--config", "/etc/frankenphp/Caddyfile", "--adapter", "caddyfile"]
