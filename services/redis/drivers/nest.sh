# shellcheck shell=bash
# Self-contained rather than sourcing services/shared/: redis is the only
# cache, so a shared body would have exactly one caller. Extract one when a
# second cache arrives.
service_driver_apply() {
  pnpm add @nestjs/cache-manager cache-manager @keyv/redis

  write_env_lines .env.example "REDIS_URL=redis://:app@localhost:6379"
}

service_driver_dockerfile() {
  :
}
