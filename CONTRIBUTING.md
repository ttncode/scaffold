# Contributing

## Setup

1. `mise install` — every tool this repository uses, pinned in `mise.toml`.
2. `mise exec -- lefthook install` — the git hooks (`lefthook` is pinned, not on `PATH`).
3. `mise run lint`
4. `mise run test-unit`

| Hook | Runs |
| --- | --- |
| `pre-commit` | `mise run lint`, gitleaks on staged changes |
| `commit-msg` | Conventional Commit check (a grep; this repository has no node) |
| `pre-push` | nothing: CI runs the suites on every push |

## Tasks

| Task | Runs |
| --- | --- |
| `lint` | shellcheck + shfmt (`-i 2 -ci`) over every tracked shell file |
| `test-unit` | The offline suites, listed by name in `mise.toml` |
| `test-integration` | The suites that generate a real project as a fixture |
| `test` | Every suite in `tests/`, including the per-adapter smoke tests |
| `test-runner` | `test-unit` and `test-integration` with `CI`, `GITHUB_ACTIONS` and `MISE_YES` set, as on a runner |
| `ci-unit` | `lint` + `test-unit`: the `unit` job in `.github/workflows/ci.yml` |
| `checklist` | `lint` + `test` |

`test-runner` matters: with `CI` set, pnpm uses `--frozen-lockfile`, so a suite can pass locally and fail on a runner.

## Test lanes

| Suite | Lane | Where CI runs it |
| --- | --- | --- |
| Listed in `test-unit` | unit | `.github/workflows/ci.yml`, `unit` job |
| Listed in `test-integration` | integration | `.github/workflows/ci.yml`, `integration` job |
| `tests/new-<adapter>.bats` | smoke, per adapter tier | `.github/workflows/adapters.yml` |
| `tests/provenance.bats` | provenance | `.github/workflows/provenance.yml` |

`tests/contract.bats` fails when a suite is in no lane, or when a `test-unit` suite runs an adapter generator.

## Writing a test

- Assert with `assert_ok` (`tests/helpers/setup.bash`), not `[ "$status" -eq 0 ]`: it prints the captured output on failure.
- Each test builds its own fixtures; no suite uses `setup_file`. Suites run in parallel with `--jobs`.
- When the environment cannot hold a precondition, `skip` with the reason instead of failing.

## Adding an adapter

Follow [docs/runbook/add-an-adapter.md](docs/runbook/add-an-adapter.md). The wizard needs no change: it reads `scaffold list`.

## Adding a service

A service is a directory under `services/` ([ADR-0019](docs/decisions/0019-services-are-not-adapters.md)).

1. Add `service.env` with `SERVICE_NAME`, `SERVICE_KIND` and a digest-pinned `SERVICE_IMAGE`.
2. Add `compose.fragment.yaml` and the per-lane `compose.prod.fragment.yaml`, `compose.dev.fragment.yaml`, `compose.test.fragment.yaml`, none with an `image:` line.
3. Add `env.fragment`.
4. Add `drivers/<family>.sh` for every family of an `api` or `app` adapter — today `laravel`, `nest`, `flask`.
5. Run `./scaffold lint`: it derives the families from the adapters and names any missing driver.

A new adapter family is the same check from the other side: every service needs its driver before it merges.

## What a change reaches

| Change | Reaches an existing project |
| --- | --- |
| `common/` or an adapter | When someone runs `scaffold update` in it ([ADR-0023](docs/decisions/0023-a-project-records-what-generated-it.md)) |
| A reusable workflow in *you/.github* | On its next run, once `v1` moves (ADR-0005) |

## Commits and versions

- Conventional Commits, checked at `commit-msg`.
- The toolbox is versioned by git tag only. `scaffold --version` is `git describe`, and `.scaffold.toml` records it.
- Tagging is manual: `git tag v0.2.0 && git push origin v0.2.0`.

## Before opening a pull request

```sh
mise run lint
mise run test-runner
```

`mise run test` adds the per-adapter smoke tests; tier B's five tests take about five minutes each.
