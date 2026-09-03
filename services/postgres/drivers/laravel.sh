# shellcheck shell=bash
# shellcheck disable=SC2034 # read by services/shared/laravel.sh, sourced below
LARAVEL_CONNECTION="pgsql"
LARAVEL_PORT="5432"
LARAVEL_PACKAGE=""
LARAVEL_SETUP="RUN apk add --no-cache postgresql-dev \\
 && docker-php-ext-install pdo_pgsql"
# shellcheck source=/dev/null
. "${SCAFFOLD_ROOT}/services/shared/laravel.sh"
