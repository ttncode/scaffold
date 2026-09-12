# shellcheck shell=bash
# ═══════════════════════════════════════════════════════════════════════════
# Script      : services/redis/drivers/laravel.sh
# Description : How Laravel talks to Redis.
# Author      : ttncode
# ═══════════════════════════════════════════════════════════════════════════
# Self-contained: redis is the only cache, so a shared body would have exactly
# one caller. Extract one when a second cache arrives.
service_driver_apply() {
  # predis, not the phpredis extension: a composer package needs no build stage.
  #
  composer require predis/predis --no-interaction || return 1

  write_env_lines .env.example \
    "REDIS_CLIENT=predis" \
    "REDIS_HOST=cache" \
    "REDIS_PORT=6379" \
    "REDIS_PASSWORD=app" \
    "CACHE_STORE=redis" \
    "SESSION_DRIVER=redis" \
    "QUEUE_CONNECTION=redis" \
    || return 1
}

service_driver_dockerfile() {
  :
}

# REDIS_PASSWORD already reaches the container through compose.yaml's env_file,
# so only the host needs adding here.
service_driver_compose_env() {
  printf 'REDIS_HOST: cache\n'
}

# a cache has no schema to migrate — printing nothing keeps the migrate
# service absent from a project that selected only a cache.
service_driver_compose_migrate() {
  :
}
