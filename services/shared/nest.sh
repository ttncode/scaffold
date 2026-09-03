# shellcheck shell=bash
# The Prisma driver. A service's drivers/nest.sh sets the two parameters below
# and sources this. One client API across every database this toolbox ships is
# why Prisma was chosen over TypeORM — the adapter x service matrix collapses
# to a single code path.
#
#   PRISMA_PROVIDER  the datasource provider
#   PRISMA_URL       the DATABASE_URL for .env.example

service_driver_apply() {
  # major-pinned, not @latest: prisma's latest dist-tag currently resolves to
  # an 8.x release candidate, and 7 dropped the datasource `url` this driver
  # writes below in favor of a prisma.config.ts adapter — a bigger change
  # than a driver that only ever writes datasource+generator should force on
  # every service. 6 is the newest stable major that still reads `url` from
  # the schema.
  pnpm add @prisma/client@6
  pnpm add -D prisma@6
  mkdir -p prisma

  # All three fetch or place the query engine binary through an
  # install-time script, with no pure-js fallback — same category as esbuild
  # in ADR-0017's baseline allowBuilds, just decided here instead, since only
  # a project that picked a service needing prisma carries the dependency at
  # all. Left undecided, cmd_new's later workspace-level reinstall fails
  # non-interactively (ERR_PNPM_IGNORED_BUILDS).
  yq --inplace \
    '.allowBuilds.prisma = true
     | .allowBuilds."@prisma/engines" = true
     | .allowBuilds."@prisma/client" = true' \
    "$(git rev-parse --show-toplevel)/pnpm-workspace.yaml"

  # datasource and generator only. models describe the client's domain, which
  # this toolbox does not know — see the spec's non-goals.
  cat > prisma/schema.prisma <<EOF
generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "${PRISMA_PROVIDER}"
  url      = env("DATABASE_URL")
}
EOF

  write_env_lines .env.example "DATABASE_URL=${PRISMA_URL}"
}

service_driver_dockerfile() {
  printf 'RUN pnpm exec prisma generate\n'
}
