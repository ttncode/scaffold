# 01 — Toolchain

## What it does

`mise.toml` pins every language and tool the project uses, and `mise.lock`
records the resolved versions. `mise install` reproduces them exactly on any
machine — this repository's own toolchain (`bats`, `shellcheck`, `yq`, `jq`)
and, in a generated project, `common/mise.root.toml`'s (`node`, `pnpm`,
`lefthook`, `gitleaks`).

## Read this

- `mise.toml` — this toolbox's own tools, plus `[settings] lockfile = true`.
- `common/mise.root.toml` — the template rendered into a generated project's
  root `mise.toml`. Notice what it does *not* pin: no language runtime for
  any adapter.
- `adapters/laravel-api/mise.toml` — a language declared in a local
  `[tools]` block so it never reaches the project root (see 08 — Adapters).
- Upstream for comparison: immich's own root
  `https://github.com/immich-app/immich/blob/351be95/mise.toml`, which pins
  every service's language in one place — the opposite of this project's
  per-adapter split, and the reason ADR-0011 exists.

## Delete test

Delete a *generated project's* `mise.lock` — it ships tracked, since
`common/.gitignore` does not exclude it (this toolbox's own `mise.lock`
does, deliberately: the toolbox resolves its own dev tools fresh, a
client's project should not) — and nothing breaks today: `mise install`
still resolves something. Three months later a client's machine resolves a
newer Node than the one this project was built and tested against, `pnpm
install` behaves slightly differently, and the build fails with nothing in
the error pointing at a version mismatch. `[settings] lockfile = true` in
`common/mise.root.toml` is what turns the pin into something real rather
than decorative: without it, "pinned" only means "pinned until the next
machine resolves it differently."

## Try it

```bash
mise install
mise ls
```
