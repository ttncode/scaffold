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
