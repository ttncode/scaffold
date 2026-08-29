# Bump a toolchain version

## 1. Find where the version is pinned

- This toolbox's own tools (`bats`, `shellcheck`, `yq`, `jq`): `mise.toml`
  at the repository root.
- What ships into every generated project (`node`, `pnpm`, `lefthook`,
  `gitleaks`): `common/mise.root.toml`.
- One adapter's own language (`php`'s Composer, or the pinned Node used by
  `laravel-inertia`'s build step): that adapter's own `mise.toml`, e.g.
  `adapters/laravel-api/mise.toml`.

## 2. Edit the version

Change the version string for the tool in question. Leave everything else
in the `[tools]` block alone.

## 3. Re-resolve the lock

```bash
mise install
```

This rewrites `mise.lock` (for this toolbox's own tools) with the newly
resolved version and checksum. A generated project has no shipped
`mise.lock` of its own — the client's first `mise install` produces it —
so a `common/`-level bump has nothing local to re-lock here.

## 4. Verify

```bash
mise run checklist
```

For a `common/`-level bump specifically, also generate a throwaway project
and run its own checklist, since nothing in this repository's own suite
exercises `common/mise.root.toml` end to end the way a real generation
does:

```bash
./scaffold new /tmp/probe --api nestjs && cd /tmp/probe && mise run checklist
```

## Done when

`mise run checklist` passes here, the probe project's own checklist
passes, and `mise ls` shows the new version resolved and installed. This
toolbox's own `mise.lock` is gitignored (unlike a generated project's, see
docs/tour/01-toolchain.md), so there's nothing to `git diff` here — `mise
ls` is the check.
