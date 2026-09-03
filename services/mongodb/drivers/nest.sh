# shellcheck shell=bash
# shellcheck disable=SC2034 # read by services/shared/nest.sh, sourced below
PRISMA_PROVIDER="mongodb"
# directConnection, because prisma's mongodb provider otherwise expects a
# replica set and a single-node container is not one.
PRISMA_URL="mongodb://app:app@localhost:27017/app?authSource=admin&directConnection=true"
# shellcheck source=/dev/null
. "${SCAFFOLD_ROOT}/services/shared/nest.sh"
