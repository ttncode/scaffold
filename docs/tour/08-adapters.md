# 08 — Adapters

## What it does

An adapter is an overlay, not a vendored application: `scaffold` invokes a
framework's own generator (`create-next-app`, `nest new`, `composer
create-project`) and then copies four files on top of the result —
`adapter.env`, `mise.toml`, `Dockerfile`, `.env.example`. Measured
directly across the four shipping adapters, those four files total 72
lines (`nestjs`) up to 132 (`laravel-inertia`, which — like `laravel-api`
at 103 — also carries a PHP version guard the TypeScript adapters don't
need) — nowhere near a full generated application kept in sync by hand,
but wider than a single fixed figure would suggest.

## Read this

- `adapters/nestjs/adapter.env` — `ADAPTER_NAME`, `ADAPTER_ROLE`,
  `ADAPTER_TIER`, `ADAPTER_LANGUAGE`, `ADAPTER_GENERATOR`, and the optional
  `ADAPTER_POST_GENERATE` for one-time fixups the generator itself gets
  wrong.
- `lib/adapter.sh` — `load_adapter` (reads `adapter.env` into the shell),
  `role_path` (the only place a role maps to a directory — web, api, and
  app roles land under apps/web, apps/api, and apps/app in a *generated*
  project), `apply_adapter` (runs the generator, overlays the four files,
  merges the lefthook fragment).
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
