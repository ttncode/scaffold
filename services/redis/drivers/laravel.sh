# shellcheck shell=bash
# Self-contained rather than sourcing services/shared/: redis is the only
# cache, so a shared body would have exactly one caller. Extract one when a
# second cache arrives.
service_driver_apply() {
  # predis, not the phpredis extension: a composer package needs no build
  # stage, and this is the only difference between the two for a cache this
  # size.
  composer require predis/predis --no-interaction

  write_env_lines .env.example \
    "REDIS_CLIENT=predis" \
    "REDIS_HOST=cache" \
    "REDIS_PORT=6379" \
    "REDIS_PASSWORD=app" \
    "CACHE_STORE=redis" \
    "SESSION_DRIVER=redis" \
    "QUEUE_CONNECTION=redis"
}

service_driver_dockerfile() {
  :
}
