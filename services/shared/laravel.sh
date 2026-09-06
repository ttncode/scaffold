# shellcheck shell=bash
# The Laravel database driver. A service's drivers/laravel.sh sets the
# parameters below and sources this, so the logic lives once and each service
# records only what is different about it. mysql and postgres only — mongodb
# is self-contained (drivers/laravel.sh): a DSN and a config/database.php edit
# differ in kind from these decomposed credentials.
#
#   LARAVEL_CONNECTION    the DB_CONNECTION value
#   LARAVEL_PORT           the default port for .env.example
#   LARAVEL_PACKAGE        a composer package to require, or ""
#   LARAVEL_SETUP          the Dockerfile block, or ""
#   LARAVEL_COMPOSE_ENV    the compose.yaml app environment lines this family
#                          needs beyond DB_CONNECTION, e.g. DB_HOST/DB_PORT

service_driver_apply() {
  # apply_service_drivers runs this in its own `bash -e` process, so a
  # fallible command left unchecked here is caught there too — `|| return 1`
  # stays anyway: it names the failure at the point it happens instead of
  # leaving that to the caller's generic message.
  if [ -n "$LARAVEL_PACKAGE" ]; then
    composer require "$LARAVEL_PACKAGE" --no-interaction || return 1
  fi

  # localhost, not the compose service name: .env.example describes host-side
  # `mise run dev` (see docs/tour/08-adapters.md), which reaches the database
  # through compose.dev.yaml's published port, not the compose network.
  write_env_lines .env.example \
    "DB_CONNECTION=${LARAVEL_CONNECTION}" \
    "DB_HOST=localhost" \
    "DB_PORT=${LARAVEL_PORT}" \
    "DB_DATABASE=app" \
    "DB_USERNAME=app" \
    "DB_PASSWORD=app" \
    || return 1

  # APP_KEY has no service to come from — it is per-family, not per-service —
  # so no env.fragment can carry it, and the project's example.env (assembled
  # from those fragments, before this runs) never sees it any other way.
  # Without a value here, compose.yaml's `APP_KEY: ${APP_KEY}` interpolates to
  # empty and laravel refuses to boot.
  write_env_lines "${SCAFFOLD_PROJECT_ROOT}/example.env" "APP_KEY=changeme" || return 1

  # laravel has no provider-agnostic read across the SQL connections this file
  # serves — `select 1` is the one this task settled on. Written here rather
  # than in the route itself so the shipped file carries exactly one probe,
  # for the connection this project actually has.
  #
  # Two separate substitutions, not one: splicing the probe in above the
  # shipped `throw` would leave that throw as dead code below a path that
  # always returns first. The throw is replaced in place instead, so a
  # --db none project keeps it — unreachable in no project this driver ever
  # touches.
  sed -i.bak 's|// @DB_PROBE@|\\Illuminate\\Support\\Facades\\DB::connection()->select(\x27select 1\x27);|' \
    routes/health.php || return 1
  sed -i.bak "s|throw new \\\\RuntimeException('no database is configured for this project');|return response()->json(['status' => 'ok']);|" \
    routes/health.php || return 1
  rm -f routes/health.php.bak

  grep -q 'DB::connection()->select' routes/health.php \
    && grep -q "return response()->json(\['status' => 'ok'\]);" routes/health.php \
    || die "could not splice the database probe into routes/health.php — has the anchor moved?"
}

service_driver_dockerfile() {
  [ -z "$LARAVEL_SETUP" ] || printf '%s\n' "$LARAVEL_SETUP"
}

# DB_CONNECTION first and always: config/database.php defaults to sqlite, so
# its absence is not an error, it is a silent wrong answer. DB_DATABASE,
# DB_USERNAME and DB_PASSWORD reach the container through compose.yaml's
# env_file already (they are in the project's example.env, assembled from
# this service's own env.fragment) — only what laravel does not otherwise
# know (the connection name, the host, the key) needs adding here.
service_driver_compose_env() {
  printf 'DB_CONNECTION: %s\n' "$LARAVEL_CONNECTION"
  printf '%s\n' "$LARAVEL_COMPOSE_ENV"
  printf 'APP_KEY: ${APP_KEY}\n'
}
