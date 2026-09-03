# shellcheck shell=bash
# shellcheck disable=SC2034 # read by services/shared/nest.sh, sourced below
PRISMA_PROVIDER="postgresql"
PRISMA_URL="postgresql://app:app@localhost:5432/app"
# shellcheck source=/dev/null
. "${SCAFFOLD_ROOT}/services/shared/nest.sh"
