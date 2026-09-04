# Walk through a first project

A scripted run of everything a new engineer does between cloning this toolbox
and shipping a release from a project it generated. Follow it in order on a
machine that has never run the toolbox, and record where it goes wrong — the
purpose is to find the rough steps, not to prove they are smooth.

Each step states what to expect. A step that does something other than what is
written here is a finding, even when it still works.

## 0. Prerequisites

`git` and `mise` installed. A GitHub account, and `gh auth login` completed.
Docker only matters for step 10.

## 1. Clone and install

```sh
git clone https://github.com/ttncode/scaffold.git
cd scaffold
mise install
```

Expect: mise installs jq, yq, bats, shellcheck, zizmor and rush, and prints no
prompt. A prompt about trusting the config means step 1 is a finding — the
README does not mention one.

## 2. Prove the toolbox runs

```sh
mise exec -- ./scaffold list
mise exec -- ./scaffold lint
```

Expect: `list` prints eight rows now, not four — every adapter and every
service, as name, second column, tier. The second column is the adapter's
role (`api`, `app`, `web`) or the service's kind (`database`, `cache`); a
service carries no tier, so its third column reads `-` — tiers (ADR-0012)
measure verification cost for adapters, and a service's own manifest names
no such thing (ADR-0019). `list --adapters` or `list --services` narrows to
one half. `lint` still prints nothing and exits 0. Anything else stops the
walkthrough here.

## 3. Try the wizard

```sh
mise exec -- ./scaffold
```

Run this in an actual terminal. Expect an interactive wizard: a name prompt,
then shape (`web+api`, `app`, `api`, `web`), then one to four more screens
depending on the shape. Type `demo-app` at the name prompt; at each menu
after that, typing a letter jumps the highlight to the first option that
starts with it — arrows work too, and either way Enter takes the highlighted
option. Reach `web+api`, `nextjs`, `laravel-api`, `postgres`, `redis` that
way, then `n` at "Generate this project?" to stop at the summary without
generating anything. Expect the line above the prompt to read:

```
scaffold new demo-app --web nextjs --api laravel-api --db postgres --cache redis
```

That is the command step 5 runs, argument order aside — reaching it by menu
first is how a first-time user is meant to find it. See
docs/tour/09-wizard.md for the question logic and its known limits.

Piped, redirected, or run from a script — a closed stdin, not a terminal —
`scaffold` with no arguments takes none of this and prints usage and exits 1,
same as before:

```sh
printf '' | mise exec -- ./scaffold
```

## 4. Make it callable from anywhere

Add the shell function from the README's Install section to your shell profile,
open a new shell, then from a directory that is **not** the toolbox:

```sh
cd ~/some/other/directory
scaffold list
```

Expect: the same output as step 2. If it reports a missing tool, the function
is not supplying mise's environment. If a later `scaffold new relative-name`
lands inside the toolbox, the function used `mise exec -C` instead of
`mise env -C`.

## 5. Generate a project

```sh
cd ~/playground
scaffold new demo-app --api laravel-api --web nextjs --db postgres --cache redis
```

Expect: two generators run, then `created …/demo-app`. Expect a warning naming
the GitHub account it detected. Expect it to take several minutes.

Then read what it made before doing anything else:

```sh
cd demo-app
git log --oneline           # one commit, "chore: scaffold project"
cat mise.toml               # config_roots: apps/web, apps/api, docs
                             # [vars] database = "postgres", cache = "redis"
ls .github/workflows        # five call sites
grep -l database compose*.yaml    # all three: compose.yaml, .dev.yaml, .test.yaml
cat example.env             # DB_PASSWORD and REDIS_PASSWORD, appended for the services chosen
cat apps/api/.env.example   # DB_CONNECTION=pgsql and REDIS_* — the driver's own variables
```

## 6. Run what CI will run, before pushing

```sh
mise run //docs:ci-unit
mise run //apps/web:ci-unit
mise run //apps/api:ci-unit
```

Expect: all three pass. This is the same command CI issues per config root.

Now check the harder thing — that they pass on a machine that has none of your
local state:

```sh
mv apps/api/.env /tmp/env-aside
mv apps/web/.next /tmp/next-aside 2>/dev/null
mise run //apps/api:ci-unit && mise run //apps/web:ci-unit
mv /tmp/env-aside apps/api/.env
```

Expect: still pass. A failure here is a real finding — it means a check depends
on a file that is not committed, and CI will fail where you succeeded.

A `nestjs` app's `check` and `build` also depend on a `prisma` task now
(`prisma generate` first, when the project has a database). Moving its `.env`
aside the same way still passes — `prisma generate` only parses the schema,
it does not need `DATABASE_URL` to resolve. Nothing here uses `nestjs` yet;
this matters again once step 11 adds one.

## 7. Install the hooks and make a commit

```sh
lefthook install
git checkout -b feat/health
```

Add a small feature with a test — for `laravel-api`, a `/health` route in
`apps/api/routes/web.php` and a `HealthTest` beside the other feature tests.

```sh
mise run //apps/api:ci-unit
git add -A
git commit -m "feat(api): add a health endpoint"
```

Expect: pre-commit runs pint and gitleaks; commit-msg runs commitlint. Then
prove the gate works:

```sh
git commit --allow-empty -m "added a health thing"
```

Expect: rejected, naming the convention.

## 8. Push and open a pull request

```sh
gh repo create ttncode/demo-app --private --source=. --remote=origin --push
gh api -X PUT repos/ttncode/demo-app/actions/permissions/workflow \
  -f default_workflow_permissions=read \
  -F can_approve_pull_request_reviews=true
git push -u origin feat/health
gh pr create --fill
gh pr checks --watch
```

Expect: `CI / ci / ci (apps/api)` runs, because `apps/api` changed. Expect
`CI / ci / changes` to skip roots that did not. Expect `commitlint` to run —
it only ever runs on a pull request.

The `gh api` call is required, not optional: without it Release Please cannot
open its pull request later, and the failure appears several steps away from
this one.

## 9. Merge, and let the release happen

```sh
gh pr merge --squash --delete-branch
gh run list --limit 5
```

Expect: five workflows on `main`, all green. Expect Release Please to open
`chore(main): release 0.2.0` — `feat:` moves the minor version.

If that pull request's checks sit at `Action required`, the repository has no
`RELEASE_APP_ID`/`RELEASE_APP_PRIVATE_KEY`; a pull request opened with
`GITHUB_TOKEN` starts no workflow. Merging it directly still releases.

```sh
gh pr merge <number> --squash
gh release list
```

Expect: `v0.2.0`, and the image tagged `0.2.0`, `0.2`, `latest`, `sha-…`.

## 10. Run what was built

```sh
docker pull ghcr.io/ttncode/demo-app:0.2.0
```

Expect: pulls, if the package is public or you are logged in to ghcr.

## 11. Add a second application to the existing project

```sh
cd ~/playground/demo-app
scaffold add apps/worker --adapter nestjs
git status
```

Expect: `apps/worker` exists, `mise.toml` gained a config root, `ci.yml`'s
`roots:` gained an entry, and `lefthook.yml`, `pnpm-workspace.yaml` and
`pnpm-lock.yaml` also changed — the new app's own hooks, `allowBuilds` and
`minimumReleaseAgeExclude` entries, and dependencies. Expect the changes to
be left uncommitted for review.

The new application is wired to the database and cache this project already
recorded, not asked again: `apps/worker/.env.example` names a `DATABASE_URL`
and `REDIS_URL` for the same services `mise.toml`'s `[vars]` already records,
not whatever nestjs would default to on its own. `scaffold` cannot change a
project's database after generation (ADR-0019) — reading it back on `add` is
how a later application still ends up on the one already running.

## What counts as a finding

- A step that needs a command this page does not give
- An error message that does not say what to do next
- A check that passes locally and fails in CI, or the reverse
- Anything that required reading the source to get past
- Any wait longer than the step led you to expect

Record each one with the step number, what was expected, and what happened.
