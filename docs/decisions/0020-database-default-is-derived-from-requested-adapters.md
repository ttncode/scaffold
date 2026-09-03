# 0020 — MySQL is the default database

Status: Accepted
Date: 2026-09-03

## Context

Before `--db` and `--cache` existed, every generated project shipped
PostgreSQL — not chosen, the only option, written directly into
`common/compose.yaml`, `common/compose.dev.yaml`, `common/compose.test.yaml`,
and both Laravel Dockerfiles (`pdo_pgsql`). A project with no backend still
got a database service and an `app` container waiting on its health check;
the `nestjs` adapter's own `.env.example` named a `DATABASE_URL` no
installed client could open.

A flag with no default ships that same behavior to anyone who runs
`scaffold new` without thinking about databases — which was everyone, since
there was nothing to think about before.

## Decision

`--db` defaults to `mysql` when the project has an `api` or `app` adapter,
and to `none` otherwise — derived from the requested adapters, not fixed,
so a frontend-only project stops shipping a database it cannot use.
`--cache` always defaults to `none`: a cache is a performance decision a
client makes deliberately, not one this toolbox makes on their behalf.

`--db` or `--cache` with a value other than `none` on a project with
neither `--api` nor `--app` is refused. The `web` tier has no driver
(ADR-0019), so the service would run with nothing in the generated project
able to reach it.

## Consequences

Projects generated from 2026-09-03 differ from projects generated before
it: the default database changes from PostgreSQL to MySQL, and a
frontend-only project stops shipping a database at all. `scaffold` never
revisits a project it already generated, so nothing about an existing
project migrates — this decision governs `scaffold new` from here on, not
what is already running.

`postgres` remains available on request (`--db postgres`); it is no longer
what a caller gets by saying nothing.
