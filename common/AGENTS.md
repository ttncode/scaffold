# Agent instructions

This project follows a fixed task contract: `install`, `format`, `format-fix`,
`lint`, `check`, `test`, `build`, `ci-unit`, `checklist`. Run
`mise run //<root>:ci-unit` for a given config root to check your work the
same way CI does, or `mise run checklist` from the project root to check
every root.

Architecture decisions live in `docs/decisions`. Read the relevant ones before
changing behavior they cover.
