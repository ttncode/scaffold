# shellcheck shell=bash
# shellcheck disable=SC2034 # read by services/shared/laravel.sh, sourced below
LARAVEL_CONNECTION="pgsql"
LARAVEL_PORT="5432"
LARAVEL_PACKAGE=""
LARAVEL_SETUP="RUN apk add --no-cache postgresql-dev \\
 && docker-php-ext-install pdo_pgsql"
# DB_PASSWORD already reaches the container via compose.yaml's env_file (it
# is in the project's example.env, assembled from this service's own
# env.fragment) — restated here, interpolated rather than baked, so the
# service_driver_compose_env test that guards against a literal password can
# see it the same way the URL-based drivers show theirs.
LARAVEL_COMPOSE_ENV="DB_HOST: database
DB_PORT: 5432
DB_PASSWORD: \${DB_PASSWORD}"
# shellcheck source=/dev/null
. "${SCAFFOLD_ROOT}/services/shared/laravel.sh"
