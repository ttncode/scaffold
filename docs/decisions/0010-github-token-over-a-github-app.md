# 0010 — GITHUB_TOKEN over a GitHub App

Status: Accepted
Date: 2026-08-28
Superseded in part by ADR-0024 (the Release Please token)

## Context

immich wraps every job that needs a token in a GitHub App token
(`immich-app/devtools/actions/create-workflow-token`), minted per run rather
than using the ambient `GITHUB_TOKEN`. That exists because immich is an
organisation with many repositories and untrusted fork contributors: a
scoped, short-lived App token limits what a compromised or malicious
workflow run in one repository can reach across the rest of the
organisation, and lets a PR from a fork run privileged steps safely.

Neither condition holds here. `you/.github` and every project it serves are
single-repository, first-party workflows with no fork contribution model to
defend against.

## Decision

Use the built-in `GITHUB_TOKEN` everywhere, scoped down per job with
`permissions:` (every workflow starts `permissions: {}` and grants only what
that job needs — `contents: read`, `packages: write`, and so on).

> **Amended 2026-09-17.** One exception exists. `app-release.yml`'s
> `release-please` job mints a GitHub App token when the `RELEASE_APP_ID` and
> `RELEASE_APP_PRIVATE_KEY` secrets are set, and falls back to `GITHUB_TOKEN`
> when they are not. `common/.github/workflows/release.yml` passes both, and
> `scaffold publish` sets them from the environment (ADR-0024). A pull request
> opened with `GITHUB_TOKEN` starts no workflow, so its checks wait for
> approval. Every other job still uses `GITHUB_TOKEN`.

## Consequences

- No secret to provision, rotate, or document per project — `GITHUB_TOKEN`
  is issued automatically for every run.
- Roughly ten fewer lines per job than a job-token-then-use pattern would
  add.
- If a later project genuinely needs cross-repository operations (writing
  to a second repository from CI, for instance), `GITHUB_TOKEN` cannot do
  that — this decision would need revisiting for that one case, not
  reversing wholesale.

## Alternatives considered

- Copying immich's `create-workflow-token` flow outright. Rejected as cargo
  cult at this scale: it solves a multi-repository, untrusted-fork problem
  neither `you/.github` nor its generated projects have, in exchange for a
  secret to manage and a dependency on `immich-app/devtools`.
