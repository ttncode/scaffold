# shellcheck shell=bash
# Self-contained rather than sourcing services/shared/: redis is the only
# cache, so a shared body would have exactly one caller. Extract one when a
# second cache arrives.
service_driver_apply() {
  # apply_service_drivers runs this in its own `bash -e` process, so a
  # fallible command left unchecked here is caught there too — `|| return 1`
  # stays anyway: it names the failure at the point it happens instead of
  # leaving that to the caller's generic message.
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
