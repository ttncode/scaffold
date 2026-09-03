# 08 — Adapters

## What it does

An adapter is an overlay, not a vendored application: `scaffold` invokes a
framework's own generator (`create-next-app`, `nest new`, `composer
create-project`) and then copies its own files on top of the result.
`lib/lint.sh` requires four of them — `adapter.env`, `mise.toml`,
`Dockerfile`, `.env.example` — and an adapter may ship more: `nextjs` adds
`next.config.ts` and `.prettierignore`, `laravel-api` adds `phpstan.neon`
and a `docker/` directory. `adapter.env` is the one exception to the copy:
it is sourced, never written into the app.

The overlay is small by construction — tens of lines per adapter, not a
generated application kept in sync by hand. Run `scaffold list` for what
ships today rather than trusting a figure written here, which goes stale
the first time an adapter gains a file.

Every Dockerfile that can take a database or cache ships a
`# @SERVICE_SETUP@` anchor comment. Once the generator and any
`ADAPTER_POST_GENERATE` have settled the package manager's state,
`apply_adapter` calls `apply_service_drivers`, which runs each selected
service's `drivers/<family>.sh` — keyed on `ADAPTER_FAMILY`, not the
adapter's own name, because the two Laravel adapters need identical wiring
— and concatenates every driver's `service_driver_dockerfile` output in
place of the anchor. A driver is expected to do two things: install
whatever the framework needs to reach the service (a composer package, a
pnpm package, a Prisma schema) and write the connection variables into
`.env.example` with `write_env_lines`, never a bare append, since a driver
runs against an `.env.example` the adapter already shipped. `nextjs`'s
Dockerfile ships the anchor like every other adapter's — `tests/service.bats`
requires it on all of them — but `ADAPTER_ROLE=web` takes no driver at all,
so `apply_adapter` calls `apply_service_setup` with an empty block, which
removes the anchor outright rather than replacing it. A Dockerfile that
ships the anchor unreplaced fails to build.

## Read this

- `adapters/nestjs/adapter.env` — `ADAPTER_NAME`, `ADAPTER_ROLE`,
  `ADAPTER_TIER`, `ADAPTER_LANGUAGE`, `ADAPTER_FAMILY`, `ADAPTER_GENERATOR`,
  and the optional `ADAPTER_POST_GENERATE` for one-time fixups the
  generator itself gets wrong.
- `lib/adapter.sh` — `load_adapter` (reads `adapter.env` into the shell),
  `role_path` (the only place a role maps to a directory — web, api, and
  app roles land under apps/web, apps/api, and apps/app in a *generated*
  project), `apply_adapter` (runs the generator, overlays every file the adapter
  ships except `adapter.env`, merges the lefthook fragment, then runs the
  service drivers described above).
- `services/shared/nest.sh` — the Prisma driver body every `nest`-family
  database service sources. Pinned to Prisma major 6, not `@latest`:
  major 7 drops the datasource `url` field this driver writes, in favor of
  a `prisma.config.ts` adapter — a bigger change than a driver that only
  ever writes `datasource` and `generator` blocks should force on every
  service. The same file sets `allowBuilds` for `prisma`, `@prisma/engines`
  and `@prisma/client` in the project's `pnpm-workspace.yaml`: none of the
  three ships a pure-JS fallback for its install-time binary fetch, and
  pnpm blocks an unapproved postinstall build by default
  (`ERR_PNPM_IGNORED_BUILDS`) — the same guard ADR-0017 already names for
  `unrs-resolver` and `esbuild`.
- ADR-0003 for the overlay decision itself, ADR-0012 for how tiers decide
  what CI actually runs, ADR-0018 for why adding a second adapter later
  never retroactively rewires the shared TypeScript workspace, and
  ADR-0019 for why `services/` is a category of its own rather than a kind
  of adapter.

## Delete test

Delete an adapter's `adapter.env` and `scaffold lint` catches it
immediately — `lint_adapters` checks for all four required files on every
run. The quieter failure is a typo inside a field that still parses: set
`ADAPTER_TIER` to an unrecognised value and, before the fix this project
had to make, the adapter simply vanished from every CI matrix with exit 0
— no adapters.yml job ever mentioned it again, and nothing pointed at
`adapter.env` as the place to look. `scripts/adapter-matrix.sh`'s
`validate_tiers` now fails loudly, by name, on exactly that case.

## Try it

```bash
mise exec -- ./scaffold list
```
