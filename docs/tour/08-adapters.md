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

## Read this

- `adapters/nestjs/adapter.env` — `ADAPTER_NAME`, `ADAPTER_ROLE`,
  `ADAPTER_TIER`, `ADAPTER_LANGUAGE`, `ADAPTER_GENERATOR`, and the optional
  `ADAPTER_POST_GENERATE` for one-time fixups the generator itself gets
  wrong.
- `lib/adapter.sh` — `load_adapter` (reads `adapter.env` into the shell),
  `role_path` (the only place a role maps to a directory — web, api, and
  app roles land under apps/web, apps/api, and apps/app in a *generated*
  project), `apply_adapter` (runs the generator, overlays every file the adapter
  ships except `adapter.env`, merges the lefthook fragment).
- ADR-0003 for the overlay decision itself, ADR-0012 for how tiers decide
  what CI actually runs, ADR-0018 for why adding a second adapter later
  never retroactively rewires the shared TypeScript workspace.

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
