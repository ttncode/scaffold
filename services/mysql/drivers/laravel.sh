# shellcheck shell=bash
# shellcheck disable=SC2034 # read by services/shared/laravel.sh, sourced below
LARAVEL_CONNECTION="mysql"
LARAVEL_PORT="3306"
# pdo_mysql needs no distribution package; it builds from the php source the
# image already carries.
LARAVEL_PACKAGE=""
LARAVEL_SETUP="RUN docker-php-ext-install pdo_mysql"
# shellcheck source=/dev/null
. "${SCAFFOLD_ROOT}/services/shared/laravel.sh"
