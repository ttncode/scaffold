# scaffold

[![CI](https://github.com/ttncode/scaffold/actions/workflows/ci.yml/badge.svg)](https://github.com/ttncode/scaffold/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Generate a client project that is ready for its first pull request: a monorepo
of apps, an optional database and cache in Docker Compose, git hooks, CI,
releases and a docs site, all wired together and committed.

scaffold is a bash toolbox for engineers who start client projects often and
want every one of them built, checked and released the same way. It is
pre-1.0; versions are git tags.

## What a generated project gets

- **Apps** from the adapters you pick: `--web`, `--api` or `--app`, each in its own directory with its own `mise.toml`.
- **One task contract.** Every app answers the same nine `mise` tasks (`install`, `format`, `lint`, `test`, `build`, `checklist`, …), so CI runs one command per app and never learns the language.
- **CI** as five thin workflows that call shared reusable workflows at `@v1` ([ADR-0005](docs/decisions/0005-share-ci-through-reusable-workflows.md)).
- **Guardrails:** lefthook runs prettier, gitleaks and commitlint locally; Renovate opens dependency bumps.
- **Releases:** Release Please from Conventional Commits, container images, and an `install.sh` that runs the released stack with Docker Compose.
- **A VitePress docs site** checked in CI like any app.
- **`.scaffold.toml`**, recording the toolbox commit that generated it, so `scaffold update` can bring later toolbox changes in.

## Requirements

| Needed for | Requirement |
| --- | --- |
| Everything | `git` and [`mise`](https://mise.jdx.dev/getting-started.html); `mise install` supplies `jq`, `yq` and the rest |
| `laravel-api`, `laravel-inertia` | PHP 8.3 or later on the host; mise cannot pin it ([ADR-0016](docs/decisions/0016-php-is-not-pinned-through-mise.md)) |
| `scaffold new` | A GitHub owner for the project: `SCAFFOLD_GITHUB_OWNER`, else the signed-in `gh` user, else `git config github.user` |
| `scaffold publish` | [`gh`](https://cli.github.com/), signed in with `gh auth login` |
| CI in a generated project | A `.github` repository under the project's GitHub owner holding the reusable workflows ([ADR-0005](docs/decisions/0005-share-ci-through-reusable-workflows.md)) |
| Running a release | Docker |

## Quick start

```sh
git clone https://github.com/ttncode/scaffold.git
cd scaffold
mise install
export PATH="$PWD:$PATH"
scaffold list
```

`scaffold list` prints one row per adapter and service. `scaffold` loads its pinned `jq` and `yq` itself. Call `scaffold` by its path or through `PATH`; a symlink to it does not work.

Generate a project outside the toolbox. `scaffold new` creates it where you run it:

```sh
cd ~/playground
scaffold new demo-app --web nextjs --api nestjs --db postgres
```

The framework generators take several minutes. The result is a directory with one commit, `feat: scaffold project`.

Run `scaffold` with no arguments in a terminal for a wizard that builds the same command. The full end-to-end run, from generation to a running release, is [Walk through a first project](docs/runbook/first-project-walkthrough.md).

## Commands

| Command | Does |
| --- | --- |
| `scaffold new <name>` | Generates and commits a project |
| `scaffold add <dir> --adapter <adapter>` | Adds an app to an existing project and stages it |
| `scaffold update [dir]` | Applies toolbox changes since the project was generated; never commits |
| `scaffold publish [dir]` | Creates the GitHub repository (private by default) and protects `main` |
| `scaffold list` | Prints adapters with role and tier, services with kind |
| `scaffold lint` | Checks every adapter and service against the contract |

Flags, defaults, environment variables and the decision behind each command: [Commands](docs/README.md#commands).

## Adapters

Each adapter's tier is `ADAPTER_TIER` in its `adapter.env` ([ADR-0012](docs/decisions/0012-tiered-adapter-support.md)).

| Adapter | Role | Tier |
| --- | --- | --- |
| `nextjs` | web | A |
| `nestjs` | api | A |
| `laravel-api` | api | A |
| `flask` | api | A |
| `laravel-inertia` | app | B |

| Tier | CI runs it | Guarantee |
| --- | --- | --- |
| A | every pull request, and nightly | stays green through every dependency bump |
| B | a pull request that changes `adapters/laravel-inertia/`, weekly, or on manual dispatch | verified regularly, not on every push |
| C | not automatically verified | none; no adapter is tier C today |

## Services

A database or cache is a directory under `services/`, not an adapter ([ADR-0019](docs/decisions/0019-services-are-not-adapters.md)).

| Flag | Services | Default |
| --- | --- | --- |
| `--db` | `mysql`, `postgres`, `mongodb`, `none` | `mysql` with `--api` or `--app`, otherwise `none` ([ADR-0020](docs/decisions/0020-database-default-is-derived-from-requested-adapters.md)) |
| `--cache` | `redis`, `none` | `none` |

There is no DynamoDB: every release ships a `compose.yaml` for the client to run ([ADR-0014](docs/decisions/0014-deployment-deferred-with-seams.md)), and the only DynamoDB that fits a compose file is an emulator with no production counterpart.

## Documentation

- [Start here](docs/README.md): repository map, commands, glossary and a [reading path](docs/README.md#reading-path)
- [Tour](docs/tour/): how the pieces fit, in nine pages
- [Decisions](docs/decisions/): why they fit that way
- [Runbooks](docs/runbook/): what to do when something specific happens
- [Provenance](docs/PROVENANCE.md): what is copied from [immich](https://github.com/immich-app/immich), and where it drifted

## Contributing and security

Setup, test lanes and how to add an adapter or a service: [CONTRIBUTING.md](CONTRIBUTING.md). Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## License

MIT, see [LICENSE](LICENSE). A generated project gets no license file: its terms belong to the engagement it was generated for.
