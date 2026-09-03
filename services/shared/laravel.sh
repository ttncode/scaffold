# shellcheck shell=bash
# The Laravel database driver. A service's drivers/laravel.sh sets the
# parameters below and sources this, so the logic lives once and each service
# records only what is different about it.
#
#   LARAVEL_CONNECTION    the DB_CONNECTION value
#   LARAVEL_PORT           the default port for .env.example
#   LARAVEL_PACKAGE        a composer package to require, or ""
#   LARAVEL_SETUP          the Dockerfile block, or ""
#   LARAVEL_PLATFORM_REQ   --ignore-platform-req value, or "" (default)

: "${LARAVEL_PLATFORM_REQ:=}"

service_driver_apply() {
  if [ -n "$LARAVEL_PACKAGE" ]; then
    if [ -n "$LARAVEL_PLATFORM_REQ" ]; then
      composer require "$LARAVEL_PACKAGE" --no-interaction \
        --ignore-platform-req="$LARAVEL_PLATFORM_REQ"
    else
      composer require "$LARAVEL_PACKAGE" --no-interaction
    fi
  fi

  write_env_lines .env.example \
    "DB_CONNECTION=${LARAVEL_CONNECTION}" \
    "DB_HOST=database" \
    "DB_PORT=${LARAVEL_PORT}" \
    "DB_DATABASE=app" \
    "DB_USERNAME=app" \
    "DB_PASSWORD=app"
}

service_driver_dockerfile() {
  [ -z "$LARAVEL_SETUP" ] || printf '%s\n' "$LARAVEL_SETUP"
}
