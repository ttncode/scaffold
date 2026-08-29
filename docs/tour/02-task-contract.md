# 02 — Task contract

## What it does

Every adapter implements the same nine task names — `install`, `format`,
`format-fix`, `lint`, `check`, `test`, `build`, `ci-unit`, `checklist` — so
CI can run the identical command against a Laravel API, a Next.js app, or a
NestJS service without ever knowing which one it is. `format`, `lint`, and
`check` are read-only by contract; only the `-fix` variant is allowed to
write. That split exists so a checking task that quietly repairs its own
input can't pass locally and then fail in CI against a clean checkout.

## Read this

- `lib/contract.sh` — `CONTRACT_TASKS`, the exact nine names, and
  `REQUIRED_ADAPTER_FILES`, the four files every adapter must ship.
- `lib/lint.sh` — `lint_adapters`, which checks both of those against every
  directory in `adapters/`.
- `adapters/nestjs/mise.toml` — one adapter's full implementation of the
  contract; compare `check` (`tsc --noEmit`, read-only) against
  `format-fix` (writes).
- ADR-0011 for why the names are immich's own rather than something
  invented for this project.
- Upstream for comparison:
  `https://github.com/immich-app/immich/blob/351be95/server/mise.toml`.

## Delete test

Delete `lib/contract.sh` and `scaffold` fails immediately — it's sourced by
name at the top of the script, and `set -euo pipefail` means a missing
source file stops execution before any command runs. That's the good case:
unlike `mise.lock`, there's no silent window where this looks fine. The
quieter failure is deleting one *entry* from `CONTRACT_TASKS` instead: an
adapter that already implements the removed task keeps working, CI stops
calling it, and nobody notices until the day someone assumes the contract
still calls a task it stopped calling months ago.

## Try it

```bash
mise exec -- ./scaffold lint
```
