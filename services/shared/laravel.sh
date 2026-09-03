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
}

service_driver_dockerfile() {
  [ -z "$LARAVEL_SETUP" ] || printf '%s\n' "$LARAVEL_SETUP"
}
