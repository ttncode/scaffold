# scaffold

A bash toolbox that generates fully configured client projects. It wires each
generated application to a fixed nine-task contract (`install`, `format`,
`format-fix`, `lint`, `check`, `test`, `build`, `ci-unit`, `checklist`) so CI
can run the same command against any adapter regardless of language.

## Usage

```sh
scaffold new <name> [--web <adapter>] [--api <adapter>] [--app <adapter>]
```

## Documentation

See `docs/` for the design spec, the architecture decisions
(`docs/decisions/`), and the implementation plan.
