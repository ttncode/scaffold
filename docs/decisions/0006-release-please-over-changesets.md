# 0006 — Release Please over changesets

Status: Accepted
Date: 2026-08-28

## Context

A project this toolbox generates is an application delivered to one client,
not a package published to a registry. It still needs a version to pin in
`compose.yaml`'s `IMAGE_TAG`, a changelog a client can read, and a concrete
point in history a release attaches artifacts to (`compose.yaml`,
`example.env`, `install.sh` — see ADR-0014).

## Decision

`app-release.yml` runs Release Please
(`common/release-please-config.json`, `common/.release-please-manifest.json`)
reading Conventional Commit messages, not changesets. Every commit in a
generated project must be conventional — enforced locally at `commit-msg`
(lefthook + commitlint, already shipped) and again by CI, since a local hook
can be bypassed.

## Consequences

- A version to pin, a generated changelog, and a GitHub Release to attach
  release assets to, all come from parsing commit history — no separate
  changeset file to author per change.
- A rollback marker exists for free: the previous tag.
- Every contributor's commit messages become load-bearing; a malformed one
  either gets caught by the local hook or shows up unclassified in the next
  changelog.

## Alternatives considered

- **Changesets.** Rejected: it is built for versioning many packages
  independently inside one repository and publishing them with `npm
  publish`. A generated project here is one deployable unit, not a
  package graph — changesets would add a workflow (author a changeset file
  per change) for a publishing step this project doesn't perform, at zero
  benefit over parsing commits that already have to be conventional for
  other reasons.
