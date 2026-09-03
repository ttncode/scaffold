# 0019 — Services are not adapters

Status: Accepted
Date: 2026-09-03

## Context

An adapter overlays a framework generator's own output: it owns an
`apps/<role>` directory, an `ADAPTER_GENERATOR` that invokes the framework's
own scaffolding, and satisfies `REQUIRED_ADAPTER_FILES` — `adapter.env`,
`mise.toml`, `Dockerfile`, `.env.example` — files that live inside the
generated application itself.

A database or cache is not that. `--db mysql` runs no generator and writes
nothing under `apps/` — it owns no `apps/<role>` directory at all. mysql,
postgres, mongodb and redis are containers, not applications: the same mysql
container serves a Laravel API and a Nest one identically, so there is no
framework here to overlay. Fitting a service into `adapters/` would mean
inventing an `ADAPTER_GENERATOR` that runs nothing, an `apps/<role>`
directory that holds nothing, and either loosening `REQUIRED_ADAPTER_FILES`
for this one case or shipping four files that describe an application a
service is not.

## Decision

`services/` is a sibling category to `adapters/`, not a kind of adapter.
Each service directory carries its own manifest (`service.env`:
`SERVICE_NAME`, `SERVICE_KIND`, `SERVICE_IMAGE`), its own compose fragments
— a shared body plus a `prod`/`dev`/`test` delta per lane — an
`env.fragment` for the infrastructure side of its configuration, and one
driver per framework family under `drivers/`. `lib/lint.sh`'s
`lint_services` gates it the way `lint_adapters` gates adapters, but
against `REQUIRED_SERVICE_FILES` and `REQUIRED_SERVICE_VARS` instead — a
parallel gate, not a shared one, because the two categories require
different things.

Drivers are keyed on `ADAPTER_FAMILY` (`laravel`, `nest`, `next`), not on
adapter name: `laravel-api` and `laravel-inertia` need identical database
wiring, and a driver per adapter would mean two files holding the same
thing for as long as both adapters exist. `ADAPTER_ROLE=web` takes no
driver at all — the presentation tier opens no connection — stated once,
in `DRIVEN_ROLES`, rather than repeated as a "not applicable" entry in
every service.

## Consequences

Adding a fifth service costs one directory: `service.env`, four compose
fragments, an `env.fragment`, and a driver per family that takes one —
nothing elsewhere in the toolbox changes. Adding an adapter in a new
framework family costs one driver file per existing service, and
`scaffold lint` enforces the full matrix — a family with a driver for
`mysql` and none for `redis` fails lint before anyone generates a project
from it, the same way a missing `adapter.env` field fails it today.

A project's database is decided once, at `scaffold new`, and recorded in
its `mise.toml` (`[vars] database`, read back by `scaffold add` so a
second application joins the same database the first one did). Changing
it after generation would mean rewriting three compose files, every
application's `.env.example`, and undoing one driver's changes in favor of
another's — across files the caller already owns and has likely already
edited by hand. `scaffold` does not attempt it.

## Alternatives considered

- **A new `ADAPTER_ROLE`** (`database`, or similar), reusing `adapters/`
  wholesale. Rejected: every invariant `lib/lint.sh` enforces on an adapter
  — a generator, an `apps/<role>` directory, the four required files — is
  true of a framework overlay and false of a container. Making the role
  fit would mean loosening those checks specifically for services, and a
  check loosened until it cannot fail on the case it exists to catch still
  reads like a guarantee to everyone who did not write the exception.
