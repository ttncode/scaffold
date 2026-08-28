# Agent instructions

This project follows a fixed task contract: `install`, `format`, `format-fix`,
`lint`, `check`, `test`, `build`, `ci-unit`, `checklist`. Run
`mise run //<root>:ci-unit` for a given config root to check your work the
same way CI does, or `mise run checklist` from the project root to check
every root.

This project ships no `docs/decisions` directory of its own — that convention
belongs to the scaffold toolbox that generated it, not to what it generated.
If this project starts recording its own architecture decisions, put them in
`docs/decisions` and read the relevant ones before changing behavior they
cover.
