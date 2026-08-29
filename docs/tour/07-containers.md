# 07 — Containers

## What it does

Every adapter ships a multi-stage Dockerfile that builds a client's
deployable image without ever containing that client's real configuration.
Three Compose files exist alongside it for three different purposes: the
production-like stack a client actually runs, a throwaway database for
local development, and a tmpfs database for CI and test runs — same shape,
different lifetimes.

## Read this

- `adapters/laravel-api/Dockerfile` — vendor stage (`composer install`)
  separate from the runtime stage, and the comment explaining why it ships
  with no `HEALTHCHECK` at all.
- `adapters/nestjs/Dockerfile` — a real HTTP `HEALTHCHECK`, for contrast.
- `common/compose.yaml`, `common/compose.dev.yaml`, `common/compose.test.yaml`
  — same `database` service, three different lifetimes.
- ADR-0014 for the seven seams a real deploy target plugs into later
  (published image, environment-only configuration, parameterised
  `IMAGE_TAG`, health checks, and more).

## Delete test

The `laravel-api` and `laravel-inertia` Dockerfiles used to ship a
`HEALTHCHECK` that ran `php -r 'exit(0);'`. It never failed a review and
never failed CI, because it could not fail *at all* — it only proved the
PHP binary starts, not that php-fpm is serving requests. It was removed
outright rather than kept, on the reasoning that a health check that can
never fail is worse than no health check: an orchestrator with no
`HEALTHCHECK` at least knows it doesn't know a container's state; one with
an always-green check believes it does, and routes real traffic to a dead
container on that false confidence. If you're adding a `HEALTHCHECK` to a
new adapter, delete-test it yourself first: stop the process the check is
supposed to detect, and confirm the check actually goes unhealthy.

## Try it

```bash
docker compose -f common/compose.dev.yaml config --quiet && echo "compose.dev.yaml is valid"
```
