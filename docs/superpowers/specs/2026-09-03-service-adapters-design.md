# Service Adapters — Design

Status: approved for planning
Date: 2026-09-03
Scope: databases and caches. The interactive command surface is a separate
design — see section 12.

## 1. Context

A generated project's database is decided once, by hand, in the toolbox. Every
project gets PostgreSQL, because PostgreSQL is written into
`common/compose.yaml`, `common/compose.dev.yaml`, `common/compose.test.yaml`,
both Laravel Dockerfiles (`pdo_pgsql`), and three adapter `.env.example` files.
There is no flag, and nothing about the arrangement is a decision the toolbox
records — it is a default that hardened into a constant.

Two problems follow from that.

A project that asked for no backend still ships a database. `scaffold new site
--web nextjs` produces a `compose.yaml` carrying a PostgreSQL service and an
`app` service that waits on its health check, for an application that never
opens a connection.

And the promise the `.env` files make is not uniformly kept. Laravel's
`DB_CONNECTION=pgsql` works: `pdo_pgsql` is in the image and Eloquent ships with
the framework. The `nestjs` adapter's `DATABASE_URL=postgres://app:app@localhost:5432/app`
does not: that adapter installs no database client at all — no Prisma, no
TypeORM, no `pg`. The variable names a container nothing in the project can talk
to.

This design introduces a service category — a database or a cache — that a
project selects at generation time, and that reaches far enough into the
generated application for the connection to actually work.

## 2. Goals

1. `scaffold new` accepts `--db` and `--cache`, and the generated project runs
   against the chosen service without further edits.
2. A project that needs no database gets no database service, and no
   `depends_on` waiting on one.
3. Adding a fifth service costs one directory, not edits spread across the
   adapters.
4. An adapter that cannot work with a service fails `scaffold lint`, before
   anyone generates a project from it.
5. The image digest for a service is written in exactly one place.

## 3. Non-goals

- **DynamoDB.** `compose.yaml` is attached to every release for a client to run
  (ADR-0014). The only DynamoDB that fits a compose file is
  `amazon/dynamodb-local`, an emulator with no production counterpart in a
  self-hosted stack. It belongs with `common/deploy-adapters/`, alongside the
  rest of the deferred deployment work, not here.
- **Changing a project's database after generation.** It would have to rewrite
  three compose files, every application's `.env.example`, every Dockerfile, and
  uninstall the previous driver — across files the caller already owns, with no
  undo. `scaffold` refuses and says so.
- **Example models or schemas.** Prisma gets a `datasource` and a `generator`
  and no models; Laravel keeps the migrations its own skeleton ships. Generating
  a `User` is guessing at the client's domain.
- **A database for the `web` tier.** The `nextjs` adapter gets no driver — see
  section 7.
- **Variants of what is already covered.** MariaDB and Valkey are protocol-
  compatible with services this design already carries; they add matrix cells
  and no capability.

## 4. The service category

Services live in `services/`, a sibling of `adapters/`, because a service is not
an adapter and does not survive the invariants `lib/lint.sh` enforces on one.
`REQUIRED_ADAPTER_FILES` demands a `Dockerfile`, an `.env.example` and a
`mise.toml`; a database has none of those in that sense. `ADAPTER_GENERATOR` has
nothing to run. `role_path` maps a role onto `apps/<role>`, and a service owns no
directory in the generated tree at all. Fitting a service into `adapters/` means
loosening every one of those checks for the one case that does not fit — and a
check loosened until it cannot fail is worse than no check, because it still
reads like a guarantee.

```
services/
  mysql/
    service.env
    compose.fragment.yaml
    compose.prod.fragment.yaml
    compose.dev.fragment.yaml
    compose.test.fragment.yaml
    env.fragment
    drivers/
      laravel.sh
      nest.sh
  postgres/
  mongodb/
  redis/
  shared/
    laravel.sh
    nest.sh
```

`service.env` carries three variables and nothing else:

```sh
SERVICE_NAME="mysql"
SERVICE_KIND="database"     # database | cache
SERVICE_IMAGE="docker.io/library/mysql:8.4.6@sha256:<digest>"
```

The compose service key is derived from `SERVICE_KIND`, not declared: a
`database` service is keyed `database`, a `cache` service is keyed `cache`. One
service of each kind at most, which is what `--db` and `--cache` already imply.

## 5. Compose assembly

`common/compose.yaml` loses its `database` service and its `volumes` block, and
ships the `app` service alone. `scaffold` merges the selected services in with
`yq`, and adds the matching `depends_on` entry and named volume as it does. A
project generated with `--db none --cache none` gets a `compose.yaml` with one
service and no `depends_on` at all — which is the correct file for it, not a
degraded one.

Each service carries a shared body plus three deltas:

| File | Contents |
| --- | --- |
| `compose.fragment.yaml` | `image`, `environment`, `healthcheck` |
| `compose.prod.fragment.yaml` | named volume, `restart: always` |
| `compose.dev.fragment.yaml` | port published on `127.0.0.1` |
| `compose.test.fragment.yaml` | `tmpfs` storage |

A lane's service block is `yq eval-all 'select(fi==0) * select(fi==1)'` over the
body and that lane's delta.

The split exists for one reason. The repository today writes the PostgreSQL
digest three times, once per lane. Bumping it takes three edits, and missing one
leaves development running a different PostgreSQL from production with nothing
to report it. Four services across three lanes is twelve places to miss.
`SERVICE_IMAGE` is written once; the deltas carry only what genuinely differs
between lanes.

`env.fragment` holds the infrastructure-side variables appended to
`common/example.env` — `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD` for a
database; `REDIS_PASSWORD` for the cache.

`common/install.sh` generates a random `DB_PASSWORD` and refuses to start while
`DB_PASSWORD=changeme` remains. That name is hardcoded in three places. It
becomes a loop over every `*_PASSWORD=changeme` line the assembled `.env`
contains, so it is correct for a project with no database, one service, or two —
rather than correct for exactly the arrangement that existed when it was
written.

## 6. The driver matrix

A service knows how to run a container. A driver knows how one framework talks
to it. `DB_CONNECTION=mysql` is Laravel's phrasing and `DATABASE_URL=mysql://`
is Prisma's, for the same MySQL — so the phrasing belongs with the framework,
not with the service.

Drivers are keyed on framework family, not adapter name. `laravel-api` and
`laravel-inertia` need exactly the same wiring, and two files holding the same
thing is an invitation for them to drift. `adapter.env` gains one line:

```sh
ADAPTER_FAMILY="laravel"    # laravel | nest | next
```

Adapters with `ADAPTER_ROLE=web` take no driver. That is a rule stated once,
about the role, rather than a "not applicable" entry repeated in every service.
It also keeps two different facts from sharing one signal: a missing driver file
means the combination was never wired, and never means the tier does not need
one.

That leaves two families across four services — eight files, no empty cells:

| | `nest` (Prisma) | `laravel` |
| --- | --- | --- |
| mysql | `provider = "mysql"` | `pdo_mysql`, in the PHP core |
| postgres | `provider = "postgresql"` | `pdo_pgsql`, in the PHP core |
| mongodb | `provider = "mongodb"` | `mongodb/laravel-mongodb`, `pecl mongodb` |
| redis | `@nestjs/cache-manager` + a Keyv Redis store | `predis/predis` |

Within a family the files differ by a parameter or two, so the implementation
lives once in `services/shared/<family>.sh` and each driver sets its parameters
and sources it:

```sh
# services/mysql/drivers/nest.sh
PRISMA_PROVIDER="mysql"
source "${SCAFFOLD_ROOT}/services/shared/nest.sh"
```

The per-service file still has to exist. `scaffold lint` requires one for every
family whose role is `api` or `app`, so an adapter in a new family cannot merge
until every service has been taught about it — the same kind of gate the
nine-task contract already is. A thin file is not a weak gate; the gate is that
somebody decided, and recorded the decision.

Each driver defines two functions:

```sh
service_driver_apply()       # runs in the application directory: install the
                             # package, write the .env.example lines
service_driver_dockerfile()  # prints the lines to splice into the Dockerfile
```

### 6.1 Dockerfile placement

The Laravel Dockerfile hardcodes `apk add --no-cache postgresql-dev &&
docker-php-ext-install pdo_pgsql opcache`. Rewriting that line with `sed` is the
kind of edit that stops matching when somebody reformats the file and reports
nothing when it stops.

Instead each adapter Dockerfile carries an anchor comment, and the adapter
decides where it goes — the Laravel images put it in the runtime stage, where
extensions are installed; the Nest image puts it in the build stage, where
`prisma generate` has to run before `tsc`:

```dockerfile
# @SERVICE_SETUP@
```

`scaffold` concatenates the output of every selected service's
`service_driver_dockerfile` and replaces the anchor once. Concatenating rather
than substituting per service is what makes `--db mongodb --cache redis` produce
two blocks instead of one overwriting the other. With no services selected the
anchor is replaced with nothing.

This is the same technique as the existing `@PROJECT_NAME@` substitution in
`init_project`, not a new mechanism.

### 6.2 Prisma and the task contract

`prisma generate` writes the client that `tsc` type-checks against, so it has to
run before `build` and before `check`. The `nextjs` adapter already solved this
exact shape for `next typegen`, and the `nestjs` adapter follows it rather than
inventing a second arrangement.

`--db none` leaves the `nestjs` adapter as it is today: no Prisma, no client,
and no `DATABASE_URL` claiming otherwise.

## 7. Command surface

```
scaffold new <name> [--web A] [--api B] [--app C]
                    [--db mysql|postgres|mongodb|none]
                    [--cache redis|none]
```

`--cache` defaults to `none`. `--db` defaults to `mysql` when the project
requests an adapter whose role is `api` or `app`, and to `none` when it does
not — derived rather than fixed, so that a frontend-only project stops shipping
a database it cannot use.

MySQL rather than PostgreSQL as the default is a change of behaviour for
projects generated from this point on. Projects already generated are untouched
— `scaffold` never revisits them — but `docs/tour/07-containers.md` and the
affected ADRs are updated to match, and this section is the record of the
decision.

`--db` with a value other than `none` on a project with no `api` or `app`
adapter is refused. The `web` tier has no driver, so the project would get a
running database, a set of environment variables, and no way to reach either.
Giving the `nextjs` adapter its own client is a change to that adapter and is
not in this scope.

Every question the interactive command surface will ask maps onto one of these
flags, so a fully-specified run stays scriptable and CI never opens a menu.

## 8. Recording the choice

The selection is written into the generated project's `mise.toml`, beside
`monorepo_root` — the marker `cmd_add` already reads to recognise a scaffold
project, and the file ADR-0013 already makes the project's manifest. No new
file and no new mechanism.

`scaffold add <dir> --adapter nestjs` reads it and applies the matching driver,
so an application added in month six is wired to the same database as the one
generated in month one.

## 9. Changes to files that already exist

| File | Change |
| --- | --- |
| `common/compose.yaml` | drop the `database` service and `volumes`; keep `app` alone |
| `common/compose.dev.yaml` | keeps only `name:`; the service is assembled from fragments |
| `common/compose.test.yaml` | the same |
| `common/example.env` | drop `DB_*`; assembled from `env.fragment` |
| `common/install.sh` | loop over `*_PASSWORD=changeme`, drop the hardcoded name |
| `adapters/*/adapter.env` | add `ADAPTER_FAMILY` |
| `adapters/laravel-*/Dockerfile` | replace the `pdo_pgsql` line with `# @SERVICE_SETUP@` |
| `adapters/nestjs/Dockerfile` | add `# @SERVICE_SETUP@` in the build stage |
| `adapters/*/.env.example` | drop the `DB_*` and `DATABASE_URL` lines; drivers write them |
| `lib/lint.sh` | require the driver matrix and `ADAPTER_FAMILY` |
| `docs/tour/07-containers.md` | describe assembly, and the MySQL default |
| `docs/decisions/` | one ADR for the service category, one for the MySQL default |

## 10. Testing

Four databases and two caches across the two families is eight combinations per
adapter. Generating one Tier B project already costs about five minutes
(ADR-0012), so running every combination on every pull request is not available.
The work is layered instead, and the existing tier system carries it:

| Layer | Runs | Cells | What it proves |
| --- | --- | --- | --- |
| structural | every pull request, seconds | all | fragments merge, `docker compose config` validates, the driver matrix is complete, digests appear once |
| generation, default cell | every pull request | 2 | `mysql` with no cache, on Tier A adapters |
| generation, full | nightly | 16 | Tier A across 4 databases and 2 caches |
| Tier B | weekly | 8 | `laravel-inertia` across the same |

The structural layer carries most of the load: a broken fragment, a stale
digest, a missing driver, a service whose health check never passes `docker
compose config` — all of it is caught in seconds without building a container.
The generation layers are reserved for what only appears when the thing actually
runs.

Tests follow the isolation rule the suite already holds to: each test generates
into its own `BATS_TEST_TMPDIR` against a copied toolbox (`copy_toolbox`), so
none of them can observe or disturb another. Parallelism is a property of the
runner, never of shared state between tests.

## 11. Known limits

1. `set_image_context` records one image context per project, so a project with
   both a `web` and an `api` adapter still builds a single image — whichever
   role was applied last. Unchanged by this work, and listed here because the
   interactive surface will make it far more visible than a command-line flag
   does.
2. A project's database cannot be changed after generation (section 3).
3. The `web` tier has no database driver (section 7).
4. DynamoDB is not covered (section 3).

## 12. Follow-on work

The interactive command surface is designed separately and built after this,
against the flag surface section 7 fixes. Its shape has been settled by mock:
a wizard that asks one question per screen, opening with the project's shape
(`web+api`, `app`, `api`, `web`) so that the mutually exclusive roles cannot
both be chosen — `laravel-inertia` is one application serving both tiers, and a
screen offering "frontend" and "backend" as independent groups has no honest
place to put it. The terminal handling is taken from the `bootstrap` script's
`lib/menu.sh`; the selection model is one choice per group rather than that
menu's independent checkboxes.
