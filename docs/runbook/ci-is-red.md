# CI is red

When: a check is red on a generated project or on this toolbox.

## Steps

1. Read the failing job's name and find it in the tables below.
2. Reproduce with the command in the table, on a clean clone.
3. Fix the cause in the file the task names: the app's `mise.toml`, the source file, the test. Do not edit the workflow to hide what the task caught.
4. Before calling it done, ask what else reaches the code you changed. A fix checked only against the one repro that prompted it has missed adjacent paths four times in this project's history.

### A generated project

`ci (<root>)` runs `mise run //<root>:ci-unit` in each config root the change touched; `ci-unit` runs `install`, `format`, `lint`, `check` and `test` in that order (ADR-0011).

| Job, or `ci-unit` step | Usually means | Reproduce |
| --- | --- | --- |
| `install` | Lockfile out of sync, or a supply-chain guard: a too-fresh dependency, an unapproved native build (ADR-0017) | `mise run //<root>:install` |
| `format` | Unformatted code was committed | `mise run //<root>:format-fix`, then commit the diff |
| `lint` | A real lint violation, or the lint config changed | `mise run //<root>:lint` |
| `check` | A type error, or `phpstan` on Laravel | `mise run //<root>:check`; it never writes, so it repeats what CI saw |
| `test` | A failing test, or a test that needs a file a fresh checkout lacks | Move aside what `.gitignore` excludes, then `mise run //<root>:test` |
| `changes` | The path filter failed; it runs only on a pull request | The job log |
| `commitlint` | A commit in the pull request is not a Conventional Commit; runs only on a pull request | Reword the commit |
| `codeql`, `zizmor`, `gitleaks` | A security finding; `gitleaks` runs `mise run secrets` | `mise run secrets` for gitleaks; the job log for the others |
| `build` (Build workflow), `image` (Release workflow) | The Docker image does not build | `docker build -f <dockerfile> <context>`, with the `context` and `dockerfile` from `images:` in the project's `build.yml` |

`build` is not part of `ci-unit`. Locally it runs inside `checklist`, which `pre-push` runs.

### This toolbox

| Job | Usually means | Reproduce |
| --- | --- | --- |
| `unit` | `lint` or `test-unit` failed | `mise run ci-unit` |
| `unit`, 5-minute timeout, or `tests/contract.bats` fails with "<file> runs an adapter generator to completion" | A `test-unit` suite runs an adapter generator | Move that suite to `test-integration` in `mise.toml` |
| `integration` | A suite that generates a real project failed | `mise run test-runner`, which sets `CI` as a runner does |
| `zizmor` | A workflow finding; the common one is untrusted input interpolated into `run:` | `mise exec -- zizmor .github/workflows/`; pass the value through `env:` as `.github/workflows/adapters.yml` does |
| `pull-request-body` | The pull request body lost a `##` heading of `.github/pull_request_template.md` | Restore the template's headings |
| `self-test` (Provenance) | `scripts/check-provenance.sh` itself regressed | `bats tests/provenance.bats` |
| `check` (Provenance) | A `verbatim` file no longer matches the commit pinned in `UPSTREAM` | `docs/runbook/sync-with-upstream-immich.md` |
| `smoke`, `smoke-tier-b`, `deploy`, `deploy-tier-b`, `deploy-multi-app` (Adapters) | An adapter's generator or image broke | `bats tests/new-<adapter>.bats`, or `./scripts/deploy-check.sh <adapter>` |
| `compose` (Adapters) | A compose file, Dockerfile or `install.sh` invariant broke | `bats tests/compose.bats` |
| `services` (Adapters) | One adapter, database and cache combination does not generate or pass its checklist | `./scaffold new ../demo --api <adapter> --db <db> --cache <cache>`, then `mise run //apps/api:checklist` in it |

## Verify

- The failing job is green on a re-run of the fixed commit.
- The fix is in a task, a source file or a test, not in a workflow that skips the failing step.
