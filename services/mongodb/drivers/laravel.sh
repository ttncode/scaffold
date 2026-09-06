# shellcheck shell=bash
# Self-contained rather than sourcing services/shared/laravel.sh: mongodb
# wires a DSN and a config/database.php connection instead of the decomposed
# DB_HOST/DB_PORT/DB_USERNAME/DB_PASSWORD every relational driver shares —
# parameterising the shared body five ways for one caller costs more than a
# second honest file.
service_driver_apply() {
  # apply_service_drivers runs this in its own `bash -e` process, so a
  # fallible command left unchecked here is caught there too — `|| return 1`
  # stays anyway: it names the failure at the point it happens instead of
  # leaving that to the caller's generic message.
  #
  # The platform override has to be recorded in composer.lock BEFORE
  # `composer require` runs, not after: it is what lets `composer require`
  # (here, with no mongodb extension on this host) and a later from-scratch
  # `composer install` (the Docker vendor stage, same situation) both resolve
  # laravel-mongodb without --ignore-platform-req. Setting it after the lock
  # exists does not work.
  #
  # 1.21.0 has to stay the version `pecl install mongodb` actually builds in
  # service_driver_dockerfile below: that call has no version pin of its own
  # (pecl always resolves latest), so a newer extension release moves the
  # image out from under this number with nothing here to notice.
  composer config platform.ext-mongodb 1.21.0 --no-interaction || return 1
  composer require mongodb/laravel-mongodb --no-interaction || return 1

  write_env_lines .env.example \
    "DB_CONNECTION=mongodb" \
    "DB_URI=mongodb://app:app@database:27017/app?authSource=admin" \
    "DB_DATABASE=app" \
    || return 1

  register_mongodb_connection config/database.php

  # APP_KEY has no service to come from — it is per-family, not per-service —
  # so no env.fragment can carry it, and the project's example.env (assembled
  # from those fragments, before this runs) never sees it any other way.
  # Without a value here, compose.yaml's `APP_KEY: ${APP_KEY}` interpolates to
  # empty and laravel refuses to boot.
  write_env_lines "${SCAFFOLD_PROJECT_ROOT}/example.env" "APP_KEY=changeme" || return 1

  # mongodb has no SQL to run a `select 1` against — a ping command is the
  # provider-agnostic equivalent laravel-mongodb actually exposes.
  #
  # Two separate substitutions, not one: splicing the probe in above the
  # shipped `throw` would leave that throw as dead code below a path that
  # always returns first. The throw is replaced in place instead, so a
  # --db none project keeps it — unreachable in no project this driver ever
  # touches.
  sed -i.bak 's|// @DB_PROBE@|\\Illuminate\\Support\\Facades\\DB::connection(\x27mongodb\x27)->getMongoDB()->command([\x27ping\x27 => 1]);|' \
    routes/health.php || return 1
  sed -i.bak "s|throw new \\\\RuntimeException('no database is configured for this project');|return response()->json(['status' => 'ok']);|" \
    routes/health.php || return 1
  rm -f routes/health.php.bak

  grep -q "DB::connection('mongodb')->getMongoDB()->command" routes/health.php \
    && grep -q "return response()->json(\['status' => 'ok'\]);" routes/health.php \
    || die "could not splice the database probe into routes/health.php — has the anchor moved?"
}

service_driver_dockerfile() {
  # pecl, not apk: the mongodb extension is not in alpine's repositories, so
  # it is built here — which is why this block installs the build
  # dependencies and nothing else does.
  #
  # Pinned to 1.21.0, matching platform.ext-mongodb above: an unpinned
  # `pecl install mongodb` resolves whatever is latest at build time, and
  # 2.x is not that — mongodb/mongodb's BSONArray/BSONDocument model classes
  # declare bsonSerialize() against the 1.x extension's signature, and the
  # 2.x extension changed it, so any code path that loads those classes (a
  # bare `new MongoDB\Client(...)`, no Laravel involved) is a PHP fatal
  # error, not an exception this project's own try/catch can see. Measured
  # by generating this project with mongodb and hitting /health/ready on a
  # running container: 500 before this pin, 200 after.
  printf '%s\n' \
    'RUN apk add --no-cache --virtual .build-deps $PHPIZE_DEPS openssl-dev \' \
    ' && pecl install mongodb-1.21.0 \' \
    ' && docker-php-ext-enable mongodb \' \
    ' && apk del .build-deps'
}

# DB_CONNECTION first and always: config/database.php defaults to sqlite, so
# its absence is not an error, it is a silent wrong answer. DB_USERNAME and
# DB_PASSWORD reach the container through compose.yaml's env_file already
# (they are in the project's example.env, assembled from this service's own
# env.fragment) — DB_URI still needs assembling here because laravel-mongodb
# reads one DSN string, not decomposed host/port credentials.
service_driver_compose_env() {
  printf 'DB_CONNECTION: mongodb\n'
  printf 'DB_URI: ${DB_URI:-mongodb://${DB_USERNAME:-app}:${DB_PASSWORD}@database:27017/${DB_DATABASE:-app}?authSource=admin}\n'
  printf 'APP_KEY: ${APP_KEY}\n'
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
