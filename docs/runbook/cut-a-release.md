# Cut a release

This applies to a generated project (Release Please, `common/release-please-config.json`),
not to this toolbox itself, which has no release process of its own.

## 0. Once per repository: let Actions open pull requests

Release Please works by opening a pull request, and a new repository
forbids that by default — the run fails with `GitHub Actions is not
permitted to create or approve pull requests` after it has already
pushed its branch, so the symptom appears late and looks like a
permissions bug in the workflow. It is a repository setting:

```bash
gh api -X PUT "repos/<owner>/<repo>/actions/permissions/workflow" \
  -f default_workflow_permissions=read \
  -F can_approve_pull_request_reviews=true
```

Or Settings → Actions → General → Workflow permissions → *Allow GitHub
Actions to create and approve pull requests*.

## 1. Merge conventional commits to `main`

Every commit must already be a Conventional Commit — enforced at
`commit-msg` by lefthook and commitlint, and again in CI. `feat:` and
`fix:` commits are what move the version; `chore:`/`docs:` do not.

## 2. Let Release Please open (or update) its release PR

`common/.github/workflows/release.yml` runs on every push to `main` and
maintains one standing pull request with the next version's changelog,
computed from the commits merged since the last release.

## 3. Review the release PR

Check the generated changelog against what actually shipped. This is the
only manual step in the whole flow.

## 4. Merge it

Merging the release PR is the release. `release.yml`'s image and asset
jobs only run `if: needs.release-please.outputs.released == 'true'` —
i.e. only on this specific merge — and publish the version tags
(`1.4.0` and `1.4`, for example) plus `latest`.

## 5. Confirm the image published

Check the workflow run for `release.yml` succeeded, then confirm the new
tag exists in the registry a client's `compose.yaml` points at.

## Done when

The GitHub Release exists, the semver and `latest` image tags are
published, and a client pinning `IMAGE_TAG` to the new version (or to
`latest`) can pull it.
