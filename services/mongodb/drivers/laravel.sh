# shellcheck shell=bash
# Self-contained rather than sourcing services/shared/laravel.sh: mongodb
# wires a DSN and a config/database.php connection instead of the decomposed
# DB_HOST/DB_PORT/DB_USERNAME/DB_PASSWORD every relational driver shares —
# parameterising the shared body five ways for one caller costs more than a
# second honest file.
service_driver_apply() {
  # This runs inside `( ... ) || die` (apply_service_drivers), which disables
  # `set -e` for everything in the subshell — a fallible command left
  # unchecked here keeps running and its failure vanishes.
  #
  # The platform override has to be recorded in composer.lock BEFORE
  # `composer require` runs, not after: it is what lets `composer require`
  # (here, with no mongodb extension on this host) and a later from-scratch
  # `composer install` (the Docker vendor stage, same situation) both resolve
  # laravel-mongodb without --ignore-platform-req. Setting it after the lock
  # exists does not work.
  composer config platform.ext-mongodb 1.21.0 --no-interaction || return 1
  composer require mongodb/laravel-mongodb --no-interaction || return 1

  write_env_lines .env.example \
    "DB_CONNECTION=mongodb" \
    "DB_URI=mongodb://app:app@database:27017/app?authSource=admin" \
    "DB_DATABASE=app" \
    || return 1

  register_mongodb_connection config/database.php
}

service_driver_dockerfile() {
  # pecl, not apk: the mongodb extension is not in alpine's repositories, so
  # it is built here — which is why this block installs the build
  # dependencies and nothing else does.
  printf '%s\n' \
    'RUN apk add --no-cache --virtual .build-deps $PHPIZE_DEPS openssl-dev \' \
    ' && pecl install mongodb \' \
    ' && docker-php-ext-enable mongodb \' \
    ' && apk del .build-deps'
}

# register_mongodb_connection <path/to/config/database.php>
# laravel-mongodb needs a 'mongodb' entry in the connections array; the
# Laravel skeleton ships none. Same insert-then-verify shape as
# register_config_root in lib/project.sh, for the same reason: an anchor that
# stops matching after a skeleton upgrade must fail loudly here, not ship an
# app whose DB_CONNECTION names a connection that does not exist.
register_mongodb_connection() {
  local file="$1"
  local anchor="    'connections' => ["
  local block="        'mongodb' => [
            'driver' => 'mongodb',
            'dsn' => env('DB_URI', 'mongodb://localhost:27017'),
            'database' => env('DB_DATABASE', 'app'),
        ],"

  ANCHOR="$anchor" BLOCK="$block" awk '
    { print }
    $0 == ENVIRON["ANCHOR"] { print ENVIRON["BLOCK"] }
  ' "$file" > "${file}.tmp"
  mv "${file}.tmp" "$file"

  grep -Fxq "        'mongodb' => [" "$file" \
    || die "the Laravel skeleton's config/database.php no longer has the expected shape"
}
