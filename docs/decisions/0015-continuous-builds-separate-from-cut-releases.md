# 0015 — Continuous builds separate from cut releases

Status: Accepted
Date: 2026-08-28

## Context

Release Please (ADR-0006) maintains a standing release pull request and
only cuts a version when that PR merges. If publishing an image were tied
to that same event, every ordinary merge to `main` would sit behind the
release PR: a client waiting on a fix would have to wait for someone to
also merge the release PR, or for a version bump they may not want yet.

## Decision

Split publishing into two reusable workflows that never gate each other:

- `app-build.yml` runs on every push to `main` and publishes `main` and
  `sha-<commit>` tags. It has no dependency on Release Please.
- `app-release.yml` runs on every push to `main` too, but its `image` and
  `assets` jobs only fire `if: needs.release-please.outputs.released ==
  'true'` — i.e. only on the merge that closes a release PR — and publish
  semver tags (`1.4.0`, `1.4`) plus `latest`.

Both call sites (`common/.github/workflows/build.yml` and `release.yml`)
are separate files with separate triggers, not two jobs in one workflow, so
one failing does not block the other from being invoked at all.

## Consequences

- A client running `IMAGE_TAG=main` (or `sha-<commit>` for something
  pinned but pre-release) always gets the latest merge, immediately.
- A client running `IMAGE_TAG=latest` or a pinned semver only moves on a
  deliberate release — the point of maintaining a release PR at all.
- Both delivery modes exist side by side and differ only by which
  `IMAGE_TAG` a deployment sets; neither workflow needs to know the other
  ran.

## Alternatives considered

- **Publishing an image on every merge, with no separate release step.**
  Rejected: the changelog and version history become noise (every merge is
  "a release"), and a client who wants to operate their own upgrade
  schedule loses the one clearly-marked point to upgrade to.
