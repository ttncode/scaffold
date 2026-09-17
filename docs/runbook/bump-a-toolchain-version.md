# Bump a toolchain version

When: a pinned tool needs a new version, in the toolbox or in what it generates.

## Steps

1. Find the pin.

   | Tool | Pinned in |
   | --- | --- |
   | This toolbox's tools: `bats`, `shellcheck`, `shfmt`, `yq`, `jq`, `zizmor`, `rush`, `lefthook`, `gitleaks` | `mise.toml` |
   | Every generated project: `node`, `pnpm`, `lefthook`, `gitleaks` | `common/mise.root.toml` |
   | One adapter's toolchain, e.g. composer for `laravel-api`, node for `laravel-inertia` | `adapters/<name>/mise.toml` |
   | `flask`'s python | `adapters/flask/.python-version` and the `--python` argument in `adapters/flask/adapter.env` |
   | php | Not pinned: system php, checked by each Laravel adapter's `install` task (ADR-0016) |

2. Edit the version string. Leave the rest of the `[tools]` block alone.

3. `lefthook` and `gitleaks` are pinned twice. Change `mise.toml` and `common/mise.root.toml` together.

4. Re-resolve this toolbox's lock.

   ```bash
   mise install
   mise lock
   ```

   `common/` ships no `mise.lock`. `scaffold new` runs `mise lock` in each new project (`lock_toolchains` in `lib/project.sh`).

## Verify

```bash
git diff mise.lock
mise run checklist
```

For a `common/` or adapter bump, also generate a project and run its checklist:

```bash
./scaffold new ../probe --api nestjs
(cd ../probe && mise run checklist)
```

Delete the probe project afterwards.

## If it fails

| Symptom | Fix |
| --- | --- |
| A generated project warns `could not lock the toolchain` | Run `mise lock` in that project, then commit `mise.lock` |
| `laravel-api` fails `install` with `requires system php >= 8.3.0` | Install php 8.3 or newer on the host; mise cannot (ADR-0016) |
