# shellcheck shell=bash
# ═══════════════════════════════════════════════════════════════════════════
# Script      : services/redis/drivers/nest.sh
# Description : How NestJS talks to Redis.
# Author      : ttncode
# ═══════════════════════════════════════════════════════════════════════════
# Self-contained: redis is the only cache, so a shared body would have exactly
# one caller. Extract one when a second cache arrives.
service_driver_apply() {
  pnpm add @nestjs/cache-manager cache-manager @keyv/redis || return 1

  write_env_lines .env.example "REDIS_URL=redis://:app@localhost:6379" || return 1
}

service_driver_dockerfile() {
  :
}

# Same override-then-compose shape as services/shared/nest.sh's DATABASE_URL:
# an operator's own .env wins, otherwise compose builds the URL from the same
# REDIS_PASSWORD the cache container reads, so the password lives in exactly
# one place.
service_driver_compose_env() {
  printf 'REDIS_URL: ${REDIS_URL:-redis://:${REDIS_PASSWORD}@cache:6379}\n'
}

# a cache has no schema to migrate — printing nothing keeps the migrate
# service absent from a project that selected only a cache.
service_driver_compose_migrate() {
  :
}
