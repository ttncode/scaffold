# Two `scaffold add` bugs — to fix next

Date: 2026-10-14
Status: found by reading the code while checking the withdrawn `opensocial`
request; neither is reproduced by a test yet. Each needs its own brainstorm,
fix and bats test.

## 1. `scaffold add` repoints the compose `migrate` service

`cmd_add` runs the service drivers for every added `api` or `app`.
`apply_service_compose_migrate` (`lib/service.sh`) then merges a `migrate`
service with `yq`'s `*`, which overwrites the existing `image` and `command`.
After `scaffold new --api nestjs --db postgres` then
`scaffold add apps/worker --adapter flask`, `migrate` runs the worker's image
with `alembic upgrade head`, not the api's Prisma migrations, and exits 0.
The comment above the call ("nothing generates that shape") is wrong.

Proposed fix: keep an existing `migrate` service, so the first backend owns
migrations. Amend ADR-0022.

Fixed on 2026-10-16 as proposed, with a unit test in `tests/service.bats` and
an integration test in `tests/add-app.bats`.

## 2. A TypeScript app added outside the workspace globs loses its lockfile

`joins_shared_workspace` (`scaffold`) checks only that the workspace has
`packages:` and the adapter is TypeScript, not that the new app's path matches
a glob (`apps/*`, `packages/*`, `docs`). For
`scaffold add services/x --adapter nestjs` in an all-TypeScript project,
`sync_workspace_lockfile` deletes `services/x/pnpm-lock.yaml`, the root
install skips the non-member app, and its standalone `Dockerfile` copies the
deleted lockfile.

Proposed fix: also require `app_is_workspace_member "$project" "$rel"`; the
app then stays standalone with its own lockfile. Amend ADR-0018.
