# 08 — Adapters

## What it does

- An adapter runs a framework's own generator (`ADAPTER_GENERATOR`), then overlays its files on the output (ADR-0003).
- Required files: `adapter.env`, `mise.toml`, `Dockerfile`, `.env.example`; `adapter.env` and `lefthook.fragment.yml` are read, never copied.
- `ADAPTER_ROLE` (`web`, `api`, `app`) picks the directory: `apps/web`, `apps/api`, `apps/app`.
- For an `api` or `app` adapter, each selected service's `drivers/<family>.sh` runs, keyed on `ADAPTER_FAMILY`, and its Dockerfile block replaces the `# @SERVICE_SETUP@` anchor.
- A `web` adapter takes no driver; the anchor is removed.

![Code layers](../diagrams/code-layers.svg)

## Read this

| File | Why |
| --- | --- |
| `adapters/nestjs/adapter.env` | Every field: name, role, tier, language, family, generator, post-generate, health paths |
| `lib/adapter.sh` | `load_adapter`, `role_path`, `apply_adapter`: generate, overlay, post-generate, drivers, config root, lefthook fragment |
| `lib/service.sh` | `apply_service_drivers`, `apply_service_dockerfile`, `write_env_lines` |
| `services/redis/drivers/nest.sh` | Installs the cache packages and writes `REDIS_URL`; registering `CacheModule` is left to the developer |
| `services/shared/nest.sh` | The Prisma driver body: Prisma 6, `allowBuilds` for its install scripts (ADR-0017) |
| `scripts/adapter-matrix.sh` | Tier A and B CI matrices from `scaffold list --adapters` (ADR-0012) |
| `docs/runbook/add-an-adapter.md` | The steps to add one |

## Delete test

Delete an adapter's `adapter.env` and `scaffold lint` reports `missing file adapter.env`.
Set `ADAPTER_TIER` to an unknown value and `scripts/adapter-matrix.sh` fails, naming the adapter.

## Try it

```bash
./scaffold list --adapters
```
