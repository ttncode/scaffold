# shellcheck shell=bash
# ═══════════════════════════════════════════════════════════════════════════
# Script      : services/postgres/drivers/flask.sh
# Description : PostgreSQL parameters for the shared Flask driver.
# Author      : ttncode
# ═══════════════════════════════════════════════════════════════════════════
# shellcheck disable=SC2034 # read by services/shared/flask.sh, sourced below
FLASK_DIALECT="postgresql+psycopg"
# the [binary] extra ships a wheel with libpq inside, so the image needs no
# system package and service_driver_dockerfile stays empty
FLASK_PACKAGE="psycopg[binary]"
FLASK_PORT="5432"
# shellcheck disable=SC2016 # literal ${...} written into compose.yaml, not expanded here
FLASK_COMPOSE_URL='postgresql+psycopg://${DB_USERNAME:-app}:${DB_PASSWORD}@database:5432/${DB_DATABASE:-app}'
# shellcheck source=/dev/null
. "${SCAFFOLD_ROOT}/services/shared/flask.sh"
