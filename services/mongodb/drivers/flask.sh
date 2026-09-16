# shellcheck shell=bash
# ═══════════════════════════════════════════════════════════════════════════
# Script      : services/mongodb/drivers/flask.sh
# Description : How Flask talks to MongoDB.
# Author      : ttncode
# ═══════════════════════════════════════════════════════════════════════════
# Self-contained, like services/mongodb/drivers/laravel.sh: a DSN, not
# decomposed credentials. Sources services/shared/flask.sh only to reuse
# splice_flask_probe, then overrides service_driver_apply,
# service_driver_compose_env and service_driver_compose_migrate; no FLASK_*
# variables are set.
# shellcheck source=/dev/null
. "${SCAFFOLD_ROOT}/services/shared/flask.sh"

service_driver_apply() {
  uv add pymongo || return 1

  write_env_lines .env.example \
    "DATABASE_URL=mongodb://app:app@localhost:27017/app?authSource=admin" \
    || return 1

  # MongoClient is generic; mypy --strict rejects the bare name, so the
  # parameter names the document type.
  splice_flask_probe \
    'import os
from functools import cache
from typing import Any

from pymongo import MongoClient


@cache
def _client() -> MongoClient[dict[str, Any]]:
    return MongoClient(os.environ["DATABASE_URL"])' \
    '        _client().admin.command("ping")'

  # alembic is SQL-only; this is mongodb's equivalent of it having zero
  # revisions — a real command against the real database, with an empty seam
  # for a client's own indexes.
  cat > app/migrate.py <<'EOF' || return 1
from typing import Any

from app.health import _client

# (collection, keys, kwargs) for pymongo's create_index — add one per index as
# the schema grows; empty ships correctly, same as alembic with no revisions.
INDEXES: list[tuple[str, Any, dict[str, Any]]] = []


def main() -> None:
    database = _client().get_default_database()
    for collection, keys, kwargs in INDEXES:
        database[collection].create_index(keys, **kwargs)


if __name__ == "__main__":
    main()
EOF
}

service_driver_compose_env() {
  # shellcheck disable=SC2016 # literal ${...} written into compose.yaml, not expanded here
  printf 'DATABASE_URL: ${DATABASE_URL:-mongodb://${DB_USERNAME:-app}:${DB_PASSWORD}@database:27017/${DB_DATABASE:-app}?authSource=admin}\n'
}

# common/install.sh's run_migrations refuses to start a project that has a
# database service but no migrate service; python, not `mise exec -C`: the
# runtime image has no mise, and the Dockerfile already puts /app/.venv/bin on
# PATH.
service_driver_compose_migrate() {
  printf 'command: ["python", "-m", "app.migrate"]\n'
}
