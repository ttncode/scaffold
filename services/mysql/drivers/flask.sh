# shellcheck shell=bash
# ═══════════════════════════════════════════════════════════════════════════
# Script      : services/mysql/drivers/flask.sh
# Description : MySQL parameters for the shared Flask driver.
# Author      : ttncode
# ═══════════════════════════════════════════════════════════════════════════
# shellcheck disable=SC2034 # read by services/shared/flask.sh, sourced below
FLASK_DIALECT="mysql+pymysql"
# pure python, so no build stage and no system package
FLASK_PACKAGES="PyMySQL"
FLASK_PORT="3306"
FLASK_COMPOSE_URL='mysql+pymysql://${DB_USERNAME:-app}:${DB_PASSWORD}@database:3306/${DB_DATABASE:-app}'
# shellcheck source=/dev/null
. "${SCAFFOLD_ROOT}/services/shared/flask.sh"
