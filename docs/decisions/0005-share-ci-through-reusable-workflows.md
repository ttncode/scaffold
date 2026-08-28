# 0005 — Share CI through reusable workflows

Status: Accepted
Date: 2026-08-28

## Context

`scaffold` copies `common/` into a fresh repository and stops there
(ADR-0004). A project generated in January carries January's CI pipeline
forever unless something keeps it current — there is no prune step, no
template sync, nothing that revisits a generated project after it exists.

## Decision

The pipeline itself does not live in a generated project. It lives in a
second repository, `you/.github`, as five `workflow_call` entrypoints
(`app-ci.yml`, `app-security.yml`, `app-build.yml`, `app-release.yml`,
`app-docs.yml`). `common/.github/workflows/` ships five thin call sites —
one per entrypoint — that only name the reusable workflow and pass its
inputs. Projects reference `you/.github` by the moving tag `v1`, not a
commit or a fixed minor version.

## Consequences

- A fix to CI reaches every project that calls `v1` the next time it runs,
  with no per-project edit.
- The blast radius of a bad change is every project at once, not one.
  Mitigated by running the smoke suite against the workflow repository's
  `main` before moving `v1` to point at it, and by rolling back with a tag
  move rather than a revert-and-redeploy per project.
- A generated project's own `.github/workflows/` carries no logic to fix
  later — the entire reason for the split. Any logic that did end up there
  would need a per-project patch to change, which is exactly what this
  decision avoids.

## Alternatives considered

- Embedding the workflow bodies directly in `common/.github/workflows/`.
  Rejected: every generated project would diverge immediately, and a fix
  found after generating project #5 would never reach projects #1–4.
