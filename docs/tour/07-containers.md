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
  with no `HEALTHCHECK` at all: it used to run `php -r 'exit(0);'`, which
  only proved the PHP binary starts, not that php-fpm is serving requests,
  and never failed a review or CI because it could not fail *at all*. It
  was removed outright rather than kept — a check that can never fail is
  worse than no check: an orchestrator with none at least knows it doesn't
  know a container's state; one with an always-green check believes it
  does, and routes real traffic to a dead container on that false
  confidence.
- `adapters/nestjs/Dockerfile` — a real HTTP `HEALTHCHECK`, for contrast.
- `common/compose.yaml`, `common/compose.dev.yaml`, `common/compose.test.yaml`
  — same `database` service, three different lifetimes.
- ADR-0014 for the seven seams a real deploy target plugs into later
  (published image, environment-only configuration, parameterised
  `IMAGE_TAG`, health checks, and more).

## Delete test

Delete the `HEALTHCHECK` line from `adapters/nestjs/Dockerfile` (or
`nextjs`'s) and nothing here notices: no test in `tests/` asserts a
Dockerfile has one, `mise run checklist` stays green, and
`docker compose up` in `common/compose.yaml` doesn't gate on it either —
only the `database` service's health is wired to `depends_on`. The
consequence only shows up once a client's own deploy target (one of
ADR-0014's seams) actually polls container health before routing traffic:
a slow-starting container gets real requests before it's ready, and
nothing in this repository would have pointed at a missing
`HEALTHCHECK` as the reason. If you're adding one to a new adapter,
delete-test it the other direction first: stop the process the check is
supposed to detect, and confirm the check actually goes unhealthy — the
laravel lesson above is what happens when nobody does.

## Try it

```bash
docker compose -f common/compose.dev.yaml config --quiet && echo "compose.dev.yaml is valid"
```
