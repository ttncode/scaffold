# Walk through a first project

When: an engineer is new to the toolbox, or a change to it needs an end-to-end run. Follow the steps in order on a clean machine.

A step that does something other than its **Expect** is a finding, even when it still works. Record the step number, what was expected and what happened.

## Steps

1. **Prerequisites.** `git`, `mise`, `gh` with `gh auth login` done. Docker for step 10.

2. **Clone and install.**

   ```sh
   git clone https://github.com/ttncode/scaffold.git
   cd scaffold
   mise install
   export PATH="$PWD:$PATH"
   ```

   Expect: mise installs `bats`, `shellcheck`, `shfmt`, `yq`, `jq`, `zizmor`, `rush`, `lefthook` and `gitleaks` without a prompt. Put the clone on `PATH`; a symlink to `scaffold` does not work.

3. **Prove the toolbox runs.**

   ```sh
   scaffold list
   scaffold lint
   printf '' | scaffold; echo "exit $?"
   ```

   Expect: `list` prints one row per adapter and service: name, role or kind, tier (`-` for a service). `lint` prints nothing. With no terminal, `scaffold` prints usage and exits 1.

4. **Try the wizard.** In a real terminal:

   ```sh
   scaffold
   ```

   Type `demo-app`, then pick `web+api`, `nextjs`, `laravel-api`, `postgres`, `redis`. Typing a letter jumps to the first option starting with it; Enter takes it. Answer `n` at "Generate this project?".
   Expect: `scaffold new demo-app --web nextjs --api laravel-api --db postgres --cache redis` above the prompt, and nothing generated ([09-wizard](../tour/09-wizard.md)).

5. **Generate a project.** Outside the toolbox:

   ```sh
   cd ~/playground
   scaffold new demo-app --web nextjs --api laravel-api --db postgres --cache redis
   cd demo-app
   ```

   Expect: a warning naming the detected GitHub owner, several minutes of generators, then `created …/demo-app` and the next steps. Then:

   | Command | Expect |
   | --- | --- |
   | `git log --oneline` | One commit, `feat: scaffold project` |
   | `cat mise.toml` | `config_roots` with `apps/api`, `apps/web`, `docs`; `[vars]` `database = "postgres"`, `cache = "redis"`, `image` |
   | `cat .scaffold.toml` | The toolbox version and `"apps/web" = "nextjs"`, `"apps/api" = "laravel-api"` |
   | `ls .github/workflows` | `build.yml`, `ci.yml`, `docs.yml`, `release.yml`, `security.yml` |
   | `grep -l database compose*.yaml` | `compose.yaml`, `compose.dev.yaml`, `compose.test.yaml` |
   | `cat example.env` | `WEB_PORT=8080`, `API_PORT=8081`, `DB_PASSWORD`, `REDIS_PASSWORD` |
   | `cat apps/api/.env.example` | `DB_CONNECTION=pgsql` and `REDIS_*` |

6. **Run what CI runs.**

   ```sh
   mise install && mise exec -- lefthook install
   mise run //docs:ci-unit
   mise run //apps/web:ci-unit
   mise run //apps/api:ci-unit
   ```

   Expect: all pass. `lefthook` is pinned in the project, not on `PATH`, hence `mise exec`.

   Then repeat with local state moved aside: everything the app's `.gitignore` excludes that a task writes. A failure here fails CI too.

   | Adapter | Move aside |
   | --- | --- |
   | `laravel-api` | `apps/api/.env` |
   | `nextjs` | `apps/web/.next` |
   | `laravel-inertia` | `apps/app/.env`, `apps/app/resources/js/actions`, `apps/app/resources/js/routes`, `apps/app/public/build` |

7. **Commit through the hooks.**

   ```sh
   git checkout -b feat/health
   # add a /health route in apps/api/routes/web.php and a HealthTest beside the other feature tests
   mise run //apps/api:ci-unit
   git add -A && git commit -m "feat(api): add a health endpoint"
   git commit --allow-empty -m "added a health thing"
   ```

   Expect: `pre-commit` runs prettier, pint and gitleaks; `commit-msg` runs commitlint. The second commit is rejected.

8. **Publish and open a pull request.**

   ```sh
   git checkout main
   scaffold publish
   git checkout feat/health
   git push -u origin feat/health
   gh pr create --fill
   gh pr checks --watch
   ```

   Expect: `scaffold publish` creates the private repository, pushes `main` and applies the settings ([publish-a-project](publish-a-project.md)). The push runs `pre-push`, the whole `checklist`, so it takes minutes.

   Expect these checks: `changes`, `ci (apps/api)`, `commitlint`, `codeql`, `zizmor`, `gitleaks`, and the docs `build`. A root the commit did not touch gets no `ci (<root>)`. If `gh pr checks --watch` exits at once with `no checks reported`, run it again after a few seconds.

9. **Merge and release.**

   ```sh
   gh pr merge --squash --delete-branch
   gh run list --limit 5
   ```

   Expect: every workflow on `main` green, and a Release Please pull request. Merge it and follow [cut-a-release](cut-a-release.md).

10. **Run the release.** The repository is private, so `install.sh` needs a token with `repo` and `read:packages`, and `jq` on the host.

    ```sh
    GITHUB_TOKEN=<token> bash install.sh
    curl -fsS http://localhost:8080/api/health/live
    curl -fsS http://localhost:8081/health/ready
    docker compose -f app/compose.yaml down -v
    ```

    Expect: `install.sh` creates an `app` directory, downloads `compose.yaml` and `example.env` from the latest release, generates passwords, signs in to `ghcr.io`, starts the stack, runs `migrate`, then prints `web is running on http://localhost:8080` and `api is running on http://localhost:8081`. Both curls succeed. `nextjs` has no readiness route (ADR-0021).

    The owner and name must agree in three places; a repository renamed after generation breaks them:

    ```sh
    grep -n '^image' mise.toml
    grep -n 'ghcr.io' compose.yaml
    grep -n '^RepoUrl=' install.sh
    ```

11. **Add an application.**

    ```sh
    scaffold add apps/worker --adapter nestjs
    git status
    ```

    Expect: `apps/worker` staged. Unstaged edits to `mise.toml` (a config root), `ci.yml` (`roots:`), `build.yml` and `release.yml` (`images:`), `compose.yaml` (a `worker` service), `example.env` (`WORKER_PORT`), `.scaffold.toml` and `lefthook.yml`. `pnpm-workspace.yaml` changes only when it gains a new `allowBuilds` or `minimumReleaseAgeExclude` entry.

    Expect `apps/worker/.env.example` to name `DATABASE_URL` and `REDIS_URL`: `scaffold add` reads `[vars]` instead of asking (ADR-0019).

12. **Clean up.** Delete `~/playground/demo-app`, and the GitHub repository if it was a trial.

## Verify

- Every step matched its Expect, or each difference is recorded as a finding.

## What counts as a finding

- A step that needs a command this page does not give
- An error message that does not say what to do next
- A check that passes locally and fails in CI, or the reverse
- Anything that needed reading the source to get past
- A wait longer than the step said
