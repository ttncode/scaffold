# shellcheck shell=bash
# shellcheck disable=SC2034 # read by services/shared/nest.sh, sourced below
PRISMA_PROVIDER="mysql"
PRISMA_URL="mysql://app:app@localhost:3306/app"
# shellcheck source=/dev/null
. "${SCAFFOLD_ROOT}/services/shared/nest.sh"
