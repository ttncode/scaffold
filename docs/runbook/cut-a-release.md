# Cut a release

When: a generated project should ship a version. This toolbox has no release process; its tags are manual (`CONTRIBUTING.md`).

![Release flow](../diagrams/release-flow.svg)

## Steps

1. Once per repository, run `scaffold publish`. It allows Actions to open pull requests, which Release Please needs, and sets the release app secrets when they are in the environment ([publish-a-project](publish-a-project.md)).

2. Merge Conventional Commits to `main`. `feat:` and `fix:` move the version; `docs:` and `chore:` do not (`common/release-please-config.json`).

3. Wait for Release Please. `release.yml` runs on every push to `main` and keeps one pull request, `chore(main): release <version>`, with the changelog.

   ```bash
   gh pr list --search "release in:title"
   ```

4. Review the changelog against what shipped, then merge the pull request.

   ```bash
   gh pr merge <number> --squash
   ```

   Merging it is the release. Only on that merge, `app-release.yml`'s jobs:

   | Job | Publishes |
   | --- | --- |
   | `image` | Every application's image, tagged `<version>`, `<major>.<minor>`, `latest`, `sha-<commit>` |
   | `assets` | `compose.yaml`, `example.env`, `install.sh` on the GitHub Release |
   | `deploy` | Nothing: it runs only when `vars.DEPLOY_TARGET` is set, and then fails, since no deploy adapter exists (ADR-0014) |

## Verify

```bash
gh release list --limit 1
gh release view <tag> --json assets --jq '.assets[].name'
gh run list --workflow release.yml --limit 1
```

- The release lists `compose.yaml`, `example.env` and `install.sh`.
- `ghcr.io/<owner>/<project>-<app>:<version>` exists for every application.
- A host that runs `install.sh` pulls the new version ([first-project-walkthrough](first-project-walkthrough.md)).

## If it fails

| Symptom | Fix |
| --- | --- |
| `GitHub Actions is not permitted to create or approve pull requests` | Run `scaffold publish` in the project |
| Checks on the release pull request sit at `Action required` | No `RELEASE_APP_ID`/`RELEASE_APP_PRIVATE_KEY`. Merge anyway, or set them with `scaffold publish` |
| No release pull request after a merge | The merged commits are only `docs:` or `chore:` |
| `image` skipped | `images:` in the project's `release.yml` is `"[]"`. Copy the entries from `build.yml`, which `scaffold new` and `scaffold add` write to both |
