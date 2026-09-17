# Add an adapter

When: a framework needs to be generated that `scaffold list --adapters` does not show.

## Steps

1. Create the directory.

   ```bash
   mkdir -p adapters/<name>
   ```

2. Write `adapters/<name>/adapter.env`. `adapters/flask/adapter.env` is a complete example.

   ```bash
   ADAPTER_NAME="<name>"
   ADAPTER_ROLE="api"                 # web, api or app
   ADAPTER_TIER="B"                   # A, B or C (ADR-0012)
   ADAPTER_LANGUAGE="go"              # "typescript" opts into the shared pnpm workspace
   ADAPTER_FAMILY="<family>"          # which service driver wires it (ADR-0019)
   ADAPTER_GENERATOR='<the framework generator, writing into "$APP_DIR">'
   ADAPTER_LIVENESS_PATH="/health/live"
   ADAPTER_READINESS_PATH="/health/ready"   # required for api and app, omitted for web
   # ADAPTER_POST_GENERATE='<one-time fixup after the generator>'
   ```

   | Field | Rule |
   | --- | --- |
   | Required | `ADAPTER_NAME`, `ADAPTER_ROLE`, `ADAPTER_FAMILY`, `ADAPTER_GENERATOR`, `ADAPTER_LIVENESS_PATH` (`REQUIRED_ADAPTER_VARS` in `lib/contract.sh`) |
   | No generator | Use the package manager's init: `adapters/flask` runs `uv init --bare` |
   | `ADAPTER_POST_GENERATE` | Optional. For a generator bug (`adapters/nestjs`) or a manifest-only generator (`adapters/flask` runs `uv add`). End it with a `grep` that fails when nothing was written |

3. Write `adapters/<name>/mise.toml` with all nine contract tasks (`CONTRACT_TASKS` in `lib/contract.sh`).
   - Pin the language in a local `[tools]` block, never at the project root. Where the language's own tool owns the pin, pin that tool: `adapters/flask` pins `uv`, and `adapters/flask/.python-version` pins python.
   - `format`, `lint` and `check` must not write; `scaffold lint` rejects `--write`, `--fix` and similar flags in them.

4. Write the overlay files. Every file in the directory is copied into the app except `adapter.env` and `lefthook.fragment.yml` (ADR-0003).

   | File | Rule |
   | --- | --- |
   | `Dockerfile` | Multi-stage, base images pinned by digest, `EXPOSE 8080`, a `HEALTHCHECK` that probes `ADAPTER_LIVENESS_PATH`, never copies a `.env` (`tests/compose.bats`) |
   | `Dockerfile.workspace` | TypeScript only: the variant built from the workspace root |
   | `.dockerignore` | Required by `tests/compose.bats` |
   | `.env.example` | The app's own variables |
   | `lefthook.fragment.yml` | Hooks merged into the project's `lefthook.yml`; `{}` for none |

5. For an `api` or `app` role, add `services/<service>/drivers/<family>.sh` to every service, unless the family already has drivers.

6. Copy `tests/new-laravel-api.bats` to `tests/new-<name>.bats` and change the adapter name. Keep the assertion that the language never reaches the project's root `mise.toml`.

## Verify

```bash
./scaffold lint
./scaffold new ../probe --api <name>
(cd ../probe && mise run //apps/api:checklist)
bats tests/new-<name>.bats
./scaffold list --adapters
```

- `scaffold lint` prints nothing and exits 0.
- `scaffold list --adapters` shows the adapter with its tier.

For a TypeScript adapter, also check a second TypeScript app in the same workspace, both ways:

```bash
./scaffold new ../probe2 --api <name> --web nextjs
./scaffold new ../probe3 --api nestjs
toolbox="$PWD"
(cd ../probe3 && "$toolbox/scaffold" add apps/<name> --adapter <name>)
find ../probe3 -name pnpm-lock.yaml -not -path '*/node_modules/*'   # exactly one, at the root
test -f ../probe3/packages/types/package.json && echo "types package: ok"
grep confirmModulesPurge ../probe3/pnpm-workspace.yaml             # no match
```

Delete the probe projects afterwards.

## Promote to Tier A

Set `ADAPTER_TIER="A"` in `adapter.env`. `scripts/adapter-matrix.sh` reads tiers through `scaffold list`, so `.github/workflows/adapters.yml` needs no edit (ADR-0012).

## If it fails

| Symptom | Fix |
| --- | --- |
| `scaffold lint` names a missing driver | Step 5: add `drivers/<family>.sh` to that service |
| `scaffold lint` says a read-only task writes | Remove the writing flag from `format`, `lint` or `check` |
| A caller's own `confirmModulesPurge: false` line vanished after `scaffold add` | Known gap: `restore_pnpm_workspace` in `lib/pnpm.sh` strips it by text match (ADR-0017). Add it back |
