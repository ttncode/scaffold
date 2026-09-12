# shellcheck shell=bash
# ═══════════════════════════════════════════════════════════════════════════
# Script      : services/postgres/drivers/nest.sh
# Description : PostgreSQL parameters for the shared Prisma driver.
# Author      : ttncode
# ═══════════════════════════════════════════════════════════════════════════
# shellcheck disable=SC2034 # read by services/shared/nest.sh, sourced below
PRISMA_PROVIDER="postgresql"
PRISMA_URL="postgresql://app:app@localhost:5432/app"
PRISMA_COMPOSE_URL='postgresql://${DB_USERNAME:-app}:${DB_PASSWORD}@database:5432/${DB_DATABASE:-app}'
# shellcheck source=/dev/null
. "${SCAFFOLD_ROOT}/services/shared/nest.sh"
