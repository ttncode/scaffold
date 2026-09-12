# shellcheck shell=bash
# ═══════════════════════════════════════════════════════════════════════════
# Script      : services/mysql/drivers/nest.sh
# Description : MySQL parameters for the shared Prisma driver.
# Author      : ttncode
# ═══════════════════════════════════════════════════════════════════════════
# shellcheck disable=SC2034 # read by services/shared/nest.sh, sourced below
PRISMA_PROVIDER="mysql"
PRISMA_URL="mysql://app:app@localhost:3306/app"
PRISMA_COMPOSE_URL='mysql://${DB_USERNAME:-app}:${DB_PASSWORD}@database:3306/${DB_DATABASE:-app}'
# shellcheck source=/dev/null
. "${SCAFFOLD_ROOT}/services/shared/nest.sh"
