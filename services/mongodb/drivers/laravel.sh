# shellcheck shell=bash
# ═══════════════════════════════════════════════════════════════════════════
# Script      : services/mongodb/drivers/laravel.sh
# Description : How Laravel talks to MongoDB.
# Author      : ttncode
# ═══════════════════════════════════════════════════════════════════════════
# Self-contained rather than sourcing services/shared/laravel.sh: mongodb wires
# a DSN and a config/database.php connection instead of the decomposed
# DB_HOST/DB_PORT/DB_USERNAME/DB_PASSWORD every relational driver shares.
service_driver_apply() {
  # Recorded in composer.lock BEFORE `composer require`, never after: it is what
  # lets both this call and the Docker vendor stage's from-scratch `composer
  # install` resolve laravel-mongodb with no mongodb extension on the host.
  #
  # 1.21.0 must stay the version service_driver_dockerfile builds below.
  composer config platform.ext-mongodb 1.21.0 --no-interaction || return 1
  composer require mongodb/laravel-mongodb --no-interaction || return 1

  write_env_lines .env.example \
    "DB_CONNECTION=mongodb" \
    "DB_URI=mongodb://app:app@database:27017/app?authSource=admin" \
    "DB_DATABASE=app" \
    || return 1

  register_mongodb_connection config/database.php

  # APP_KEY is per-family, not per-service, so no env.fragment can carry it into
  # the project's example.env. Without a value here, compose.yaml's
  # `APP_KEY: ${APP_KEY}` interpolates to empty and laravel refuses to boot.
  write_env_lines "${SCAFFOLD_PROJECT_ROOT}/example.env" "APP_KEY=changeme" || return 1

  # mongodb has no SQL to run a `select 1` against; ping is what
  # laravel-mongodb exposes.
  #
  # The throw is replaced in place rather than left below the probe: pint
  # rejects dead code after a path that always returns. The class arrives as a
  # short name with its own `use`, because pint's fully_qualified_strict_types
  # rejects an inline FQCN once the file has imports — and a --db none project
  # runs neither substitution, so it keeps both the throw and the FQCN.
  sed -i.bak 's|use Illuminate\\Support\\Facades\\Route;|use Illuminate\\Support\\Facades\\DB;\nuse Illuminate\\Support\\Facades\\Route;|' \
    routes/health.php || return 1
  sed -i.bak 's|// @DB_PROBE@|DB::connection(\x27mongodb\x27)->getMongoDB()->command([\x27ping\x27 => 1]);|' \
    routes/health.php || return 1
  # Matched with its leading indentation so the replacement's `\n` opens a bare
  # blank line, which is what pint's blank_line_before_statement wants here.
  sed -i.bak "s|        throw new RuntimeException('no database is configured for this project');|\\n        return response()->json(['status' => 'ok']);|" \
    routes/health.php || return 1
  rm -f routes/health.php.bak

  grep -q "DB::connection('mongodb')->getMongoDB()->command" routes/health.php \
    && grep -q "return response()->json(\['status' => 'ok'\]);" routes/health.php \
    || die "could not splice the database probe into routes/health.php — has the anchor moved?"
}

service_driver_dockerfile() {
  # pecl, not apk: the extension is not in alpine's repositories, which is why
  # this block installs build dependencies and nothing else does.
  #
  # Pinned to 1.21.0, matching platform.ext-mongodb above. mongodb/mongodb's
  # BSONArray/BSONDocument declare bsonSerialize() against the 1.x signature and
  # the 2.x extension changed it, so any code path loading those classes is a
  # PHP fatal error, not an exception this project's try/catch can see — a 500
  # on /health/ready before this pin.
  printf '%s\n' \
    'RUN apk add --no-cache --virtual .build-deps $PHPIZE_DEPS openssl-dev \' \
    ' && pecl install mongodb-1.21.0 \' \
    ' && docker-php-ext-enable mongodb \' \
    ' && apk del .build-deps'
}

# DB_CONNECTION first and always: config/database.php defaults to sqlite, so its
# absence is a silent wrong answer. DB_URI is assembled here because
# laravel-mongodb reads one DSN string, not decomposed credentials.
service_driver_compose_env() {
  printf 'DB_CONNECTION: mongodb\n'
  printf 'DB_URI: ${DB_URI:-mongodb://${DB_USERNAME:-app}:${DB_PASSWORD}@database:27017/${DB_DATABASE:-app}?authSource=admin}\n'
  printf 'APP_KEY: ${APP_KEY}\n'
}

# laravel-mongodb provides its own Schema grammar, so the same artisan command
# the SQL connections use also migrates a mongodb-backed project.
service_driver_compose_migrate() {
  printf 'command: ["php", "artisan", "migrate", "--force"]\n'
}

# register_mongodb_connection <path/to/config/database.php>
# laravel-mongodb needs a 'mongodb' entry in the connections array; the Laravel
# skeleton ships none. Insert-then-verify, like register_config_root: an anchor
# that stops matching after a skeleton upgrade must fail loudly here, not ship
# an app whose DB_CONNECTION names a connection that does not exist.
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
