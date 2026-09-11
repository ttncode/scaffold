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
  separate from the FrankenPHP runtime stage, and the comment explaining
  why FrankenPHP replaced php-fpm: php-fpm speaks FastCGI, this stack has
  no reverse proxy in front of it, and the check that used to ship here —
  `php -r 'exit(0);'` — only proved the PHP binary starts, never failed a
  review or CI because it could not fail *at all*, and was removed outright
  rather than kept. That argument still holds: a check that can never fail
  is worse than no check — an orchestrator with none at least knows it
  doesn't know a container's state; one with an always-green check believes
  it does, and routes real traffic to a dead container on that false
  confidence. What changed is the premise underneath it, not the argument
  (ADR-0014, ADR-0021): FrankenPHP serves real HTTP, so
  `HEALTHCHECK … CMD wget -qO- http://localhost:8080/up` is a check that can
  actually fail.
- `adapters/nestjs/Dockerfile` — the same shape, for contrast: its
  `HEALTHCHECK` probes `/health/live`, the route
  `adapters/nestjs/src/health/health.controller.ts` ships.
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
- `lib/service.sh`'s `add_app_service` and `lib/project.sh`'s
  `register_image_target`: one compose service and one image per application,
  named after the application's own directory (ADR-0022). Until that ADR the
  build and release workflows named one `apps/<role>` directory per project,
  so `--web nextjs --api nestjs` published only whichever adapter was applied
  last and the other was never built at all.

## Delete test

Delete the `HEALTHCHECK` line from `adapters/nestjs/Dockerfile` (or any
other adapter's) and something notices now: `tests/compose.bats` asserts
every adapter Dockerfile has `EXPOSE 8080`, a `HEALTHCHECK`, and that the
`HEALTHCHECK` probes the exact path the adapter's own `adapter.env`
declares. Point it at a path nothing serves instead of deleting it, and the
same assertion still catches it — that is the `nestjs` defect ADR-0021
records: it probed `/health`, which no adapter has ever served, for as long
as this repository existed, and nothing here noticed until this test was
written to compare the two values.

What that test still cannot catch: whether the process behind the probe
ever answers for real. It reads Dockerfile text; it never builds an image
or starts a container. ADR-0021 records two defects invisible to every
static check in this repository, found only once something actually ran
the image — FrankenPHP's `CMD` silently dropping the base image's default
arguments (nothing listened on 8080 while `EXPOSE`/`HEALTHCHECK` both still
read correctly), and `nextjs` binding to an address its own `HEALTHCHECK`
could never dial. Only `scripts/deploy-check.sh`, the deploy gate, starts a
container, which is what closes that gap. If you're adding a `HEALTHCHECK`
to a new adapter, delete-test it the way that gate does: stop the process
the check is supposed to detect, and confirm the check actually goes
unhealthy — the laravel lesson above is what happens when nobody does.

## Try it

```bash
docker compose -f common/compose.dev.yaml config --quiet && echo "compose.dev.yaml is valid"
```
