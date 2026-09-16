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
  # Before the installs, not after: prisma, its engines and its client all place
  # the query engine binary through an install-time script with no pure-js
  # fallback, and undecided the first `pnpm add` below is refused with
  # ERR_PNPM_IGNORED_BUILDS wherever CI=true leaves pnpm no prompt.
  #
  # SCAFFOLD_PROJECT_ROOT, not a fixed `../..`: cmd_add's app directory is
  # caller-chosen.
  if ! yq --inplace \
    '.allowBuilds.prisma = true
     | .allowBuilds."@prisma/engines" = true
     | .allowBuilds."@prisma/client" = true' \
    "${SCAFFOLD_PROJECT_ROOT}/pnpm-workspace.yaml"; then
    die "could not set allowBuilds for prisma in pnpm-workspace.yaml"
  fi

  # major-pinned, not @latest: 7 dropped the datasource `url` this driver writes
  # below for a prisma.config.ts adapter, and latest resolves to an 8.x release
  # candidate.
  pnpm add @prisma/client@6 || return 1
  # A regular dependency, not -D: `pnpm prune --prod` drops devDependencies, and
  # the published image is what runs `migrate deploy`.
  pnpm add prisma@6 || return 1
  mkdir -p prisma || return 1

  # datasource and generator only; models describe the client's domain, which
  # this toolbox does not know.
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

  # prisma has no provider-agnostic read: $queryRaw is SQL-only, mongodb needs a
  # command, and a generated client only has the one method its provider
  # implies — casting to the other fails tsc's "sufficient overlap" check.
  #
  # Cast to an explicit method signature, not a bare `import(...).then(...)`:
  # lint runs before the :prisma task, so the generated client does not exist
  # yet and an untyped access to it is `any`, which @typescript-eslint's
  # no-unsafe-* rules reject under --max-warnings 0.
  #
  # The throw is replaced in place, not left below the probe: no-unreachable is
  # in eslint's recommended set. A --db none project keeps the throw.
  #
  # The client is a field on HealthController, not a local inside ready(): a
  # controller is a Nest singleton, and a PrismaClient built per request and
  # never closed leaks one connection per poll — measured exhausting Postgres's
  # max_connections inside an hour at a 10s probe interval.
  local method field preamble probe
  # shellcheck disable=SC2016 # literal TypeScript spliced into the generated controller
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
  # The adapter ships ready() without `async` — a --db none project would
  # otherwise fail @typescript-eslint/require-await on its own lint task.
  sed -i.bak "s|  ready(): Promise<|  async ready(): Promise<|" \
    src/health/health.controller.ts || return 1
  rm -f src/health/health.controller.ts.bak

  assert_nest_probe_spliced src/health/health.controller.ts

  # The mongodb and SQL branches wrap differently under prettier's print width,
  # so reformat once rather than hand-matching its output per branch.
  pnpm exec prettier --write src/health/health.controller.ts || return 1
}

# The fourth check is the absence of the fallback throw, not the presence of the
# success return: live() already returns `{ status: 'ok' };`, so a grep for that
# matches the shipped file and passes whether or not the splice landed.
assert_nest_probe_spliced() {
  local -r file="$1"

  # shellcheck disable=SC2015 # deliberate: die must fire when any check fails
  grep -q "dbClient" "$file" \
    && grep -q "PrismaClient" "$file" \
    && grep -q "async ready(): Promise<" "$file" \
    && ! grep -q "no database is configured for this project" "$file" \
    || die "could not splice the database probe into ${file} — has the anchor moved?"
}

service_driver_dockerfile() {
  printf 'RUN pnpm exec prisma generate\n'
}

# An operator's own .env wins; otherwise compose builds the URL from the same
# DB_* variables the database container reads.
service_driver_compose_env() {
  # shellcheck disable=SC2016 # literal ${DATABASE_URL} written into compose.yaml, not expanded here
  printf 'DATABASE_URL: ${DATABASE_URL:-%s}\n' "$PRISMA_COMPOSE_URL"
}

# prisma's mongodb provider rejects `migrate deploy` — `The "mongodb" provider
# is not supported with this command.` — and takes `db push` instead.
#
# Not `pnpm exec`: the runtime stage copies node_modules/dist alone, so pnpm is
# not in the built image. prisma's own bin survives `pnpm prune --prod`, but at
# one of two locations depending on which Dockerfile shape wins, a decision made
# after this driver runs — so the command tries both and `cd`s into whichever
# matched, since prisma resolves `./prisma/schema.prisma` from its own working
# directory (measured: `Could not find Prisma Schema` before this `cd`).
service_driver_compose_migrate() {
  local args
  case "$PRISMA_PROVIDER" in
    mongodb) args='db push --skip-generate' ;;
    *) args='migrate deploy' ;;
  esac
  # `$${d}`/`$$d`, not `${d}`/`$d`: compose interpolates `$var` before the
  # command reaches the container; `$$` is compose's escape for a literal `$`.
  # shellcheck disable=SC2016 # literal shell text written into compose.yaml, not expanded here
  printf 'command: ["sh", "-c", "for d in apps/*/ ./; do [ -x $${d}node_modules/.bin/prisma ] && cd $$d && exec node_modules/.bin/prisma %s; done; echo prisma binary not found >&2; exit 1"]\n' "$args"
}
