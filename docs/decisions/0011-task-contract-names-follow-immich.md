# 0011 — Task contract names follow immich

Status: Accepted
Date: 2026-08-25

## Context

CI must run the same command for every application regardless of language. That
requires a fixed vocabulary of task names each adapter implements.

## Decision

Use immich's names verbatim: `install`, `format`, `format-fix`, `lint`,
`check`, `test`, `build`, plus the aggregates `ci-unit` and `checklist`.
`format`, `lint`, and `check` never modify files; the `-fix` variants do.
Dashes are legal in TOML bare keys, and immich itself writes both spellings:
every file that defines `format-fix` quotes it, while other dashed names such
as `ci-unit` and `dev-down` are written bare — so the linter tolerates either.

A name joins the contract only when every configured root implements it and CI
needs to call it. Tasks outside the contract — `migrate`, `queue`, `tinker` —
live in the adapter and are never called by CI.

## Consequences

Reading `immich/server/mise.toml` teaches this repository's layout directly. A
checking task that repairs its own input would pass locally and fail in CI, so
the split is enforced by the linter rather than by convention.

## Alternatives considered

- Inventing clearer names such as `verify` or `typecheck`. Rejected: the value
  of matching a real production repository outweighs marginal clarity.
- A per-role contract, where API adapters additionally guarantee `migrate`.
  Rejected as premature. Promotion is available once every API adapter
  implements it and CI needs to call it.
