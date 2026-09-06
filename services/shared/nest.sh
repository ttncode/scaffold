# shellcheck shell=bash
# The Prisma driver. A service's drivers/nest.sh sets the parameters below
# and sources this. One client API across every database this toolbox ships is
# why Prisma was chosen over TypeORM — the adapter x service matrix collapses
# to a single code path.
#
#   PRISMA_PROVIDER      the datasource provider
#   PRISMA_URL           the DATABASE_URL for .env.example (host-side, via
#                        localhost)
#   PRISMA_COMPOSE_URL   the same DSN against the compose network, with the
#                        credentials left as compose interpolations

service_driver_apply() {
  # Before the installs, not after. All three packages place the query engine
  # binary through an install-time script with no pure-js fallback — the same
  # category as esbuild in ADR-0017's baseline allowBuilds, decided here
  # instead because only a project that picked a service needing prisma
  # carries them at all. Undecided, the first `pnpm add` below is itself
  # refused with ERR_PNPM_IGNORED_BUILDS on a runner, where CI=true leaves
  # pnpm no prompt to fall back on. Ordered after the installs this passed
  # every local run and failed on the first push to main.
  # SCAFFOLD_PROJECT_ROOT, exported by apply_service_drivers: cmd_add's app
  # directory is caller-chosen, not always apps/<role>, so a fixed `../..`
  # guess reaches outside the project it was meant to edit.
  if ! yq --inplace \
    '.allowBuilds.prisma = true
     | .allowBuilds."@prisma/engines" = true
     | .allowBuilds."@prisma/client" = true' \
    "${SCAFFOLD_PROJECT_ROOT}/pnpm-workspace.yaml"; then
    die "could not set allowBuilds for prisma in pnpm-workspace.yaml"
  fi

  # major-pinned, not @latest: prisma's latest dist-tag currently resolves to
  # an 8.x release candidate, and 7 dropped the datasource `url` this driver
  # writes below in favor of a prisma.config.ts adapter — a bigger change
  # than a driver that only ever writes datasource+generator should force on
  # every service. 6 is the newest stable major that still reads `url` from
  # the schema.
  # apply_service_drivers runs this in its own `bash -e` process, so a
  # fallible command left unchecked here is caught there too — `|| return 1`
  # stays anyway: it names the failure at the point it happens instead of
  # leaving that to the caller's generic message.
  pnpm add @prisma/client@6 || return 1
  pnpm add -D prisma@6 || return 1
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
  # needs a command. Written here rather than branched in the controller so
  # the shipped route carries exactly one probe, for the provider this
  # project actually has.
  #
  # A dynamic import cast to an explicit method signature, not a bare
  # `import(...).then(...)`: before `prisma generate` has run (lint runs
  # before the :prisma mise task, which build and check both depend on),
  # @prisma/client re-exports a generated module that does not exist yet, so
  # an untyped access to it is `any` — @typescript-eslint's no-unsafe-* rules
  # catch that under --max-warnings 0. The cast keeps the probe typed
  # regardless of whether the client has been generated.
  #
  # Two separate substitutions, not one: splicing the probe in above the
  # shipped `throw` would leave that throw as dead code below a path that
  # always returns first, and //apps/api:lint runs eslint with
  # --max-warnings 0, where no-unreachable is in the recommended set. The
  # throw is replaced in place instead, so a --db none project keeps it —
  # unreachable in no project this driver ever touches.
  # Only the one method this provider calls, not both: `prisma generate`
  # (which lint runs before but check runs after) produces a real
  # PrismaClient whose mongodb build has no $queryRawUnsafe and whose SQL
  # builds have no $runCommandRaw, and asserting a type carrying a method
  # the generated class lacks fails tsc's "sufficient overlap" check on the
  # cast — caught by generating this project with a real database and
  # running its check task, not by lint alone.
  local method preamble probe
  case "$PRISMA_PROVIDER" in
    mongodb)
      method='$runCommandRaw(command: object): Promise<unknown>'
      probe='await client.$runCommandRaw({ ping: 1 });'
      ;;
    *)
      method='$queryRawUnsafe(query: string): Promise<unknown>'
      probe="await client.\$queryRawUnsafe('SELECT 1');"
      ;;
  esac
  preamble="const { PrismaClient } = (await import('@prisma/client')) as {\n        PrismaClient: new () => { ${method} };\n      };\n      const client = new PrismaClient();"
  sed -i.bak "s|// @DB_PROBE@|${preamble}\n      ${probe}|" \
    src/health/health.controller.ts || return 1
  sed -i.bak "s|throw new Error('no database is configured for this project');|return { status: 'ok' };|" \
    src/health/health.controller.ts || return 1
  rm -f src/health/health.controller.ts.bak

  grep -q "PrismaClient" src/health/health.controller.ts \
    && grep -q "return { status: 'ok' };" src/health/health.controller.ts \
    || die "could not splice the database probe into src/health/health.controller.ts — has the anchor moved?"

  # The spliced text's own line breaks are a guess, and the mongodb and SQL
  # branches wrap differently once prettier's print width applies to each —
  # reformatting here, once, beats hand-matching prettier's output for every
  # branch this driver can produce.
  pnpm exec prettier --write src/health/health.controller.ts || return 1
}

service_driver_dockerfile() {
  printf 'RUN pnpm exec prisma generate\n'
}

# The value an operator sets in .env wins; otherwise compose composes it from
# the same DB_* variables the database container reads, so the password lives
# in exactly one place and the two cannot drift. Measured against a real
# `docker compose config`: both paths resolve, and the default is not
# evaluated when DATABASE_URL is set.
service_driver_compose_env() {
  printf 'DATABASE_URL: ${DATABASE_URL:-%s}\n' "$PRISMA_COMPOSE_URL"
}
