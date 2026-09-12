# shellcheck shell=bash
# ═══════════════════════════════════════════════════════════════════════════
# Script      : services/mongodb/drivers/nest.sh
# Description : MongoDB parameters for the shared Prisma driver.
# Author      : ttncode
# ═══════════════════════════════════════════════════════════════════════════
# shellcheck disable=SC2034 # read by services/shared/nest.sh, sourced below
PRISMA_PROVIDER="mongodb"
# authSource=admin because the container creates the user in `admin`, and
# without it prisma authenticates against `app` and fails with a SCRAM error.
# directConnection is for prisma's mongodb provider, which otherwise expects a
# replica set — unproven for anything but `db push` against one node.
PRISMA_URL="mongodb://app:app@localhost:27017/app?authSource=admin&directConnection=true"
PRISMA_COMPOSE_URL='mongodb://${DB_USERNAME:-app}:${DB_PASSWORD}@database:27017/${DB_DATABASE:-app}?authSource=admin&directConnection=true'
# shellcheck source=/dev/null
. "${SCAFFOLD_ROOT}/services/shared/nest.sh"
