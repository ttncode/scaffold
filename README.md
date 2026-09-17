# scaffold

[![CI](https://github.com/ttncode/scaffold/actions/workflows/ci.yml/badge.svg)](https://github.com/ttncode/scaffold/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A bash toolbox that generates fully configured client projects. Every generated
application implements the same nine-task contract, so CI runs one command per
config root and never learns the language.

## Install

Needs `git` and [`mise`](https://mise.jdx.dev/getting-started.html); `mise install` supplies `jq`, `yq` and the rest.

```sh
git clone https://github.com/ttncode/scaffold.git
cd scaffold
mise install
./scaffold list
export PATH="$PWD:$PATH"   # optional: run `scaffold` from anywhere
```

`scaffold` loads its pinned `jq` and `yq` itself, and creates a relative target where you run it.
Call it by its path or through `PATH`; a symlink to it does not work.

## Usage

```sh
scaffold                    # in a terminal: an interactive wizard
scaffold new <name> [--web <adapter>] [--api <adapter>] [--app <adapter>]
                    [--db <service>] [--cache <service>]
scaffold add <dir> --adapter <adapter>
scaffold update [dir] [--dry-run]
scaffold publish [dir] [--public | --private] [--no-protect] [--dry-run]
scaffold list [--adapters] [--services]
scaffold lint
scaffold --version
```

What each command does, its defaults and its decision: [Commands](docs/README.md#commands).

## Adapter support tiers

Each adapter's tier is `ADAPTER_TIER` in its `adapter.env` ([ADR-0012](docs/decisions/0012-tiered-adapter-support.md)).

| Tier | Adapters | CI runs it | Guarantee |
| --- | --- | --- | --- |
| A | `nextjs`, `nestjs`, `laravel-api`, `flask` | every pull request, and nightly | stays green through every dependency bump |
| B | `laravel-inertia` | a pull request that changes `adapters/laravel-inertia/`, weekly, or on manual dispatch | verified regularly, not on every push |
| C | none currently | not automatically verified | none |

## Services

A database or cache is a directory under `services/`, not an adapter ([ADR-0019](docs/decisions/0019-services-are-not-adapters.md)).

| Slot | Services | Default |
| --- | --- | --- |
| `--db` | `mysql`, `postgres`, `mongodb`, `none` | `mysql` with `--api` or `--app`, otherwise `none` ([ADR-0020](docs/decisions/0020-database-default-is-derived-from-requested-adapters.md)) |
| `--cache` | `redis`, `none` | `none` |

No DynamoDB: `compose.yaml` ships with every release for a client to run ([ADR-0014](docs/decisions/0014-deployment-deferred-with-seams.md)), and the only DynamoDB that fits a compose file is an emulator with no production counterpart.

## Documentation

- [Start here](docs/README.md) — what the toolbox is, map, commands, glossary, [reading path](docs/README.md#reading-path)
- [Tour](docs/tour/) — how the pieces fit, nine pages
- [Decisions](docs/decisions/) — why they fit that way
- [Runbooks](docs/runbook/) — what to do when something specific happens
- [Provenance](docs/PROVENANCE.md) — what is copied from immich, and where it drifted
- [Contributing](CONTRIBUTING.md) — tasks, tests, adding an adapter or a service

## Licence

MIT — see [LICENSE](LICENSE). A generated project gets no licence file: its terms belong to the engagement it was generated for.
