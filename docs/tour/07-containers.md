# 07 — Containers

## What it does

Every adapter ships a multi-stage Dockerfile that builds a client's
deployable image without ever containing that client's real configuration.
Three Compose files exist alongside it for three different purposes: the
production-like stack a client actually runs, a throwaway database for
local development, and a tmpfs database for CI and test runs — same shape,
different lifetimes.

`common/compose.yaml`, `common/compose.dev.yaml` and `common/compose.test.yaml`
ship the `app` service alone; a database or cache is not written into any of
them. Each service selected with `--db` or `--cache` merges in a shared body
(`services/<name>/compose.fragment.yaml`) plus its own per-lane delta
(`compose.prod.fragment.yaml`, `.dev.`, `.test.`) into all three files, and
`app`'s `depends_on` gets a `service_healthy` entry for it, in the
production lane only. A project that asked for neither ships neither — no
service nothing opens a connection to (ADR-0019). The image digest lives in
exactly one place, that service's own `service.env`: no compose fragment
carries an `image:` line, `assemble_compose` writes it in during the merge,
and `tests/service.bats` fails a fragment that pins its own.

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
- `lib/service.sh`'s `assemble_compose` — the merge described above, and
  `service_compose_key` for why a fragment must publish under `database` or
  `cache`, not its own service name: `depends_on` names the key, not
  `mysql` or `redis`, so an adapter's driver never has to know which one was
  picked.
- `services/mysql/` for one full service: `service.env` (the pinned digest),
  the four compose fragments, `env.fragment`, and
  `services/mysql/drivers/laravel.sh` / `services/mysql/drivers/nest.sh`.
- ADR-0019 for why services are a category of their own, not a kind of
  adapter, and ADR-0014 for the seven seams a real deploy target plugs into
  later (published image, environment-only configuration, parameterised
  `IMAGE_TAG`, health checks, and more).
- `scaffold`'s `cmd_new`, the comment above its `set_image_context` call:
  the build and release workflows point at one `apps/<role>` directory per
  project, so `--web nextjs --api nestjs` still builds a single image, for
  whichever role's adapter was applied last. Unrelated to services — true
  before this work and unchanged by it.

## Delete test

Delete the `HEALTHCHECK` line from `adapters/nestjs/Dockerfile` (or
`nextjs`'s) and nothing here notices: no test in `tests/` asserts a
Dockerfile has one, `mise run checklist` stays green, and
`docker compose up` in `common/compose.yaml` doesn't gate on it either —
only a selected service's own health is wired to `app`'s `depends_on`, and
only for that service. The consequence only shows up once a client's own
deploy target (one of
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
