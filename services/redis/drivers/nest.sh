# shellcheck shell=bash
# Self-contained rather than sourcing services/shared/: redis is the only
# cache, so a shared body would have exactly one caller. Extract one when a
# second cache arrives.
service_driver_apply() {
  # This runs inside `( ... ) || die` (apply_service_drivers), which disables
  # `set -e` for everything in the subshell — a fallible command left
  # unchecked here keeps running and its failure vanishes.
  pnpm add @nestjs/cache-manager cache-manager @keyv/redis || return 1

  write_env_lines .env.example "REDIS_URL=redis://:app@localhost:6379" || return 1
}

service_driver_dockerfile() {
  :
}
