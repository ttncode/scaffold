# Deployable Stack — Design

Status: approved for planning
Date: 2026-09-06
Scope: what a generated project's released stack has to do before it counts as
delivered. Deploy targets remain out of scope — see section 3.

## 1. Context

An acceptance run on 2026-09-05 took four freshly generated projects through
the whole walkthrough on real private repositories and then, for the first
time, started the stack those projects publish. It does not work, and never
has, in any shape.

Following `install.sh` against a real published image:

```
$ docker compose exec app node -e "... new PrismaClient(); p.$connect() ..."
error: Environment variable not found: DATABASE_URL.
```

Laravel does not even report an error. `config/database.php` is
`'default' => env('DB_CONNECTION', 'sqlite')`, so with `DB_CONNECTION` absent
it falls back to sqlite and reads the `DB_DATABASE=app` it *did* receive as a
sqlite filename. The mongodb container is never contacted.

Three more, each independently fatal to serving traffic:

- `EXPOSE` says `9000` for both Laravel adapters, `3001` for `nestjs`, `3000`
  for `nextjs`. `common/compose.yaml` publishes `${APP_PORT:-8080}:8080`, and
  nothing in `lib/` or `scaffold` rewrites it. **Container port 8080 matches
  no adapter in this repository.** `install.sh` prints `the application is
  running on http://localhost:8080`, which has never been true for any shape.
- The Laravel images end at `CMD ["php-fpm"]`. php-fpm speaks FastCGI, and
  the stack contains no web server, so nothing in a Laravel project serves
  HTTP at all.
- Both Laravel images `COPY . .` as root and then `USER www-data`, leaving
  `storage/` and `bootstrap/cache` unwritable. The first request that
  compiles a Blade view or writes a log returns 500.
- `nestjs`'s `HEALTHCHECK` probes `/health`, which no adapter ships — the
  NestJS generator produces `/` and nothing else. Every `nestjs` image has
  reported unhealthy from first boot, the same defect found in `nextjs` on
  2026-09-05 and fixed there alone, because only the nextjs Dockerfiles were
  checked.

None of this is a regression. It is a last mile that was specified and never
built: ADR-0014's seam 2 already requires that "every value a container needs
arrives through `env_file`/`environment` at run time". The requirement was
written on 2026-08-27. Nothing was ever made to produce the values.

The reason it survived is the same shape this project keeps meeting: **no
check could fail.** `tests/compose.bats` runs `docker compose config --quiet`,
which validates YAML, not reachability. No test starts a container. 185 tests
and eight whole-branch reviews found none of it; starting the stack once found
all of it.

ADR-0014 is also internally inconsistent, not merely incomplete. Seam 1 says
"a client's target only ever needs to know how to run one image". Seam 4 says
the Laravel images deliberately speak FastCGI, which requires something else
in front of them. Both cannot be true.

## 2. Goals

A project generated today must satisfy two gates, each mechanically checkable
and each currently failing:

1. **Green immediately.** Generate, clone the generated project, run every
   config root's `ci-unit` in the clone. All pass. The clone is the point: a
   working tree keeps artifacts that make the checks pass for the wrong
   reason.
2. **Deployable immediately.** Generate, build the image using the
   `context`/`dockerfile` pair the generated `build.yml` names, run
   `install.sh`'s own sequence, and then:
   - the image's **liveness path** returns 200 — the container serves HTTP on
     the port compose publishes.
   - its **readiness path** returns 200 — a request reaches the database
     through the application, proving the listener, the environment contract,
     the compose network, the credentials and the schema in one call.

Both paths are declared by the adapter (section 7), because they differ per
framework and because two of them are wrong today.

Gate 1 already holds as of the fixes merged on 2026-09-05. Gate 2 holds for
nothing.

## 3. Non-goals

- **A deploy target.** ADR-0014's seven seams stand. This design fills seams
  1, 2 and 4 with working implementations; it adds no `deploy-adapters/` body
  and no automated path from a merged pull request to a running instance.
- **Octane.** FrankenPHP without worker mode. Worker mode makes client code
  stateful by default and hands the client the whole "Managing Memory Leaks"
  section of Laravel's docs. Moving to it later is a one-line `ENTRYPOINT`
  change on the same pinned base image, so choosing against it now costs
  nothing later.
- **Migrations from an entrypoint.** ADR-0014 seam 5 stands: no image runs
  migrations when it starts. `install.sh` runs them once, visibly, as the
  human operator's step — which is a different thing, and the one deploy
  mechanism ADR-0014 says exists today.
- **A second container.** No nginx sidecar, no shared volume, no new service
  kind in `lib/service.sh`.
- **Serving the `web` and `api` roles from one image.** A project still
  builds exactly one image, chosen by the last role on the command line
  (`set_image_context`). Unchanged here.

## 4. The container port contract

Every adapter serves HTTP on container port **8080**.

`common/compose.yaml` already publishes `${APP_PORT:-8080}:8080` and stays
exactly as it is. `nextjs` and `nestjs` already read `PORT` from the
environment, so each Dockerfile sets `ENV PORT=8080`, `EXPOSE 8080`, and a
`HEALTHCHECK` on 8080. The Laravel images get a listener on 8080 (section 5).

The alternative — teaching compose each adapter's port through an
`APP_CONTAINER_PORT` variable written at generation time — is rejected for
the reason this project already recorded when it rejected a parameterised
`IMAGE_REPOSITORY` in ADR-0014: the value is fixed for the life of the
project, so a variable "would only add a place for the default to silently
drift from the real value". A container port is exactly that kind of value.

The cost is real and worth stating: an engineer who runs a generated image by
hand gets 8080, not the 3000 their framework's own documentation names. The
Dockerfile says why, on the line that sets it.

## 5. An HTTP listener in the Laravel images

Both Laravel runtime stages move to **FrankenPHP, alpine, pinned by digest**,
without Octane:

```
FROM dunglas/frankenphp:1.12.7-php8.3-alpine@sha256:049b8d8356efceb93c91ed42866de890534310bcef4ad4dde902029e4a0d20c3
```

Digest verified against the registry on 2026-09-06, not copied from a
secondary source.

**Why FrankenPHP.** It is the only option that serves PHP *and* the Vite
assets in `public/build` *and* keeps the stack at one container. A nginx
sidecar would need a genuinely new concept in `lib/service.sh` — a service
that is neither a database nor a cache, that `app` both depends on and shares
a volume with — plus an `nginx.conf` shipped as a release asset, plus moving
the port publish off the `app` service. FrankenPHP changes two Dockerfiles and
nothing else.

**Evidence, not preference.** FrankenPHP has its own section in
`laravel.com/docs/13.x/deployment`, has been part of the PHP Foundation since
May 2025 (`github.com/php/frankenphp`), and runs Laravel Cloud in production.
Shopware has run it in production for over a year.

**Alpine is not optional.** `services/mongodb/drivers/laravel.sh` emits
`apk add --no-cache $PHPIZE_DEPS && pecl install mongodb`. The bookworm variant
has no `apk`, and the mongodb driver would break on a base image change nobody
associated with it.

Each Laravel runtime stage therefore gains:

- `ENV SERVER_NAME=:8080` — how FrankenPHP listens on an unprivileged port and
  declines to provision TLS, which is the reverse proxy's job wherever this
  lands.
- `ENV XDG_CONFIG_HOME=/config XDG_DATA_HOME=/data`, both owned by `www-data`.
  Caddy writes there and cannot start if it may not.
- `HEALTHCHECK … CMD wget -qO- http://localhost:8080/up || exit 1`. Laravel
  has shipped `/up` since 11.x.

`docker/opcache.ini` is unchanged: FrankenPHP builds on the official PHP
images, so `$PHP_INI_DIR/conf.d` is the same path.

## 6. The environment contract

`compose.yaml`'s `app` service gains an `environment:` block whose values are
composed from the service variables already in `.env`:

```yaml
    environment:
      DATABASE_URL: ${DATABASE_URL:-postgresql://${DB_USERNAME:-app}:${DB_PASSWORD}@database:5432/${DB_DATABASE:-app}}
```

Both paths measured against a real Docker Compose on 2026-09-06: with no
`DATABASE_URL` in `.env` the composed default is produced; with one, the
operator's value wins and the default is not evaluated. That is what lets a
client point at a managed database by adding one line to the file
`install.sh` never overwrites.

**The password exists in exactly one place.** `.env` holds it; compose
interpolates it into the URL at `up` time. The rejected alternative — a driver
writing a literal `DATABASE_URL=…` into `example.env` — puts the password in
two places and asks `install.sh`, which generates an independent random value
per password variable, to keep them equal. That is the `changeme`-versus-`app`
defect the acceptance run measured in the dev stack, reintroduced in a new
costume.

**The shape is per adapter family, not per service.** Prisma wants one
`DATABASE_URL`. Laravel wants `DB_CONNECTION` plus a DSN, and will silently
fall back to sqlite without the first. A compose fragment belongs to a service
and cannot know the family, so the block is produced by the **driver**, which
knows both — a new `service_driver_compose_env`, beside the
`service_driver_dockerfile` that already exists for exactly this reason.

The timing works without reordering anything: `assemble_compose` runs before
any adapter is applied, and `apply_service_drivers` runs inside `apply_adapter`
after the family is known, which is when the block is written.

Laravel additionally needs `APP_KEY`, which no service fragment has any reason
to produce. `install.sh` already generates a random value for every password in
`example.env`; it generates this one too, and `example.env` carries
`APP_KEY=changeme` for it to replace.

## 7. Liveness and readiness paths

Each adapter declares two paths. The `HEALTHCHECK` probes the first; the
deploy gate curls both.

| Adapter | Liveness | Readiness |
|---|---|---|
| `laravel-api` | `/up` (shipped by Laravel since 11.x) | `/health/ready` |
| `laravel-inertia` | `/up` | `/health/ready` |
| `nestjs` | `/health/live` | `/health/ready` |
| `nextjs` | `/` (the generated home page) | none — the `web` role takes no database driver |

**Two of the four are wrong today, in the same way.** `nestjs`'s Dockerfile
probes `http://localhost:3001/health`, and no adapter ships a `/health` route
— the NestJS generator produces `/` returning `Hello World!` and nothing else.
So every `nestjs` image has reported unhealthy from first boot, exactly as
every `nextjs` image did until 2026-09-05. The nextjs one was found and fixed;
this one was missed because only the nextjs Dockerfiles were checked. Both
adapters therefore need a real liveness path, not just a corrected probe.

**Readiness runs one query and reports it:**

```
GET /health/ready  ->  200 when the query succeeds, 503 when it does not
```

This is the only thing that proves the whole chain — listener, environment,
compose network, credentials, schema — in a single call. A liveness path
alone cannot: Laravel's `/up` never touches the database, so a project with a
wrong `DATABASE_URL` passes it. That is precisely the check-that-cannot-fail
ADR-0014 seam 4 warned about, and shipping one as the only gate would repeat
the mistake this design exists to correct.

**This changes ADR-0003's boundary and the ADR must say so.** Until now an
adapter invoked the framework's own generator and overlaid configuration; it
never wrote application code. It does now, for one file per adapter. The
boundary moves from "no application code" to "no application code except a
readiness route the deploy gate requires", which is narrow, stated, and
testable.

A project generated with `--db none` ships no readiness route, and neither
does `nextjs` in any shape: there is nothing for either to query, and a route
that returns 200 without doing anything is the same worthless check in a
different place. The gate curls readiness only when the image it built serves
one — which is decided by the role that won `set_image_context`, not by
whether the project has a database. A `--api laravel-api --web nextjs --db
mysql` project builds the **nextjs** image, so its gate is liveness only, and
the Laravel app beside it is generated and checked but never deployed. Section
13 says why that is a limit worth naming.

## 8. Migrations at install time

`install.sh` runs the project's migration task once, after the stack is up and
before it prints its success message, and prints what it is doing.

This does not touch ADR-0014 seam 5, which forbids migrations from an
*entrypoint* — a container that migrates every time it starts is a container
that cannot be scaled or rolled back. `install.sh` is a human running one
command on the target host, which ADR-0014 itself calls "the one deploy
mechanism that exists today".

**The image has to be able to run it, and the Nest one cannot today.**
`services/shared/nest.sh` installs the CLI as `pnpm add -D prisma@6`, and
`adapters/nestjs/Dockerfile` runs `pnpm prune --prod` before the runtime stage
copies `node_modules` — so the published Nest image carries `@prisma/client`
and no `prisma` binary. It cannot migrate itself.

The driver installs `prisma` as a regular dependency instead. That is what
Prisma's own deployment guidance assumes when the migration runs from the
image, and it is the smaller change: the alternative — a second image, or a
compose service that mounts the source — introduces a build artifact the
release does not publish, for a command run once per deploy. The cost is the
CLI and its engines in the runtime image, and it is stated in the new decision record numbered 0021 rather
than discovered later.

The Laravel images need nothing: `php artisan` is already there.

`install.sh` therefore runs the framework's own command, not a `mise` task —
no image carries `mise`, and inventing one would be a mechanism built to make
a sentence in this spec true. The driver writes the command into
`compose.yaml` as a `migrate` service sharing the app's image and environment,
under a compose profile so it never starts with the stack:

```yaml
  migrate:
    profiles: [migrate]
    image: ${APP_IMAGE}
    command: [...the family's migration command...]
```

and `install.sh` runs `docker compose --profile migrate run --rm migrate`.

`nestjs` has no `migrate` task and needs one for local use. It must branch on
the Prisma provider, measured on 2026-09-05:

```
$ pnpm exec prisma migrate deploy       # against mongodb
Error: The "mongodb" provider is not supported with this command.
$ pnpm exec prisma db push              # against mongodb
The database is already in sync with the Prisma schema.
```

So: `db push` for `mongodb`, `migrate deploy` otherwise. Both Laravel adapters
already ship `[tasks.migrate]`.

## 9. What serving reveals

Three defects exist today, cause no symptom because nothing serves a request,
and become visible the moment something does. They are in scope because gate 2
fails without them.

- **File ownership.** `storage/framework/{views,sessions}` and
  `bootstrap/cache` are root-owned in both Laravel images while the process
  runs as `www-data`. One `chown` in each runtime stage.
- **Stale assets in `laravel-inertia`.** The runtime stage copies
  `public/build` from the assets stage and *then* runs `COPY . .`, and
  `public/build` is in `.gitignore` but not `.dockerignore` — so a developer
  who has run `npm run build` locally layers their host copy over the image's.
  Add it to `.dockerignore`. This is the same class as the `bootstrap/cache`
  defect fixed on 2026-09-04: a working tree leaking into a build context.
- **mongodb extension against a locked library.** The image carries
  `ext-mongodb 2.5.2` while `composer.lock` pins `mongodb/mongodb 1.21.4`
  against `ext-mongodb 1.21.0`, and any real query dies on
  `Declaration of MongoDB\Model\BSONArray::bsonSerialize() must be
  compatible`. The driver pins a library version matching the extension it
  installs.

## 10. The deploy gate

A new job in `.github/workflows/adapters.yml`, beside `smoke`, driven by the
same `discover` matrix so ADR-0012's tiers decide what runs when:

```
generate
  -> docker build, using the context/dockerfile pair the generated
     build.yml names, never a chosen one
  -> install.sh's own sequence against the built image
  -> wait for the app container to report healthy
  -> curl <the built image's liveness path>   -> 200
  -> curl <its readiness path, where it has one> -> 200
  -> docker compose down -v
```

The two paths come from the adapter (section 7), not from the job: hardcoding
them here would put the gate's idea of the route and the Dockerfile's idea of
it in two places, which is how `nestjs` came to probe a `/health` nothing
serves.

Reading the pair out of the generated `build.yml` rather than choosing one is
what made a 9-cell container matrix go from 8/9 to 9/9 in a previous round: a
build that passes with a pair CI does not use proves nothing.

**Tier-gated, deliberately.** Tier A on every pull request, tier B on the
weekly schedule, exactly as `smoke` and `smoke-tier-b` already split. Running
every shape on every pull request would add roughly a container build per
adapter to a lane that already costs 15 minutes, and ADR-0012 exists to make
that tradeoff once rather than per job.

## 11. Changes to files that already exist

| File | Change |
|---|---|
| `adapters/laravel-api/Dockerfile` | runtime stage to FrankenPHP; `SERVER_NAME`, `XDG_*`, `chown`, `EXPOSE 8080`, `HEALTHCHECK` |
| `adapters/laravel-inertia/Dockerfile` | the same, plus `public/build` ordering |
| `adapters/laravel-inertia/.dockerignore` | `public/build` |
| `adapters/nestjs/Dockerfile`, `.workspace` | `ENV PORT=8080`, `EXPOSE 8080`, and a healthcheck on a path that exists — it probes `/health` today and nothing serves it |
| `adapters/nextjs/Dockerfile`, `.workspace` | `ENV PORT=8080`, `EXPOSE 8080`, healthcheck port |
| `adapters/*/` | a liveness path where the framework ships none, and a readiness route for every adapter that can hold a database |
| `adapters/nestjs/mise.toml` | a `migrate` task branching on the Prisma provider |
| `common/compose.yaml` | an `environment:` block on `app`, written by the driver |
| `common/example.env` | `APP_KEY=changeme` for Laravel projects |
| `common/install.sh` | generate `APP_KEY`; run the migration task once |
| `lib/service.sh` | `service_driver_compose_env`, beside `service_driver_dockerfile` |
| `lib/contract.sh` | the new driver hook joins the required-file checks |
| `services/*/drivers/*.sh` | each driver emits its family's environment block |
| `services/mongodb/drivers/laravel.sh` | pin `mongodb/mongodb` to match `ext-mongodb` |
| `.github/workflows/adapters.yml` | the deploy gate |
| `tests/compose.bats` | assert every adapter Dockerfile has `EXPOSE 8080` and a `HEALTHCHECK` |
| `docs/decisions/0003-*` | the application-code boundary moves; state where |
| `docs/decisions/0014-*` | seam 4's "no healthcheck is possible" and seam 1's single-image claim both become false |
| `docs/tour/07-containers.md` | its worked example is the Laravel "why no healthcheck" paragraph |
| `docs/runbook/first-project-walkthrough.md` | step 10 becomes "run it", not "pull it" |
| new `docs/decisions/0021-*` | records this design |

## 12. Testing

The gate in section 10 is the load-bearing test, and it is the only one that
can fail for the reasons this design exists. Everything else is cheap
guardrails that keep it from silently rotting:

- `tests/compose.bats` gains an assertion per adapter Dockerfile: `EXPOSE
  8080` present, `HEALTHCHECK` present, and the path the `HEALTHCHECK` probes
  is the liveness path the adapter declares. All three are static, and all
  three fail today for at least one adapter — the third is what would have
  caught `nestjs` probing a route nothing serves.
- `tests/service.bats` gains a case per driver: the emitted environment block
  names the family's variables and interpolates `${DB_PASSWORD}` rather than a
  literal.
- `tests/contract.bats` requires `service_driver_compose_env` of every driver,
  the way it already requires `service_driver_apply`.
- No new test starts a container outside the gate. Container work belongs in
  the tier-gated lane, not in a suite someone runs on a laptop.

Suites to run for a change under this design: `compose`, `service`, `contract`
and the adapter's own `new-<adapter>.bats`. The full lane runs in CI.

## 13. Known limits

- **One image per project stands.** A `web+api` project still builds and
  deploys only the role that came last on the command line. The gate tests
  that image; the other application is generated, checked, and not deployed.
  Unchanged by this design, and worth stating because gate 2 will look like it
  covers a project when it covers an image.
- **`/health/ready` is application code the toolbox owns and a client may
  delete.** Nothing detects that. The gate tests generated projects, not
  client repositories six months later.
- **The gate proves one shape per adapter, not every service combination.**
  `nestjs` + `postgres` passing says nothing about `nestjs` + `mongodb`, whose
  Prisma provider takes a different migration command. Tier B's weekly matrix
  covers more but not all.
- **`install.sh` running migrations is a single-instance assumption.** Two
  operators running it concurrently against one database is not defended
  against. It is the same assumption `install.sh` already makes about
  everything else it does.

## 14. Follow-on work

- Octane, if a client's load justifies worker mode — one `ENTRYPOINT` line on
  the same base image.
- A deploy adapter, which is what ADR-0014's remaining seams are for. This
  design makes the image it would deploy actually runnable, which was the
  missing precondition.
- The root `prettier` hook rewriting `apps/app`'s frontend source, measured on
  2026-09-05: `lefthook run pre-commit --all-files` rewrites 39 files and the
  app then fails its own `ci-unit`. Adjacent, separately scoped, and blocking
  daily work on `laravel-inertia` rather than deployment.
