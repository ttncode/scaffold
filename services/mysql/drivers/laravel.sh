# shellcheck shell=bash
# shellcheck disable=SC2034 # read by services/shared/laravel.sh, sourced below
LARAVEL_CONNECTION="mysql"
LARAVEL_PORT="3306"
# pdo_mysql needs no distribution package; it builds from the php source the
# image already carries.
LARAVEL_PACKAGE=""
LARAVEL_SETUP="RUN docker-php-ext-install pdo_mysql"
# DB_PASSWORD already reaches the container via compose.yaml's env_file (it
# is in the project's example.env, assembled from this service's own
# env.fragment) — restated here, interpolated rather than baked, so the
# service_driver_compose_env test that guards against a literal password can
# see it the same way the URL-based drivers show theirs.
LARAVEL_COMPOSE_ENV="DB_HOST: database
DB_PORT: 3306
DB_PASSWORD: \${DB_PASSWORD}"
# shellcheck source=/dev/null
. "${SCAFFOLD_ROOT}/services/shared/laravel.sh"
