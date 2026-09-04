# shellcheck shell=bash
# The Prisma driver. A service's drivers/nest.sh sets the two parameters below
# and sources this. One client API across every database this toolbox ships is
# why Prisma was chosen over TypeORM — the adapter x service matrix collapses
# to a single code path.
#
#   PRISMA_PROVIDER  the datasource provider
#   PRISMA_URL       the DATABASE_URL for .env.example

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
}

service_driver_dockerfile() {
  printf 'RUN pnpm exec prisma generate\n'
}
