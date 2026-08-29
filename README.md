# scaffold

A bash toolbox that generates fully configured client projects. It wires each
generated application to a fixed nine-task contract (`install`, `format`,
`format-fix`, `lint`, `check`, `test`, `build`, `ci-unit`, `checklist`) so CI
can run the same command against any adapter regardless of language.

## Usage

```sh
scaffold new <name> [--web <adapter>] [--api <adapter>] [--app <adapter>]
```

## Adapter support tiers

"Supported" and "guaranteed" are different words. Tier membership is read
from each adapter's own `ADAPTER_TIER` (`adapters/*/adapter.env`) — see
`docs/decisions/0012`.

| Tier | Adapters | CI runs it | Guarantee |
| --- | --- | --- | --- |
| A | `nextjs`, `nestjs`, `laravel-api` | every pull request, and nightly | stays green through every dependency bump |
| B | `laravel-inertia` | when `adapters/laravel-inertia/**` changes, and weekly | verified regularly, not on every push — a full generation measures ~5 minutes per test |
| C | none currently | not automatically verified | may rot; no guarantee at all |

## Documentation

See `docs/` for the design spec, the architecture decisions
(`docs/decisions/`), and the implementation plan.

### Reading path

New to this toolbox: read `docs/tour/01-toolchain.md` through
`docs/tour/03-ci.md` first — that's day one, enough to generate a project
and understand what CI does with it.

Owning it for real, over the first week: the rest of the tour
(`docs/tour/04-guardrails.md` through `docs/tour/08-adapters.md`), plus
ADR-0001, ADR-0003, and ADR-0011.

`docs/runbook/` is not reading material — consult it when the situation
that names it actually arises.
