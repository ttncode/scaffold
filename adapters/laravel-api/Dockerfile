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
HEALTHCHECK --interval=30s --timeout=3s \
  CMD php -r 'exit(0);'
CMD ["php-fpm"]
