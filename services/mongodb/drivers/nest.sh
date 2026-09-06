# shellcheck shell=bash
# shellcheck disable=SC2034 # read by services/shared/nest.sh, sourced below
PRISMA_PROVIDER="mongodb"
# authSource=admin is the parameter this actually depends on: the container
# creates the user in `admin`, and without it prisma authenticates against
# `app` and fails with a SCRAM error. directConnection is kept for prisma's
# mongodb provider, which otherwise expects a replica set — measured against a
# single-node container it changes nothing for `db push`, so treat it as
# unproven for anything but transactional writes.
PRISMA_URL="mongodb://app:app@localhost:27017/app?authSource=admin&directConnection=true"
# shellcheck source=/dev/null
. "${SCAFFOLD_ROOT}/services/shared/nest.sh"
