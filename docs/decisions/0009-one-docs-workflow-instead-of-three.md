# 0009 — One docs workflow instead of three

Status: Accepted
Date: 2026-08-29

## Context

immich runs three separate documentation workflows: `docs-build`, which runs
in an untrusted pull-request context and therefore must never hold secrets;
`docs-deploy`, which needs Cloudflare credentials and so runs on
`workflow_run` once a build from a trusted context succeeds; and
`docs-destroy`, which tears down a preview deployment explicitly because the
infrastructure it deploys to is self-managed.

Neither precondition holds here. `you/.github` and every project it serves
are single-repository, first-party workflows with no fork-contribution model
to defend against, and nothing about deployment is self-managed.

## Decision

One workflow, `app-docs.yml`, that builds the site as a gate — a broken build
fails CI the same as a failing test. Preview deployments and teardown are not
built at all; they are handled by connecting Cloudflare Pages to the
repository directly, outside this pipeline.

## Consequences

Three workflows become one. There is no automated preview URL on a pull
request and no automated teardown to reason about, because Cloudflare Pages'
own repository integration owns both. Revisit this if documentation must be
self-hosted instead of on Cloudflare Pages, or if the repository starts
accepting pull requests from forks — the untrusted-build-context problem
immich's split defends against would then apply here too.

## Alternatives considered

- Copying all three of immich's workflows outright. Rejected: substantial
  machinery — a secrets-free build stage, a `workflow_run` handoff, and an
  explicit teardown job — for a problem a Cloudflare Pages repository
  integration already solves without any of it.
