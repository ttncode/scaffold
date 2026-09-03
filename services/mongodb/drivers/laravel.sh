# shellcheck shell=bash
# shellcheck disable=SC2034 # read by services/shared/laravel.sh, sourced below
LARAVEL_CONNECTION="mongodb"
LARAVEL_PORT="27017"
LARAVEL_PACKAGE="mongodb/laravel-mongodb"
# ext-mongodb: composer would otherwise refuse to resolve laravel-mongodb on
# any host lacking the extension, and the extension lives in the image built
# below, not on the machine running scaffold new.
LARAVEL_PLATFORM_REQ="ext-mongodb"
# pecl, not apk: the mongodb extension is not in alpine's repositories, so it
# is built here — which is why this block installs the build dependencies and
# nothing else does.
LARAVEL_SETUP="RUN apk add --no-cache --virtual .build-deps \$PHPIZE_DEPS openssl-dev \\
 && pecl install mongodb \\
 && docker-php-ext-enable mongodb \\
 && apk del .build-deps"
# shellcheck source=/dev/null
. "${SCAFFOLD_ROOT}/services/shared/laravel.sh"
