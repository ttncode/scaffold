# shellcheck shell=bash
# ═══════════════════════════════════════════════════════════════════════════
# Script      : services/shared/flask.sh
# Description : The shared Flask SQLAlchemy driver body.
# Author      : ttncode
# ═══════════════════════════════════════════════════════════════════════════
# A service's drivers/flask.sh sets these and sources this. mysql and postgres
# only — mongodb is self-contained: pymongo has no SQLAlchemy dialect, so its
# driver defines its own service_driver_apply after sourcing this file, kept
# only for splice_flask_probe.
#
#   FLASK_DIALECT      the SQLAlchemy URL scheme, e.g. postgresql+psycopg
#   FLASK_PACKAGES     the DBAPI package to `uv add` alongside sqlalchemy
#   FLASK_PORT         the host-side port written into .env.example
#   FLASK_COMPOSE_URL  the same DSN against the compose network

service_driver_apply() {
  uv add sqlalchemy "$FLASK_PACKAGES" || return 1

  write_env_lines .env.example \
    "DATABASE_URL=${FLASK_DIALECT}://app:app@localhost:${FLASK_PORT}/app" \
    || return 1

  splice_flask_probe \
    'import os
from functools import cache

from sqlalchemy import Engine, create_engine, text


@cache
def _engine() -> Engine:
    return create_engine(os.environ["DATABASE_URL"], pool_pre_ping=True)' \
    '        with _engine().connect() as connection:
            connection.execute(text("SELECT 1"))'
}

service_driver_dockerfile() {
  :
}

service_driver_compose_env() {
  printf 'DATABASE_URL: ${DATABASE_URL:-%s}\n' "$FLASK_COMPOSE_URL"
}

# this adapter ships no models and Flask has no migration tool of its own, so
# there is no schema to apply.
service_driver_compose_migrate() {
  :
}

# splice_flask_probe <engine-block> <probe-block>
# Used by all four drivers, so the anchor names and the verification live in
# one place.
#
# awk, not sed: both blocks are multi-line and carry /, " and backslashes that
# sed's replacement syntax would eat. ENVIRON, not -v, for the same reason
# write_env_lines uses it.
splice_flask_probe() {
  local -r engine="$1" probe="$2"
  local -r file=app/health.py

  ENGINE="$engine" PROBE="$probe" awk '
    $0 == "# @DB_ENGINE@" { print ENVIRON["ENGINE"]; next }
    $0 == "        # @DB_PROBE@" { print ENVIRON["PROBE"]; next }
    $0 == "        raise RuntimeError(\"no database is configured for this project\")" {
      print "        return jsonify(status=\"ok\")"; next
    }
    { print }
  ' "$file" > "${file}.tmp" || return 1
  mv "${file}.tmp" "$file"

  grep -q 'return jsonify(status="ok")' "$file" \
    && ! grep -q '@DB_ENGINE@' "$file" \
    && ! grep -q '@DB_PROBE@' "$file" \
    || die "could not splice the database probe into app/health.py — has the anchor moved?"

  # The engine block's stdlib imports land below flask's own import, which
  # ruff's isort rule (I001) and its formatter both reject — reformat once
  # rather than hand-ordering imports per driver, the same move
  # services/shared/nest.sh makes with prettier.
  uv run ruff check --fix "$file" || return 1
  uv run ruff format "$file" || return 1
}
