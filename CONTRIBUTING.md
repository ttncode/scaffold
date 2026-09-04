# Contributing

## Setup

```sh
mise install            # every tool this repository uses, pinned in mise.toml
mise run lint           # shellcheck over scaffold, lib/, scripts/, common/
mise run test-unit      # the offline suites
```

Run `scaffold` through `mise exec -- ./scaffold …` from a clone; see the
README's Install section for a shell function that works from anywhere.

## Tasks

| Task | What it runs |
| --- | --- |
| `lint` | shellcheck over every shell file the repository tracks |
| `test-unit` | the suites that never invoke an adapter's generator — offline and quick |
| `test-integration` | the suites that generate a real project as a fixture |
| `test` | every suite, including the per-adapter smoke tests |
| `test-runner` | `test-unit` and `test-integration` under the environment a GitHub runner has |
| `ci-unit` | `lint` + `test-unit` — what CI runs on a pull request |
| `checklist` | `lint` + `test` — the pre-push gate |

`mise run test-runner` matters more than its name suggests. `pnpm` turns on
`--frozen-lockfile` when `CI` is set, and `mise` trusts every config it finds
for the same reason; a suite that passes without those variables says nothing
about the runner. Several failures have only ever appeared there.

## Writing a test

Assert with `assert_ok` rather than `[ "$status" -eq 0 ]`. bats captures the
command's output into `$output` and prints none of it, so a bare status check
reports the line that failed and nothing about why — every diagnosis in this
repository has started by adding that output back by hand.

Each test generates its own project. That is slow, and deliberately so: a
shared fixture makes one test's mess into the next test's failure, and a suite
whose result depends on execution order cannot say what broke. The suites run
with `--jobs` instead, which overlaps independent work without sharing any.

When a test cannot hold its own precondition — `mise` pre-trusts every config
on a runner, `gh` has no credentials there — `skip` with the reason rather than
failing. A red that is about the environment teaches nothing.

## Adding an adapter

See [docs/runbook/add-an-adapter.md](docs/runbook/add-an-adapter.md). In short:
an adapter invokes a framework's own generator and overlays its own files on
the result. It must ship `adapter.env`, `mise.toml`, `Dockerfile` and
`.env.example`, implement all nine contract tasks, and pass `scaffold lint`.

`format`, `lint` and `check` must report without repairing. The linter enforces
this by rejecting a writing flag in their `run` — see
[ADR-0011](docs/decisions/0011-task-contract-names-follow-immich.md).

Nothing needs doing for the wizard: it builds its questions from `scaffold
list`, so a new adapter appears there as soon as `scaffold lint` passes —
see [09-wizard](docs/tour/09-wizard.md).

## Adding a service

A service is a directory under `services/`, not an adapter — see
[ADR-0019](docs/decisions/0019-services-are-not-adapters.md). It must ship
six files: `service.env` (`SERVICE_NAME`, `SERVICE_KIND`, a digest-pinned
`SERVICE_IMAGE`), a shared `compose.fragment.yaml`, a `compose.prod.fragment.yaml`
/ `compose.dev.fragment.yaml` / `compose.test.fragment.yaml` delta per lane,
and an `env.fragment`. None of the compose fragments may carry their own
`image:` line — `assemble_compose` writes the digest in from `service.env`.

It must also ship a driver, `drivers/<family>.sh`, for every adapter family
whose role is `api` or `app` — `laravel` and `nest` today; `next` takes none,
because `nextjs`'s role is `web` and the presentation tier opens no
connection. `scaffold lint` derives that family list from the adapters
themselves and fails a service that is missing any one of them, by name. A
new adapter family is the same problem from the other direction: it cannot
merge until every existing service has a `drivers/<that-family>.sh`, which is
why the lint requires the full matrix rather than checking each service in
isolation.

## Commits

Conventional Commits, enforced by lefthook at `commit-msg`. `feat:` and `fix:`
move the version of a generated project; `chore:` and `docs:` do not.

## Before opening a pull request

```sh
mise run lint
mise run test-runner
```

`mise run test` additionally covers the per-adapter smoke tests, including the
tier B adapter, which takes about 25 minutes.
