# 06 — Docs site

## What it does

- `common/docs/` is a VitePress site and a config root: `docs` is listed in `config_roots` in `common/mise.root.toml` (ADR-0013).
- CI runs its contract tasks like any app's, so a broken path, a malformed ADR or a failed build fails the pipeline.
- One docs workflow, not immich's three (ADR-0009).

## Read this

| File | Why |
| --- | --- |
| `common/docs/mise.toml` | `lint` runs `check-paths.mjs`; `check` runs `check-paths.mjs` and `check-adrs.mjs`; `build` runs VitePress |
| `common/docs/scripts/check-paths.mjs` | Every backticked path in the project's Markdown must exist |
| `common/docs/scripts/check-adrs.mjs` | Every ADR has `Context`, `Decision`, `Consequences`, `Alternatives considered`, a valid `Status`, a unique number |
| `common/.github/workflows/docs.yml` | The docs call site |

## Delete test

Remove `node scripts/check-adrs.mjs` from `check` in `common/docs/mise.toml`.
An ADR missing a required section then passes CI.

## Try it

```bash
grep -n -A1 '^\[tasks' common/docs/mise.toml
```
