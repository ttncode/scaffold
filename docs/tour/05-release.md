# 05 — Release

## What it does

Every commit in a generated project must be a Conventional Commit — enforced
locally by commitlint and again by parsing history, because a local hook can
be bypassed. Release Please reads that history and maintains a standing
release pull request; merging it cuts a version, a changelog entry, and a
GitHub Release. Publishing an image is deliberately a separate concern from
cutting a release, so an ordinary bug-fix merge never has to wait behind
someone else's decision to bump a version.

## Read this

- `common/release-please-config.json` and `common/.release-please-manifest.json`
  — Release Please's own config and the version it currently believes it is
  at.
- `common/.github/workflows/build.yml` — runs on every push to `main`,
  publishes `main` and `sha-<commit>` image tags, no dependency on Release
  Please at all.
- `common/.github/workflows/release.yml` — runs on every push to `main`
  too, but its image and asset jobs only fire on the merge that actually
  closes a release PR, publishing `<version>` (e.g. `1.4.0` and `1.4`) and
  `latest`.
- ADR-0006 for Release Please over changesets, ADR-0015 for why build and
  release are two separate workflows rather than two jobs in one.

## Delete test

Delete `common/.release-please-manifest.json` and the next release run
doesn't fail — Release Please just loses track of what version it already
issued and may propose a version lower than what's already tagged, which
only surfaces the first time someone tries to cut a release after the
file's been gone for a while, as a confusing diff in the release PR rather
than an error. Delete `common/.github/workflows/build.yml` instead and the
break is immediate: no image tag ever gets published for an ordinary merge
again, and a client running `IMAGE_TAG=main` stops getting updates the very
next push.

## Try it

```bash
node -e "console.log(require('./common/.release-please-manifest.json'))"
```
