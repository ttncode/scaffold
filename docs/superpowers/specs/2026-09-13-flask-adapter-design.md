# Flask Adapter Design

**Goal:** add a Python API adapter, `flask`, so `scaffold new demo --api flask`
produces a project that lints, type-checks, tests, builds an image and answers
both health probes — the same guarantees the four existing adapters carry.

**Scope:** a new adapter, a new `ADAPTER_FAMILY`, three service drivers, one
smoke suite, and the three places outside `adapters/` that name the families by
hand. No existing adapter changes.

## What was measured before this was written

Every claim below was run, not assumed. The toolchain probe generated a project
with `uv`, wrote the application, and exercised it end to end:

| Step | Result |
| --- | --- |
| `uv init --bare --vcs none --author-from none --no-workspace --python 3.13` | exactly one file, `pyproject.toml` |
| `uv add flask gunicorn`, `uv add --dev ruff mypy pytest` | resolves, writes `uv.lock` |
| `uv run ruff format --check .` | passes |
| `uv run ruff check .` | passes once the readiness handler carries `# noqa: BLE001` |
| `uv run mypy --strict app tests` | passes |
| `uv run pytest -q` | passes only with a `conftest.py` at the application root |
| `gunicorn "app:create_app()"` | `GET /health/live` → 200, `GET /health/ready` → 503 with no database |

Four of those results shaped the design and would not have been guessed:

- **`--bare` is the only usable template.** The default `uv init --app` writes a
  `.git` directory inside the application, a `src/<name>/` package keyed to the
  directory name, a `README.md` and a `[project.scripts]` entry. The overlay
  would have had to delete four of those. `--bare` writes one file and leaves
  the rest to the overlay, which is what every other adapter already does.
- **`--bare` writes no `.python-version`,** with or without `--no-pin-python`,
  so `requires-python` is a floor and uv resolves the newest interpreter it can
  find — 3.14 during the probe. The adapter ships `.python-version` itself.
- **ruff 0.16 rejects `except Exception`** under its default rule set (BLE001).
  A readiness probe catches everything by design, so the handler carries a
  `noqa` pragma rather than a narrowed clause no driver could satisfy.
- **pytest cannot import the application without a root `conftest.py`.** Under
  the default `prepend` import mode pytest inserts `tests/`, not the project
  root, so `from app import create_app` fails. immich's
  `machine-learning/conftest.py` exists for the same reason.

## Decisions

**`uv`, because immich already chose it.** `immich/machine-learning/mise.toml`
pins `python` and `uv` and defines `install`, `lint`, `test`, `format`, `check`,
`ci-unit` and `checklist` — the ADR-0011 vocabulary, already in this
repository's contract. Its tools (uv, ruff, mypy `--strict`, pytest) carry over
unchanged. What does not carry over is the framework: immich's Python service is
FastAPI. The application shape here comes from Flask's own documentation —
application factory plus blueprint — not from a third-party template.

**Python is pinned by `.python-version`, not by `mise.toml`.** uv defaults to
its own managed interpreters, so a `python` entry in the application's
`mise.toml` would be installed and then ignored — two pins, one of them a lie.
`.python-version` is the file uv actually reads, and the application's
`mise.toml` pins `uv` alone. This mirrors `adapters/laravel-api/mise.toml`,
which pins composer alone and lets php come from outside (ADR-0016), and it
keeps the root `mise.toml` unaware that the project contains Python.

**The generator runs uv through `mise x`.** `ADAPTER_GENERATOR` executes in the
project root, where the root `mise.toml` pins node and pnpm and nothing else.
`mise x uv@<version> -- uv init ...` fetches the pinned uv for that one command;
from `ADAPTER_POST_GENERATE` onward the application's own `mise.toml` is in
place and `mise exec` resolves uv from it. No CI step and no ambient
installation is required — the opposite of php, which needs `shivammathur/setup-php`
on every job.

**Four drivers, because the linter requires four.** Python has no Prisma —
SQLAlchemy covers postgres and mysql, mongodb needs pymongo, redis needs its own
client — so the intent was to ship the SQL pair plus redis and add mongodb
later. `lint_services` (`lib/lint.sh:207`) forbids that: it collects every
family declared by any adapter and fails a service that has no driver for one of
them. Skipping mongodb would mean new mechanism for declaring a combination
unsupported, which is more code than the driver it would save. `laravel` is the
shape to copy exactly: a shared body for the two SQL services, and mongodb and
redis each self-contained.

**Tier A, subject to its own measurement.** `uv sync` installs about ten wheels
and compiles nothing, so the smoke run should land well under `laravel-api`'s.
ADR-0012 assigns tiers by measurement, so the PR that adds this adapter reports
its own `smoke (flask)` and `deploy (flask)` durations; if either exceeds
`laravel-api`'s, `ADAPTER_TIER` moves to `B` before merge.

## Work items

### A — The adapter

`adapters/flask/adapter.env`:

```sh
ADAPTER_NAME="flask"
ADAPTER_ROLE="api"
ADAPTER_TIER="A"
ADAPTER_LANGUAGE="python"
ADAPTER_FAMILY="flask"
ADAPTER_GENERATOR='mise x uv@0.12.13 -- uv init --bare --vcs none --author-from none --no-workspace --python 3.13 "$APP_DIR"'
ADAPTER_POST_GENERATE='uv add flask gunicorn && uv add --dev ruff mypy pytest'
ADAPTER_LIVENESS_PATH="/health/live"
ADAPTER_READINESS_PATH="/health/ready"
```

`ADAPTER_POST_GENERATE` ends with the same guard pattern the other adapters use:
a `grep` over `pyproject.toml` for `flask` and `gunicorn` that turns a silent
resolution failure into a build failure.

Files shipped by the overlay:

| File | What it is |
| --- | --- |
| `mise.toml` | pins `uv`; the nine ADR-0011 tasks |
| `.python-version` | `3.13` — the pin `--bare` does not write |
| `Dockerfile` | `uv` build stage, `python:3.13-slim` runtime, `# @SERVICE_SETUP@` anchor, non-root, `EXPOSE 8080`, healthcheck on `/health/live` |
| `.dockerignore` | `.venv`, `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `.env*`, `.git` |
| `app/__init__.py` | `create_app()`, the application factory |
| `app/health.py` | the blueprint, carrying the `# @DB_ENGINE@` and `# @DB_PROBE@` anchors |
| `conftest.py` | empty; puts the application root on `sys.path` for pytest |
| `tests/test_health.py` | two tests that hold with or without a database |
| `.env.example` | `FLASK_DEBUG=0` |
| `lefthook.fragment.yml` | `ruff format` on staged `*.py` |
| `README.md` | as the other adapters have one |

There is no `Dockerfile.workspace`: Python is not a pnpm workspace member, so
`join_typescript_workspace` never sees this adapter and
`assert_workspace_filter_name` returns early on the missing file.

`app/health.py` is the only file a service driver edits:

```python
from flask import Blueprint, Response, jsonify

# @DB_ENGINE@

health = Blueprint("health", __name__)

Reply = Response | tuple[Response, int]


@health.get("/health/live")
def live() -> Reply:
    return jsonify(status="ok")


@health.get("/health/ready")
def ready() -> Reply:
    try:
        # @DB_PROBE@
        raise RuntimeError("no database is configured for this project")
    except Exception as error:  # noqa: BLE001
        return jsonify(status="unavailable", reason=str(error)), 503
```

The `# @DB_ENGINE@` anchor sits above the first statement so a driver's imports
land before executable code and do not trip ruff's E402. A `--db none` project
keeps the `raise` and reports 503, exactly as `adapters/laravel-api/routes/health.php`
does.

The `build` task follows `laravel-api`'s: a production sync, then a restoring
sync, so the pre-commit hook's `ruff` binary survives.

```toml
[tasks.build]
run = "uv sync --locked --no-dev; status=$?; uv sync --locked --quiet; exit $status"
```

### B — Service drivers

`services/shared/flask.sh` holds the SQLAlchemy body, parameterised the way
`services/shared/laravel.sh` is:

| Variable | Meaning |
| --- | --- |
| `FLASK_DIALECT` | the SQLAlchemy URL scheme, e.g. `postgresql+psycopg` |
| `FLASK_PACKAGES` | the DBAPI packages to `uv add` |
| `FLASK_PORT` | the host-side port for `.env.example` |
| `FLASK_COMPOSE_URL` | the same DSN against the compose network |

`service_driver_apply` runs `uv add sqlalchemy <FLASK_PACKAGES>`, writes
`DATABASE_URL` into `.env.example`, and splices both anchors:

```python
# @DB_ENGINE@ becomes
import os
from functools import cache

from sqlalchemy import Engine, create_engine, text


@cache
def _engine() -> Engine:
    return create_engine(os.environ["DATABASE_URL"], pool_pre_ping=True)
```

`@cache` rather than an engine built inside the handler: SQLAlchemy's engine
owns a connection pool, and one per request exhausts the database's connection
limit under a polling probe — the failure `services/shared/nest.sh` records
measuring against Postgres.

`# @DB_PROBE@` and the `raise` line below it become the probe plus a success
return, and the driver greps for both afterwards.

Per-service files:

| File | Contents |
| --- | --- |
| `services/postgres/drivers/flask.sh` | `postgresql+psycopg`, `psycopg[binary]`, 5432 |
| `services/mysql/drivers/flask.sh` | `mysql+pymysql`, `PyMySQL`, 3306 |
| `services/mongodb/drivers/flask.sh` | self-contained: `pymongo`, a cached `MongoClient`, `admin.command("ping")` |
| `services/redis/drivers/flask.sh` | self-contained, as `services/redis/drivers/laravel.sh` is |

`service_driver_dockerfile` prints nothing for all four. `psycopg[binary]`,
`PyMySQL` and `pymongo` all ship wheels that need no system library, so there is
no counterpart to the Laravel drivers' `LARAVEL_SETUP` or to the `pecl install`
the Laravel MongoDB driver needs.

`service_driver_compose_migrate` prints nothing for all four. Flask ships no
migration tool of its own and this adapter adds no ORM models, so there is no
schema to apply — the same reason the redis drivers print nothing.

### C — Everything outside `adapters/` and `services/`

- `tests/service.bats:142` — the regex `^ADAPTER_FAMILY="(laravel|nest|next)"$`
  gains `flask`. It is the one place the family list is written out by hand.
- `tests/new-flask.bats` — a new suite shaped like `tests/new-laravel-api.bats`:
  the app lands at `apps/api`, `uv.lock` exists, python is pinned in the app and
  nowhere near the root `mise.toml`, the ruff hook is merged and suffixed
  `ruff-apps-api`, and a mixed-language project keeps `pnpm-workspace.yaml`'s
  `allowBuilds` while growing no `packages/types`.
- `mise.toml` — `tests/new-flask.bats` needs no entry: the `test-unit` and
  `test-integration` lanes list suites that do not generate an adapter, and the
  per-adapter smoke suites are already run by `.github/workflows/adapters.yml`
  from the tier matrix.
- `README.md` — the adapter table gains a row.
- `docs/PROVENANCE.md` — one row: `adapters/flask/mise.toml` is **adapted** from
  `machine-learning/mise.toml` (the task vocabulary and the uv shape); every
  other file under `adapters/flask/` is **original**, since immich has no Flask
  application and no application factory to adapt.

No new ADR. ADR-0003 already grants the overlay any stack, ADR-0011 already
fixes the task names, ADR-0012 already puts tier on the adapter, and ADR-0016
speaks only about php — `mise x uv` contradicts none of them.

## Not doing

| | Why |
| --- | --- |
| Flask-SQLAlchemy | The extension binds an ORM to the app object; the readiness probe needs one connection and one `SELECT 1`. Plain SQLAlchemy is the smaller dependency. |
| Alembic and a `migrate` task | ADR-0011 keeps `migrate` out of the contract, and this adapter ships no models to migrate. |
| FastAPI as well | The request was Flask. A second Python adapter is a separate decision with its own tier cost. |
| `python` in the root `mise.toml` | ADR-0004's boundary, and the same reason php is absent from it. |

## Verification

- `mise run lint`
- `mise run test-runner` — both lanes
- `scaffold lint` — the adapter and all three drivers against the contract
- `bats tests/new-flask.bats`
- `./scripts/deploy-check.sh flask` against each of `postgres`, `mysql` and `mongodb`
- `mise exec -- zizmor --min-severity medium .github/workflows/`
- the PR's own CI, which reports the `smoke (flask)` and `deploy (flask)`
  durations that decide `ADAPTER_TIER`
- a real project generated from the merged toolbox: `scaffold new`, then its own
  `mise run ci-unit`
