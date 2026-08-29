# 06 — Docs site

## What it does

`common/docs/` is not a side project — it's a config root (ADR-0013),
registered in `common/mise.root.toml`'s `config_roots` alongside every app.
That means its `check` and `build` tasks run in CI exactly like an app's
`test` and `build` do: a broken VitePress build, a dead internal link, or a
malformed ADR fails the pipeline the same way a failing unit test would.

## Read this

- `common/docs/mise.toml` — `check` runs two structural scripts before
  `build` ever runs VitePress.
- `common/docs/scripts/check-paths.mjs` — every backticked path-looking
  string in the generated project's own Markdown must resolve to a real
  file.
- `common/docs/scripts/check-adrs.mjs` — every ADR under
  `common/docs/decisions/` needs `Context`, `Decision`, `Consequences`,
  and `Alternatives considered`, a valid `Status`, and a non-duplicate
  number.
- ADR-0009 for one docs workflow instead of immich's three, ADR-0001 for
  why `mise` tasks are the mechanism at all.

## Delete test

Delete `common/docs/scripts/check-paths.mjs` and nothing breaks today —
`check` still runs `check-adrs.mjs` and reports success. Months later,
someone renames a directory the docs reference, the reference goes stale,
and the only signal is a reader hitting a dead link in the published site —
exactly the "documentation that CI does not verify is wrong within six
months" comment in `common/docs/mise.toml` describes. The check exists
specifically because that failure mode has no other detector.

## Try it

```bash
node common/docs/scripts/check-adrs.mjs && echo "all ADRs valid"
```
