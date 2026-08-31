# Agent instructions

This project follows a fixed task contract: `install`, `format`, `format-fix`,
`lint`, `check`, `test`, `build`, `ci-unit`, `checklist`. Run
`mise run //<root>:ci-unit` for a given config root to check your work the
same way CI does, or `mise run checklist` from the project root to check
every root.

Architecture decisions live in `docs/decisions`, which ships with a seed ADR
and a template. `mise run //docs:check` validates every ADR there — required
sections, a valid status, unique numbering — so a new one has to follow the
template to pass. Read the relevant ones before changing behavior they cover,
and add one when you make a decision the next reader would otherwise have to
reconstruct.
