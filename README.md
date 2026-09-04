# scaffold

[![CI](https://github.com/ttncode/scaffold/actions/workflows/ci.yml/badge.svg)](https://github.com/ttncode/scaffold/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A bash toolbox that generates fully configured client projects. Every generated
application implements the same nine-task contract — `install`, `format`,
`format-fix`, `lint`, `check`, `test`, `build`, `ci-unit`, `checklist` — so CI
runs one command per config root and never learns the language.

## Install

The toolbox needs `git`, `mise`, `jq` and `yq`. `mise` supplies the last two,
so install it first ([instructions](https://mise.jdx.dev/getting-started.html)),
then:

```sh
git clone https://github.com/ttncode/scaffold.git
cd scaffold
mise install            # jq, yq, bats, shellcheck, zizmor, rush — pinned in mise.toml
mise exec -- ./scaffold list
```

`scaffold` refuses to run without those tools and names the missing one, so
`mise exec --` is the reliable way to invoke it from a clone.

To run it from anywhere, add a shell function rather than putting it on `PATH`:
it needs its own pinned tools, but must still resolve a relative target against
wherever you are standing.

```sh
scaffold() {
  ( eval "$(mise env -C "$HOME/path/to/scaffold" -s zsh)"
    "$HOME/path/to/scaffold/scaffold" "$@" )
}
```

`mise env -C` prints the environment without changing directory. `mise exec -C`
would change it as well, and a relative target would then be created inside the
toolbox instead of where the command was run.

## Usage

```sh
scaffold                    # in a terminal: an interactive wizard
scaffold new <name> [--web <adapter>] [--api <adapter>] [--app <adapter>]
                    [--db <service>] [--cache <service>]
scaffold add <dir> --adapter <adapter>
scaffold list
scaffold lint
```

Run with no arguments in a terminal, `scaffold` walks you to a complete
`new` command instead of printing usage — see
[09-wizard](docs/tour/09-wizard.md). Anywhere else — a script, CI, no
terminal attached — it keeps exactly the behaviour below.

`new` creates a project. `add` installs another application into one that
already exists. `list` reports the adapters and their tiers. `lint` checks
every adapter and every service against the contract.

`--db` and `--cache` select a database and a cache; each defaults to `none`
except `--db`, which defaults to `mysql` for a project with an `--api` or
`--app` adapter. Requesting either on a project with neither is refused —
the `web` tier has no driver, so nothing in the project could reach it. See
[ADR-0020](docs/decisions/0020-database-default-is-derived-from-requested-adapters.md).

The generated workflows call this account's reusable CI (`dot-github`) and
publish to its `ghcr.io` namespace. `scaffold new` resolves the account from
`SCAFFOLD_GITHUB_OWNER`, then `gh api user`, then `git config github.user`,
and refuses to generate if none of the three resolves.

## Adapter support tiers

"Supported" and "guaranteed" are different words. Tier membership is read
from each adapter's own `ADAPTER_TIER` (`adapters/*/adapter.env`) — see
[ADR-0012](docs/decisions/0012-tiered-adapter-support.md).

| Tier | Adapters | CI runs it | Guarantee |
| --- | --- | --- | --- |
| A | `nextjs`, `nestjs`, `laravel-api` | every pull request, and nightly | stays green through every dependency bump |
| B | `laravel-inertia` | when `adapters/laravel-inertia/**` changes, and weekly | verified regularly, not on every push — a full generation measures ~5 minutes per test |
| C | none currently | not automatically verified | may rot; no guarantee at all |

## Services

A database or cache is a directory under `services/`, not an adapter — see
[ADR-0019](docs/decisions/0019-services-are-not-adapters.md). Each ships a
driver per adapter family (`laravel`, `nest`, `next`); `scaffold lint`
requires the full matrix before an adapter in a new family can merge.

| Slot | Services | Default |
| --- | --- | --- |
| `--db` | `mysql`, `postgres`, `mongodb`, `none` | `mysql` (with `--api` or `--app`), otherwise `none` |
| `--cache` | `redis`, `none` | `none` |

No DynamoDB: `compose.yaml` is attached to every release for a client to run
(ADR-0014), and the only DynamoDB that fits a compose file is an emulator
with no production counterpart in a self-hosted stack.

## Documentation

- [Tour](docs/tour/) — how the pieces fit, nine pages
- [Decisions](docs/decisions/) — why they fit that way
- [Runbooks](docs/runbook/) — what to do when something specific happens
- [Provenance](docs/PROVENANCE.md) — what is copied from immich, and where it drifted
- [Contributing](CONTRIBUTING.md) — the tasks, the tests, and how to add an adapter

### Reading path

New to this toolbox: [01-toolchain](docs/tour/01-toolchain.md) through
[03-ci](docs/tour/03-ci.md). That is day one — enough to generate a project and
understand what CI does with it.

Owning it for real, over the first week: the rest of the tour
([04-guardrails](docs/tour/04-guardrails.md) through
[09-wizard](docs/tour/09-wizard.md)), plus ADR-0001, ADR-0003 and ADR-0011.

`docs/runbook/` is not reading material — consult it when the situation that
names it actually arises.

## Licence

MIT — see [LICENSE](LICENSE).

That covers this toolbox. A project it generates carries no licence of its own:
the toolbox does not write one, because who owns generated work and on what
terms is a question for the engagement it was generated for, not a default.
