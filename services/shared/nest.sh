# shellcheck shell=bash
# ═══════════════════════════════════════════════════════════════════════════
# Script      : services/shared/nest.sh
# Description : The shared Prisma driver body.
# Author      : ttncode
# ═══════════════════════════════════════════════════════════════════════════
# A service's drivers/nest.sh sets the parameters below and sources this. One
# client API across every database this toolbox ships is why Prisma was chosen
# over TypeORM — the adapter x service matrix collapses to a single code path.
#
#   PRISMA_PROVIDER     the datasource provider
#   PRISMA_URL          the DATABASE_URL for .env.example (host-side, via
#                       localhost)
#   PRISMA_COMPOSE_URL  the same DSN against the compose network, with the
#                       credentials left as compose interpolations

service_driver_apply() {
  # Before the installs, not after: all three packages place the query engine
  # binary through an install-time script with no pure-js fallback, and
  # undecided the first `pnpm add` below is refused with
  # ERR_PNPM_IGNORED_BUILDS wherever CI=true leaves pnpm no prompt.
  #
  # SCAFFOLD_PROJECT_ROOT, exported by apply_service_drivers: cmd_add's app
  # directory is caller-chosen, so a fixed `../..` reaches outside the project.
  if ! yq --inplace \
    '.allowBuilds.prisma = true
     | .allowBuilds."@prisma/engines" = true
     | .allowBuilds."@prisma/client" = true' \
    "${SCAFFOLD_PROJECT_ROOT}/pnpm-workspace.yaml"; then
    die "could not set allowBuilds for prisma in pnpm-workspace.yaml"
  fi

  # major-pinned, not @latest: 7 dropped the datasource `url` this driver writes
  # below for a prisma.config.ts adapter, and latest resolves to an 8.x release
  # candidate. 6 is the newest stable major that still reads `url`.
  pnpm add @prisma/client@6 || return 1
  # A regular dependency, not -D: `pnpm prune --prod` drops devDependencies, and
  # the published image is what runs `migrate deploy`. The engines cost image
  # size (ADR-0021).
  pnpm add prisma@6 || return 1
  mkdir -p prisma || return 1

  # datasource and generator only. models describe the client's domain, which
  # this toolbox does not know — see the spec's non-goals.
  cat > prisma/schema.prisma <<EOF || return 1
generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "${PRISMA_PROVIDER}"
  url      = env("DATABASE_URL")
}
EOF

  write_env_lines .env.example "DATABASE_URL=${PRISMA_URL}" || return 1

  # prisma has no provider-agnostic read: $queryRaw is SQL-only and mongodb
  # needs a command, so the shipped route carries exactly one probe, for the
  # provider this project actually has — and only the one method that provider
  # calls: a generated mongodb client has no $queryRawUnsafe and a SQL one no
  # $runCommandRaw, and a cast naming a method the class lacks fails tsc's
  # "sufficient overlap" check.
  #
  # A dynamic import cast to an explicit method signature, not a bare
  # `import(...).then(...)`: lint runs before the :prisma task, so
  # @prisma/client still re-exports a generated module that does not exist yet
  # and an untyped access to it is `any`, which @typescript-eslint's no-unsafe-*
  # rules reject under --max-warnings 0.
  #
  # The throw is replaced in place rather than left below the probe:
  # no-unreachable is in eslint's recommended set. A --db none project runs
  # neither substitution and keeps the throw.
  #
  # The client is a field on HealthController, not a local inside ready(): a
  # controller is a Nest singleton, so every poll after the first reuses it.
  # Constructing a PrismaClient per request and never closing it leaks one real
  # database connection per poll — measured exhausting Postgres's
  # max_connections well inside an hour at a 10s probe interval.
  local method field preamble probe
  case "$PRISMA_PROVIDER" in
    mongodb)
      method='$runCommandRaw(command: object): Promise<unknown>'
      probe='await this.dbClient.$runCommandRaw({ ping: 1 });'
      ;;
    *)
      method='$queryRawUnsafe(query: string): Promise<unknown>'
      probe="await this.dbClient.\$queryRawUnsafe('SELECT 1');"
      ;;
  esac
  field="private dbClient?: { ${method} };"
  sed -i.bak "s|// @DB_CLIENT@|${field}|" \
    src/health/health.controller.ts || return 1

  preamble="if (!this.dbClient) {\n        const { PrismaClient } = (await import('@prisma/client')) as {\n          PrismaClient: new () => { ${method} };\n        };\n        this.dbClient = new PrismaClient();\n      }"
  sed -i.bak "s|// @DB_PROBE@|${preamble}\n      ${probe}|" \
    src/health/health.controller.ts || return 1
  sed -i.bak "s|throw new Error('no database is configured for this project');|return { status: 'ok' };|" \
    src/health/health.controller.ts || return 1
  # The probe spliced above is the only thing in this method that awaits, so
  # the adapter ships it without `async` — a --db none project would
  # otherwise fail @typescript-eslint/require-await on its own lint task.
  sed -i.bak "s|  ready(): Promise<|  async ready(): Promise<|" \
    src/health/health.controller.ts || return 1
  rm -f src/health/health.controller.ts.bak

  grep -q "dbClient" src/health/health.controller.ts \
    && grep -q "PrismaClient" src/health/health.controller.ts \
    && grep -q "return { status: 'ok' };" src/health/health.controller.ts \
    && grep -q "async ready(): Promise<" src/health/health.controller.ts \
    || die "could not splice the database probe into src/health/health.controller.ts — has the anchor moved?"

  # The mongodb and SQL branches wrap differently under prettier's print width,
  # so reformat once rather than hand-matching its output per branch.
  pnpm exec prettier --write src/health/health.controller.ts || return 1
}

service_driver_dockerfile() {
  printf 'RUN pnpm exec prisma generate\n'
}

# An operator's own .env wins; otherwise compose builds the URL from the same
# DB_* variables the database container reads, so the password lives in exactly
# one place.
service_driver_compose_env() {
  printf 'DATABASE_URL: ${DATABASE_URL:-%s}\n' "$PRISMA_COMPOSE_URL"
}

# prisma's mongodb provider rejects `migrate deploy` — `The "mongodb" provider
# is not supported with this command.` — and takes `db push` instead. Read off
# PRISMA_PROVIDER rather than recorded separately.
#
# Not `pnpm exec`: the runtime stage copies node_modules/dist alone, so pnpm is
# not in the built image. prisma's own bin does survive `pnpm prune --prod` (it
# is a regular dependency precisely so it would), but at one of two locations
# depending on which Dockerfile shape wins — a decision made after this driver
# runs: apps/<app>/node_modules/.bin for the workspace shape, node_modules/.bin
# at the container root for the standalone one. The command tries both rather
# than guessing, and `cd`s into whichever matched: WORKDIR stays the container
# root either way, and prisma resolves `./prisma/schema.prisma` from its own
# working directory, which is nested under the app directory in the workspace
# shape (measured: `Could not find Prisma Schema` before this `cd`).
service_driver_compose_migrate() {
  local args
  case "$PRISMA_PROVIDER" in
    mongodb) args='db push --skip-generate' ;;
    *) args='migrate deploy' ;;
  esac
  # `$${d}`/`$$d`, not `${d}`/`$d`: compose interpolates `$var` in compose.yaml
  # before the command reaches the container, and a single `$` resolves to an
  # unset variable that blanks the loop out entirely. `$$` is compose's escape
  # for a literal `$`.
  printf 'command: ["sh", "-c", "for d in apps/*/ ./; do [ -x $${d}node_modules/.bin/prisma ] && cd $$d && exec node_modules/.bin/prisma %s; done; echo prisma binary not found >&2; exit 1"]\n' "$args"
}
