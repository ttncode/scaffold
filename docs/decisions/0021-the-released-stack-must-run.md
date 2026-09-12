# 0021 — The released stack must run

Status: Accepted
Date: 2026-09-06

## Context

An acceptance run on 2026-09-05 took four freshly generated projects through
the whole walkthrough on real private repositories, then, for the first
time, started the stack those projects publish. It did not work, in any
shape: no `DATABASE_URL` reached the app, the Laravel images ended at
`php-fpm` with no web server in front of it, `compose.yaml` published port
8080 while every adapter listened somewhere else, and `nestjs`'s
`HEALTHCHECK` probed `/health`, a route no adapter has ever shipped. ADR-0014
built the seams a deploy target plugs into later; nothing had proven the
image sitting at those seams actually runs.

## Decision

**Two gates, both mechanically checkable, both now enforced by
`.github/workflows/adapters.yml`'s `deploy`/`deploy-tier-b` jobs alongside
the existing `smoke` lane:**

1. **Green immediately.** Generate, clone, run every config root's
   `ci-unit` in the clone. Already held as of 2026-09-05; unchanged here.
2. **Deployable immediately.** Generate, build the image using the
   `context`/`dockerfile` pair the generated `build.yml` names, run the
   released stack's own start-up sequence against it, then: the **liveness
   path** returns 200 (the container serves HTTP on the port compose
   publishes), and the **readiness path** returns 200 where the adapter
   declares one. `scripts/deploy-check.sh` is gate 2's implementation. It
   builds the image locally and starts the stack directly rather than
   running `common/install.sh` end to end — it does not download a
   release, call `create_directory`, or check `require_configured_image` —
   but it does call `install.sh`'s own `generate_service_passwords` on the
   copied `.env`, so the password loop and the `APP_KEY` branch run under
   the same substitution a client's install would perform, not against
   every credential left at `changeme`. It also does not call
   `install.sh`'s `run_migrations`: the gate carries its own second
   implementation (`scripts/deploy-check.sh`'s own migrate block), and the
   two have already drifted — `install.sh` falls back to checking for a
   `database` service when no `migrate` service is found, the gate falls
   back to the adapter's own `ROLE`/`DB_SERVICE`. Unifying them is deferred
   until a real-project run has exercised `install.sh` against a published
   release.

   **Update, 2026-09-07.** That evidence now exists: `install.sh` ran end
   to end against two real published projects (`laravel-api`+mongodb,
   `nestjs`+postgres) and its `run_migrations` worked both times — the
   only copy anyone has watched run. `scripts/deploy-check.sh` now calls
   it instead of carrying a second copy. The gate's own `ROLE`/`DB_SERVICE`
   check stays, beside the shared call, rather than folding into
   `install.sh`: it is known before the project is even generated, so it
   catches a driver dropping the `database` and `migrate` services
   together — a case `install.sh`'s own compose.yaml-grepping fallback,
   reading the same artifact under test, would not — and `install.sh` is a
   client artifact with no concept of an adapter's `ROLE` to push that
   check into.

**The container port is fixed at 8080, not a variable.** Every adapter
serves HTTP on container port 8080; `common/compose.yaml` publishes
`${APP_PORT:-8080}:8080` and nothing rewrites it per-adapter (ADR-0022 later
replaced that single service with one per application, each on its own
`<NAME>_PORT`; the container side is still 8080 for every adapter). The
alternative — teaching compose each adapter's port through an
`APP_CONTAINER_PORT` written at generation time — is rejected for the same
reason ADR-0014 rejected a parameterised `IMAGE_REPOSITORY`:

> the repository path does not vary release to release the way the tag
> does — it is set once and never touched again, so a variable buys
> nothing a literal placeholder with a comment does not already give, at
> the cost of one more name to keep straight in `.env`.

A container port is exactly that kind of value: fixed for the life of a
generated project the moment its adapter is chosen, never touched again,
and a variable would only add a place for the default to drift from the
one true value. The cost is real and stated on the line that sets it: an
engineer running the image by hand gets 8080, not the port their
framework's own docs name.

**FrankenPHP, alpine, pinned by digest, serves the Laravel images.**
`php-fpm` speaks FastCGI; this stack has no reverse proxy in front of it, so
nothing served HTTP at all. FrankenPHP is the only option that serves PHP
*and* the Vite assets in `public/build` *and* keeps the stack at one
container — a nginx sidecar would need a genuinely new kind of service in
`lib/service.sh`, one `app` both depends on and shares a volume with, which
this decision declines to build for a problem FrankenPHP already solves in
two Dockerfiles. It is not a guess: FrankenPHP has its own section in
`laravel.com/docs/13.x/deployment`, has been part of the PHP Foundation
since May 2025, runs Laravel Cloud, and Shopware has run it in production
for over a year. Alpine is not optional here —
`services/mongodb/drivers/laravel.sh` emits `apk add`, and the mongodb
driver would silently break on a base image that has no `apk`.

**Configuration stays environment-only, composed from one password.**
`compose.yaml`'s `app` service gains an `environment:` block, written by
the selected service's driver (`service_driver_compose_env`, beside the
existing `service_driver_dockerfile`), because the shape is per adapter
family — Prisma wants one `DATABASE_URL`; Laravel wants `DB_CONNECTION`
plus a DSN and falls back to sqlite without it — and a compose fragment
belongs to a service, not a family. Each value defaults from the same
`DB_*`/`APP_KEY` variables `.env` already carries
(`DATABASE_URL: ${DATABASE_URL:-postgresql://...${DB_PASSWORD}@database:...}`),
and an operator's own `DATABASE_URL` in `.env` wins without the default ever
being evaluated — measured against a real `docker compose config`. The
password exists in exactly one place. The rejected alternative — a driver
writing a literal `DATABASE_URL=…` into `example.env` — puts the same
password in two places and asks `install.sh`'s independently-randomised
passwords to stay equal by coincidence: the `changeme`-versus-`app` defect
the 2026-09-05 run measured, reintroduced in a new costume.

**Each adapter declares a liveness path and, where it can hold a database,
a readiness path** (`ADAPTER_LIVENESS_PATH` / `ADAPTER_READINESS_PATH` in
`adapter.env`), read by both the `HEALTHCHECK` and `scripts/deploy-check.sh`
so the two can never disagree about the route the way `nestjs`'s
`HEALTHCHECK` and its generator once did. Readiness runs one query and
reports it — `select 1` for a SQL connection, a ping command for mongodb —
returning 200 when it succeeds and 503 when it does not. **State plainly
what that proves and what it does not**: a request that reaches the
readiness route and gets a 200 has proven the listener, the environment
contract, the compose network and the credentials — four of the five links
in the chain a deploy needs. It has not proven the schema. The probe
succeeds against an empty database exactly as readily as a migrated one,
and for `nestjs` with `mongodb`, `db push` records no migration state at
all for anything to read back. The schema is proven separately: the gate
and `install.sh` both require the `migrate` service to exit 0, and a
database-bearing adapter with no `migrate` service in `compose.yaml` is
treated as a failure, not a shape with nothing to migrate. `nextjs` ships
no readiness route at all — the `web` role takes no database driver, and a
route that returns 200 without querying anything is the same
check-that-cannot-fail this record spends the next section naming.

**The Nest runtime image carries the Prisma CLI, at a size cost, so it can
migrate itself.** `services/shared/nest.sh` installs `prisma` as a regular
dependency, not a dev dependency, specifically so `pnpm prune --prod`
leaves its binary and query engines in the runtime image the released
stack actually ships. The alternative — a second image, or a compose
service that mounts source, built only to run a migration once per deploy —
introduces a build artifact the release does not otherwise publish, for a
command that already has a home: `compose.yaml`'s `migrate` service, run
under a `migrate` compose profile so it never starts with the stack, using
the same image and environment `app` does. `install.sh` runs it once,
visibly, after the stack is up — ADR-0014 seam 5's constraint (no
entrypoint runs a migration on every start) still holds; a human running
one command on the target host is the one deploy mechanism that ADR-0014
says exists today.

## What running one revealed

Two things emerged only from doing this work, not from planning it, and are
worth keeping for the next person who touches this seam.

**The same defect shape, five times.** Each was a check that could not
fail: `lib/lint.sh`'s readiness-path enforcement had no test that failed
when the enforcement itself was deleted; the Nest post-generate wiring step
exited 0 whether or not its anchor `sed` actually matched, silently able to
ship an unregistered health route on a future generator reformat; nothing
asserted the Nest migrate command's `$$`-escaping, so tidying it to a
single `$` would have broken every Nest migration with no test to catch it;
`lib/lint.sh` still only checks that an `ADAPTER_*_PATH` line exists, not
that it names a real route; and the sharpest instance sat inside the gate
built to prevent exactly this class of defect — the deploy gate's migration
assertion was originally gated on a condition read from the same artifact
under test, so deleting the `migrate` service turned a required check into
a printed skip, and the run went green with an unmigrated schema. **Two of
the five were found only by starting a container — something nothing in
this repository had ever done before this gate.** FrankenPHP's `CMD`
silently dropped the base image's default arguments, leaving nothing
listening on 8080 while every static assertion (`EXPOSE 8080`, `HEALTHCHECK`
present) still passed; only building the image and starting it showed the
port was dead. And `nextjs`'s bundled server binding, below.

**`nextjs` bound to the wrong address, for two independent reasons.** Its
standalone `server.js` binds to `process.env.HOSTNAME || '0.0.0.0'`, and
Docker sets `HOSTNAME` to the container's own id for every container — so
without `ENV HOSTNAME="0.0.0.0"`, the server listened on an address its own
`HEALTHCHECK` could never dial. Fixing that exposed a second, independent
cause behind the same symptom: `0.0.0.0` is an IPv4-only bind, but this
image's resolver hands `wget` the IPv6 `::1` first for `localhost`, and
busybox `wget` does not fall back to the IPv4 result — so the `HEALTHCHECK`
still failed, for a different reason, after the first fix landed. Neither
was visible from Dockerfile text; both only showed up once something
actually ran the image.

## Consequences

- Every adapter's runtime image serves HTTP on 8080 with a `HEALTHCHECK`
  that probes the path the adapter itself declares, and `tests/compose.bats`
  asserts all three (`EXPOSE 8080`, `HEALTHCHECK` present, the probed path
  matches `adapter.env`) statically, cheaply, on every change — while
  knowing those static assertions cannot catch the two defects above; only
  the deploy gate, which starts a container, can.
- A generated project's `compose.yaml`, `example.env` and (for adapters that
  need one) `mise.toml` migrate task all changed to carry the environment
  contract and the migration path this record describes;
  `docs/tour/07-containers.md` and
  `docs/runbook/first-project-walkthrough.md` were amended to stop
  describing the stack that predated this work.
- ADR-0014's seam 1 (one image to run) and seam 4 (no healthcheck is
  possible for a FastCGI service) are both superseded in part; ADR-0014
  itself records where.
- ADR-0003's boundary — an adapter overlays configuration, never writes
  application code — narrows to admit exactly the health routes this
  record's gate requires, and nothing else; ADR-0003 records the exception.
- **One image per project still stands.** A `web`+`api` project deploys
  only the role that won `set_image_context` (the last one on the command
  line); the gate tests that image, and the application beside it is
  generated and checked, never deployed. Unchanged by this record, and
  worth restating because gate 2 looks like it covers a project when it
  covers one image.

  *Superseded 2026-09-11 by ADR-0022, and fully retired 2026-09-12.* A project
  publishes one image per application and runs one compose service per
  application; `scripts/deploy-check.sh` now takes more than one adapter,
  builds every target the project publishes, waits for each container, and
  curls each application on its own port. Gate 2 covers a project again, not
  one image.
- **A readiness route is application code a client may delete.** Nothing
  detects that later. The gate tests generated projects, not a client's
  repository six months on.

## Alternatives considered

- **A nginx sidecar in front of php-fpm**, keeping FastCGI. Rejected: needs
  a new service kind in `lib/service.sh` — one `app` both depends on and
  shares a volume with — plus a shipped `nginx.conf` and moving the port
  publish off `app`. FrankenPHP changes two Dockerfiles and nothing else.
- **Octane**, running FrankenPHP in worker mode. Rejected for now: worker
  mode makes client request-handling code stateful by default and hands the
  client Laravel's own memory-leak-management burden, for a throughput
  problem no client has yet reported. Moving to it later is a one-line
  `ENTRYPOINT` change on the same pinned base image.
- **A per-adapter `APP_CONTAINER_PORT` variable**, matching how `IMAGE_TAG`
  varies. Rejected for the reason quoted above from ADR-0014: the value
  does not vary the way a tag does, so a variable only adds a place for the
  default to drift.
- **A driver writing a literal `DATABASE_URL` into `example.env`.**
  Rejected: puts the same password in two places instead of one, which is
  the exact defect class this record's environment contract exists to
  close.
- **A schema marker read back per provider**, so readiness could prove
  migration too. Rejected: mongodb's `db push` records no migration state
  for anything to read, so a marker would need inventing per provider for a
  property the gate already proves a cheaper way — requiring `migrate` to
  exit 0.
- **A second image, or a compose service mounting source, to run Nest's
  migration.** Rejected: introduces a build artifact the release does not
  otherwise publish, for a command run once per deploy; carrying the
  Prisma CLI's size cost in the one image already published is smaller.
