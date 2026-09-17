# Publish a project

When: a project from `scaffold new` has no GitHub repository yet, or its repository is missing settings.

`scaffold publish` creates the repository the project already names and applies the settings no file records (ADR-0024). It is idempotent: against an existing repository it applies only the settings.

## Steps

1. Sign in to GitHub.

   ```bash
   gh auth login
   ```

2. Optional: export the release app secrets, so Release Please opens its pull request as the app.

   ```bash
   export RELEASE_APP_ID=<app id>
   export RELEASE_APP_PRIVATE_KEY="$(cat <app>.private-key.pem)"
   ```

3. From a clean `main` in the project, preview.

   ```bash
   git checkout main
   scaffold publish --dry-run
   ```

4. Publish.

   ```bash
   scaffold publish              # private, main protected
   ```

   | Flag | Effect |
   | --- | --- |
   | `--private` | Default visibility |
   | `--public` | Public repository |
   | `--no-protect` | Skip the `main` ruleset |
   | `--dry-run` | Print the plan; change nothing |
   | `[dir]` | The project directory; default is the git root of the current directory |

## What it does

| Step | Function in `lib/publish.sh` | Skipped when |
| --- | --- | --- |
| Create `<owner>/<project>` and push `main` | `create_repo` | The repository exists |
| Allow Actions to open pull requests | `allow_actions_to_open_pull_requests` | Never |
| Secret scanning and push protection | `enable_secret_scanning` | The plan lacks it: warning |
| Ruleset `main`: pull request required, no force-push, no deletion | `protect_main` | `--no-protect`, a ruleset named `main` exists, or the plan lacks it: warning |
| Set `RELEASE_APP_ID` and `RELEASE_APP_PRIVATE_KEY` | `set_release_secrets` | Either variable is unset: warning |

`<owner>/<project>` is read from `[vars] image` in the project's `mise.toml` (`repo_slug`). There is no flag to change it.

## Verify

```bash
gh repo view <owner>/<project>
gh api repos/<owner>/<project>/rulesets --jq '.[].name'      # main
scaffold publish --dry-run                                     # "would leave … alone"
```

## If it fails

| Symptom | Fix |
| --- | --- |
| `publish needs the GitHub CLI` or `not signed in to GitHub` | Install `gh`, run `gh auth login` |
| `check out main first` | `git checkout main`; `gh repo create --push` makes the current branch the default |
| `has uncommitted changes` | Commit, then run again |
| `already pushes to <url>, but it names <owner>/<project>` | Point `[vars] image`, `compose.yaml`, `install.sh` and the build workflows at the existing repository, or `git remote remove origin` |
| `could not finish creating` | The repository may exist half-made. Check it on GitHub, then run again |
| Warning `main is unprotected` | A free account's private repository cannot use rulesets. Make it public or upgrade, then run again |
| Warning `no secret scanning` | A private repository needs Advanced Security. The CI gitleaks scan still runs |
| Warning `no RELEASE_APP_ID/RELEASE_APP_PRIVATE_KEY` | Checks on the release pull request sit at `Action required`, then expire red. Merging it still releases. To fix, export both and run again |
