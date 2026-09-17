# 01 — Toolchain

## What it does

- `mise.toml` pins every tool; `[settings] lockfile = true` makes `mise.lock` record the resolved versions.
- `mise install` reproduces them on any machine.
- The toolbox pins its own tools (`bats`, `shellcheck`, `shfmt`, `jq`, `yq`, …).
- A generated project's root pins `node`, `pnpm`, `lefthook`, `gitleaks`; an app's own `mise.toml` adds only what it needs beyond those.

## Read this

| File | Why |
| --- | --- |
| `mise.toml` | The toolbox's tools and its `lockfile = true` |
| `common/mise.root.toml` | Rendered into a generated project's root `mise.toml` |
| `adapters/laravel-inertia/mise.toml` | App-local `[tools]`: composer and node; php comes from the system (ADR-0016) |
| `adapters/flask/mise.toml` | Pins `uv`, not python: uv installs the version in `adapters/flask/.python-version` |

## Delete test

Delete `mise.lock` and `mise install` still succeeds.
What is lost is each tool's recorded backend, download URL and checksum per platform, so nothing checks a download against the one tested.

## Try it

```bash
mise install
mise ls
```
