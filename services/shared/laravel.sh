# shellcheck shell=bash
# ═══════════════════════════════════════════════════════════════════════════
# Script      : services/shared/laravel.sh
# Description : The shared Laravel SQL driver body.
# Author      : ttncode
# ═══════════════════════════════════════════════════════════════════════════
# A service's drivers/laravel.sh sets the parameters below and sources this.
# mysql and postgres only — mongodb is self-contained: a DSN and a
# config/database.php edit differ in kind from these decomposed credentials.
#
#   LARAVEL_CONNECTION   the DB_CONNECTION value
#   LARAVEL_PORT         the default port for .env.example
#   LARAVEL_PACKAGE      a composer package to require, or ""
#   LARAVEL_SETUP        the Dockerfile block, or ""
#   LARAVEL_COMPOSE_ENV  the compose.yaml app environment lines this family
#                        needs beyond DB_CONNECTION, e.g. DB_HOST/DB_PORT

service_driver_apply() {
  if [ -n "$LARAVEL_PACKAGE" ]; then
    composer require "$LARAVEL_PACKAGE" --no-interaction || return 1
  fi

  # localhost, not the compose service name: .env.example describes host-side
  # `mise run dev`, which reaches the database through compose.dev.yaml's
  # published port, not the compose network.
  write_env_lines .env.example \
    "DB_CONNECTION=${LARAVEL_CONNECTION}" \
    "DB_HOST=localhost" \
    "DB_PORT=${LARAVEL_PORT}" \
    "DB_DATABASE=app" \
    "DB_USERNAME=app" \
    "DB_PASSWORD=app" \
    || return 1

  # APP_KEY is per-family, not per-service, so no env.fragment can carry it into
  # the project's example.env. Without a value here, compose.yaml's
  # `APP_KEY: ${APP_KEY}` interpolates to empty and laravel refuses to boot.
  write_env_lines "${SCAFFOLD_PROJECT_ROOT}/example.env" "APP_KEY=changeme" || return 1

  # Spliced here rather than shipped in the route, so the file carries exactly
  # one probe, for the connection this project actually has.
  #
  # The throw is replaced in place rather than left below the probe: pint
  # rejects dead code after a path that always returns. The class arrives as a
  # short name with its own `use`, because pint's fully_qualified_strict_types
  # rejects an inline FQCN once the file has imports — and a --db none project
  # runs neither substitution, so it keeps both the throw and the FQCN.
  sed -i.bak 's|use Illuminate\\Support\\Facades\\Route;|use Illuminate\\Support\\Facades\\DB;\nuse Illuminate\\Support\\Facades\\Route;|' \
    routes/health.php || return 1
  sed -i.bak 's|// @DB_PROBE@|DB::connection()->select(\x27select 1\x27);|' \
    routes/health.php || return 1
  # Matched with its leading indentation so the replacement's `\n` opens a bare
  # blank line, which is what pint's blank_line_before_statement wants here.
  sed -i.bak "s|        throw new RuntimeException('no database is configured for this project');|\\n        return response()->json(['status' => 'ok']);|" \
    routes/health.php || return 1
  rm -f routes/health.php.bak

  grep -q 'DB::connection()->select' routes/health.php \
    && grep -q "return response()->json(\['status' => 'ok'\]);" routes/health.php \
    || die "could not splice the database probe into routes/health.php — has the anchor moved?"
}

service_driver_dockerfile() {
  [ -z "$LARAVEL_SETUP" ] || printf '%s\n' "$LARAVEL_SETUP"
}

# DB_CONNECTION first and always: config/database.php defaults to sqlite, so its
# absence is a silent wrong answer, not an error. The credentials already reach
# the container through compose.yaml's env_file, so only what laravel cannot
# otherwise know — the connection name, the host, the key — is added here.
service_driver_compose_env() {
  printf 'DB_CONNECTION: %s\n' "$LARAVEL_CONNECTION"
  printf '%s\n' "$LARAVEL_COMPOSE_ENV"
  printf 'APP_KEY: ${APP_KEY}\n'
}

# One artisan command covers every connection: mysql, postgres, and mongodb
# through laravel-mongodb's own Schema grammar.
service_driver_compose_migrate() {
  printf 'command: ["php", "artisan", "migrate", "--force"]\n'
}
